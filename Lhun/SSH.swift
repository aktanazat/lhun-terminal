import Foundation
import Network
import NIOCore
import NIOSSH
import NIOTransportServices

/// Why a connection or a command failed, in words the app can show.
enum SSHFailure: LocalizedError {
    case keyNotAccepted
    case hostKeyChanged
    case signInTimedOut
    case closed
    case commandFailed(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .keyNotAccepted: "The host doesn't know this device's key yet."
        case .hostKeyChanged: "The host's identity changed, so Lhûn won't connect."
        case .signInTimedOut: "The host stopped answering while signing in."
        case .closed: "The connection closed."
        case .commandFailed(_, let message): message.isEmpty ? "The command failed." : message
        }
    }
}

/// One signed-in SSH connection. Commands and shells run as channels on it.
///
/// Network.framework carries the TCP connection, so it follows the device across Wi-Fi and cellular the
/// way the system expects. Keepalives are short so a dead link is noticed in about half a minute even when
/// nothing is being typed.
struct SSHConnection: Sendable, Equatable {
    private let channel: Channel

    static func == (lhs: SSHConnection, rhs: SSHConnection) -> Bool {
        lhs.channel === rhs.channel
    }

    var isActive: Bool { channel.isActive }

    static func open(to host: Host, key: NIOSSHPrivateKey) async throws -> SSHConnection {
        let pins = Set(try host.hostKeys.map { try NIOSSHPublicKey(openSSHPublicKey: $0) })
        let user = host.user
        let loop = NIOTSEventLoopGroup.singleton.next()
        let signedIn = loop.makePromise(of: Void.self)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        tcp.connectionDropTime = 20

        let channel: Channel
        do {
            channel = try await NIOTSConnectionBootstrap(group: loop)
                .connectTimeout(.seconds(8))
                .tcpOptions(tcp)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let client = SSHClientConfiguration(
                            userAuthDelegate: KeyOffer(user: user, key: key),
                            serverAuthDelegate: PinnedHostKeys(keys: pins)
                        )
                        let ssh = NIOSSHHandler(
                            role: .client(client),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil
                        )
                        try channel.pipeline.syncOperations.addHandler(ssh)
                        try channel.pipeline.syncOperations.addHandler(SignInWatcher(signedIn: signedIn))
                    }
                }
                .connect(host: host.address, port: host.port)
                .get()
        } catch {
            signedIn.fail(error)
            throw error
        }

        let deadline = loop.scheduleTask(in: .seconds(15)) {
            signedIn.fail(SSHFailure.signInTimedOut)
            channel.close(promise: nil)
        }
        defer { deadline.cancel() }
        do {
            try await signedIn.futureResult.get()
        } catch {
            channel.close(promise: nil)
            throw error
        }
        return SSHConnection(channel: channel)
    }

    func close() {
        channel.close(promise: nil)
    }

    /// Runs one command and returns its standard output. A non-zero exit throws with its error output.
    /// `input`, when given, becomes the command's standard input: sent as fast as the host takes it,
    /// then closed.
    ///
    /// A command that outlives `timeout` closes the whole connection: a host that stops answering a
    /// one-line command is not going to answer anything else on it either.
    func run(_ command: String, input: Data? = nil, timeout: TimeAmount = .seconds(15)) async throws -> String {
        String(decoding: try await runForBytes(command, input: input, timeout: timeout), as: UTF8.self)
    }

    /// `run`, with the standard output as the bytes the command printed, for a file's contents.
    func runForBytes(_ command: String, input: Data? = nil, timeout: TimeAmount = .seconds(15)) async throws -> Data {
        let parent = channel
        let done = parent.eventLoop.makePromise(of: ExecResult.self)
        _ = try await openChannel { child in
            try child.pipeline.syncOperations.addHandler(ExecHandler(command: command, input: input, done: done))
        } onFailure: { error in
            done.fail(error)
        }
        let deadline = parent.eventLoop.scheduleTask(in: timeout) { parent.close(promise: nil) }
        defer { deadline.cancel() }
        let result = try await done.futureResult.get()
        guard result.status == 0 else {
            throw SSHFailure.commandFailed(
                status: result.status,
                message: result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result.output
    }

    /// Opens a pseudo-terminal running `command`. Output arrives in batches on a background thread.
    func openShell(
        command: String,
        cols: Int,
        rows: Int,
        output: @escaping @Sendable ([UInt8]) -> Void
    ) async throws -> ShellChannel {
        let ended = channel.eventLoop.makePromise(of: ShellEnd.self)
        let child = try await openChannel { child in
            let shell = ShellHandler(command: command, cols: cols, rows: rows, output: output, ended: ended)
            try child.pipeline.syncOperations.addHandler(shell)
        } onFailure: { error in
            ended.fail(error)
        }
        return ShellChannel(channel: child, ended: ended.futureResult)
    }

    /// Opens a tunnel to `port` on the host's own localhost, as `ssh -L` does: sshd makes the connection
    /// there, so whatever listens on the port sees an ordinary local client. "localhost" lets sshd try
    /// both ::1 and 127.0.0.1, since dev servers bind either one.
    func openTunnel(to port: Int, from originator: SocketAddress) async throws -> NIOAsyncChannel<SSHChannelData, SSHChannelData> {
        let wrapped = channel.eventLoop.makePromise(of: NIOAsyncChannel<SSHChannelData, SSHChannelData>.self)
        let target = SSHChannelType.DirectTCPIP(targetHost: "localhost", targetPort: port, originatorAddress: originator)
        _ = try await openChannel(.directTCPIP(target)) { child in
            wrapped.succeed(try NIOAsyncChannel<SSHChannelData, SSHChannelData>(
                wrappingChannelSynchronously: child,
                configuration: .init(isOutboundHalfClosureEnabled: true)
            ))
        } onFailure: { error in
            wrapped.fail(error)
        }
        return try await wrapped.futureResult.get()
    }

    /// Opens a channel and installs its handler. A host that cannot open a channel within ten seconds is
    /// treated as gone, and the connection is closed so nothing is left half-open on it.
    private func openChannel(
        _ type: SSHChannelType = .session,
        install: @escaping @Sendable (Channel) throws -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) async throws -> Channel {
        let parent = channel
        let opened = parent.eventLoop.makePromise(of: Channel.self)
        opened.futureResult.whenFailure(onFailure)
        parent.eventLoop.execute {
            do {
                let ssh = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                ssh.createChannel(opened, channelType: type) { child, _ in
                    child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMapThrowing {
                        try install(child)
                    }
                }
            } catch {
                opened.fail(error)
            }
        }
        let deadline = parent.eventLoop.scheduleTask(in: .seconds(10)) { parent.close(promise: nil) }
        defer { deadline.cancel() }
        return try await opened.futureResult.get()
    }
}

/// How a shell channel finished: the program exited (tmux detached, or its session ended), or the
/// connection under it went away and the session is still there to come back to.
enum ShellEnd: Sendable, Equatable {
    case exited(Int)
    case lost
}

/// A live pseudo-terminal channel.
struct ShellChannel: Sendable {
    private let channel: Channel
    private let ended: EventLoopFuture<ShellEnd>

    fileprivate init(channel: Channel, ended: EventLoopFuture<ShellEnd>) {
        self.channel = channel
        self.ended = ended
    }

    func write(_ bytes: [UInt8]) {
        channel.writeAndFlush(channel.allocator.buffer(bytes: bytes), promise: nil)
    }

    func resize(cols: Int, rows: Int) {
        let request = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        channel.triggerUserOutboundEvent(request, promise: nil)
    }

    func close() {
        channel.close(promise: nil)
    }

    func end() async -> ShellEnd {
        do {
            return try await ended.get()
        } catch {
            return .lost
        }
    }
}

// MARK: - Sign-in

/// Offers this device's key, once. Being asked again means the host refused it.
private final class KeyOffer: NIOSSHClientUserAuthenticationDelegate {
    private let user: String
    private let key: NIOSSHPrivateKey
    private var offered = false

    init(user: String, key: NIOSSHPrivateKey) {
        self.user = user
        self.key = key
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        // Failing the promise ends the connection with this error; offering nothing would leave it open.
        guard !offered, availableMethods.contains(.publicKey) else {
            nextChallengePromise.fail(SSHFailure.keyNotAccepted)
            return
        }
        offered = true
        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(username: user, serviceName: "", offer: .privateKey(.init(privateKey: key)))
        )
    }
}

