import Foundation
import NIOCore
import NIOSSH
import NIOTransportServices
import OSLog

/// The host turned down a tunnel to `port`: nothing listens there.
struct PortClosed: LocalizedError {
    let port: Int
    let phrase: String

    var errorDescription: String? { "Nothing answered on port \(port) on \(phrase)." }
}

/// A port on this device's loopback that leads to a port on the host's loopback, as `ssh -L` does.
///
/// Every connection made to it becomes a tunnel of its own on the host's session-list connection. It
/// listens on 127.0.0.1 only, never on the network, and only until `stop`, which also closes every
/// connection still open through it.
final class PortForward: Sendable {
    /// The port on the host.
    let port: Int
    /// The port on this device: the same number as on the host when it is free here, so a page that
    /// names its own address keeps working, and any free port otherwise.
    let localPort: Int
    private let listener: Channel
    private let serving: Task<Void, Never>

    private static let log = Logger(subsystem: "com.aktanazat.lhun", category: "forward")

    private init(port: Int, localPort: Int, listener: Channel, serving: Task<Void, Never>) {
        self.port = port
        self.localPort = localPort
        self.listener = listener
        self.serving = serving
    }

    /// Starts listening once something answers on the host's port, so a dead port is reported in words
    /// instead of as a page that never loads.
    static func start(port: Int, on link: HostLink) async throws -> PortForward {
        try await check(port: port, on: link)
        let server: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>
        do {
            server = try await listen(on: port)
        } catch {
            server = try await listen(on: 0)
        }
        guard let localPort = server.channel.localAddress?.port else {
            server.channel.close(promise: nil)
            throw ChannelError.unknownLocalAddress
        }
        let serving = Task {
            do {
                try await server.executeThenClose { clients in
                    try await withThrowingDiscardingTaskGroup { group in
                        for try await client in clients {
                            group.addTask { await relay(client, to: port, on: link) }
                        }
                    }
                }
            } catch {
                log.info("Forward to port \(port) ended: \(error.localizedDescription, privacy: .public)")
            }
        }
        return PortForward(port: port, localPort: localPort, listener: server.channel, serving: serving)
    }

    /// Opens one tunnel to the host's port and closes it at once. Throws `PortClosed` when nothing
    /// answers there.
    static func check(port: Int, on link: HostLink) async throws {
        let tunnel = try await link.openTunnel(to: port, from: try SocketAddress(ipAddress: "127.0.0.1", port: 0))
        try await tunnel.executeThenClose { _, _ in }
    }

    /// Stops listening, then closes every connection made through the port. Returns once all of it is
    /// closed.
    func stop() async {
        listener.close(promise: nil)
        // Never fails: a channel's close future only ever succeeds.
        try? await listener.closeFuture.get()
        serving.cancel()
        await serving.value
    }

    private static func listen(on port: Int) async throws -> NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never> {
        try await NIOTSListenerBootstrap(group: NIOTSEventLoopGroup.singleton)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .bind(host: "127.0.0.1", port: port) { child in
                child.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                        wrappingChannelSynchronously: child,
                        configuration: .init(isOutboundHalfClosureEnabled: true)
                    )
                }
            }
    }

    /// Carries one connection to the host and back until both sides are done. Each direction closes
    /// on its own, so a client that finishes sending still gets the whole reply.
    private static func relay(_ client: NIOAsyncChannel<ByteBuffer, ByteBuffer>, to port: Int, on link: HostLink) async {
        do {
            try await client.executeThenClose { fromClient, toClient in
                let tunnel = try await link.openTunnel(to: port, from: try SocketAddress(ipAddress: "127.0.0.1", port: 0))
                try await tunnel.executeThenClose { fromHost, toHost in
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for try await bytes in fromClient {
                                try await toHost.write(SSHChannelData(type: .channel, data: .byteBuffer(bytes)))
                            }
                            toHost.finish()
                        }
                        group.addTask {
                            for try await message in fromHost {
                                guard message.type == .channel, case .byteBuffer(let bytes) = message.data else { continue }
                                try await toClient.write(bytes)
                            }
                            toClient.finish()
                        }
                        try await group.waitForAll()
                    }
                }
            }
        } catch {
            log.debug("A connection to port \(port) ended: \(error.localizedDescription, privacy: .public)")
        }
    }
}