/// Accepts only the paired host's recorded public keys.
private struct PinnedHostKeys: NIOSSHClientServerAuthenticationDelegate {
    let keys: Set<NIOSSHPublicKey>

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        if keys.contains(hostKey) {
            validationCompletePromise.succeed()
        } else {
            validationCompletePromise.fail(SSHFailure.hostKeyChanged)
        }
    }
}

/// Completes `signedIn` when the host accepts the key, and fails it if the connection dies first.
/// Any error on the connection closes it.
private final class SignInWatcher: ChannelInboundHandler {
    typealias InboundIn = Any

    private let signedIn: EventLoopPromise<Void>

    init(signedIn: EventLoopPromise<Void>) {
        self.signedIn = signedIn
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            signedIn.succeed()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        signedIn.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        signedIn.fail(SSHFailure.closed)
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        signedIn.fail(SSHFailure.closed)
    }
}

// MARK: - Channels

private struct ExecResult: Sendable {
    let status: Int
    let output: Data
    let errorOutput: String
}

/// Runs one command, feeds it its input if it has any, and collects what it prints.
private final class ExecHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    /// Input goes out in pieces this size, as long as the host's window has room.
    private static let chunk = 32 * 1024

    private let command: String
    private let input: Data?
    private let done: EventLoopPromise<ExecResult>
    private var output = Data()
    private var errorOutput: [UInt8] = []
    private var status: Int?
    private var started = false
    private var sent = 0
    private var inputClosed = false

    init(command: String, input: Data?, done: EventLoopPromise<ExecResult>) {
        self.command = command
        self.input = input
        self.done = done
    }

    func channelActive(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { return }
        switch message.type {
        case .channel: output.append(contentsOf: buffer.readableBytesView)
        case .stdErr: errorOutput.append(contentsOf: buffer.readableBytesView)
        default: break
        }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        sendInput(context: context)
        context.fireChannelWritabilityChanged()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let exit as SSHChannelRequestEvent.ExitStatus:
            status = exit.exitStatus
        case is ChannelSuccessEvent:
            // The command is running, so its standard input is open.
            started = true
            sendInput(context: context)
        case is ChannelFailureEvent:
            // The host refused to run the command at all.
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        done.succeed(ExecResult(
            status: status ?? -1,
            output: output,
            errorOutput: String(decoding: errorOutput, as: UTF8.self)
        ))
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        done.fail(SSHFailure.closed)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        done.fail(error)
        context.close(promise: nil)
    }

    /// Writes input while the host has room for it, and closes it once all of it is out, which the
    /// command reads as end of file.
    private func sendInput(context: ChannelHandlerContext) {
        guard started, !inputClosed, let input else { return }
        while sent < input.count, context.channel.isWritable {
            let end = min(sent + Self.chunk, input.count)
            let piece = context.channel.allocator.buffer(bytes: input[(input.startIndex + sent)..<(input.startIndex + end)])
            context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(piece))), promise: nil)
            sent = end
        }
        context.flush()
        if sent == input.count {
            inputClosed = true
            context.close(mode: .output, promise: nil)
        }
    }
}

/// A pseudo-terminal running one command. Output is handed over once per read burst rather than per
/// packet, so a screenful of tmux redraw reaches the terminal as one feed.
private final class ShellHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let cols: Int
    private let rows: Int
    private let output: @Sendable ([UInt8]) -> Void
    private let ended: EventLoopPromise<ShellEnd>
    private var pending: [UInt8] = []
    private var status: Int?

    init(command: String, cols: Int, rows: Int, output: @escaping @Sendable ([UInt8]) -> Void, ended: EventLoopPromise<ShellEnd>) {
        self.command = command
        self.cols = cols
        self.rows = rows
        self.output = output
        self.ended = ended
    }

    func channelActive(context: ChannelHandlerContext) {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: false,
            term: "xterm-256color",
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        context.triggerUserOutboundEvent(pty, promise: nil)
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .byteBuffer(let buffer) = unwrapInboundIn(data).data else { return }
        pending.append(contentsOf: buffer.readableBytesView)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        flush()
        context.fireChannelReadComplete()
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let exit as SSHChannelRequestEvent.ExitStatus:
            status = exit.exitStatus
        case is SSHChannelRequestEvent.ExitSignal:
            status = status ?? -1
        case is ChannelFailureEvent:
            // The host refused to run tmux. Retrying would be refused the same way.
            status = -1
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        flush()
        ended.succeed(status.map(ShellEnd.exited) ?? .lost)
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        ended.succeed(.lost)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        output(pending)
        pending.removeAll()
    }
}
