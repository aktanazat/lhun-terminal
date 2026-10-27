import QuartzCore
import Synchronization

/// Carries a shell's output from the network's thread to the main actor. While one hop to the main
/// thread waits, output that lands behind it rides along instead of queuing a hop of its own, so a burst
/// the main thread falls behind on reaches the terminal as one feed rather than one per network read.
final class OutputRelay: Sendable {
    /// Output that came off the network and has not reached the main actor yet.
    private struct Waiting {
        var bytes: [UInt8] = []
        /// When each read came off the network, oldest first. Kept only while the probe times keys.
        var arrivals: [TimeInterval] = []
        var hopQueued = false
    }

    private let waiting = Mutex(Waiting())
    private let timesArrivals: Bool
    private let deliver: @MainActor @Sendable (_ bytes: [UInt8], _ arrivals: [TimeInterval]) -> Void

    init(
        timesArrivals: Bool,
        deliver: @escaping @MainActor @Sendable (_ bytes: [UInt8], _ arrivals: [TimeInterval]) -> Void
    ) {
        self.timesArrivals = timesArrivals
        self.deliver = deliver
    }

    /// Takes one read's output, on any thread.
    func append(_ bytes: [UInt8]) {
        let arrived = timesArrivals ? CACurrentMediaTime() : 0
        let queuesHop = waiting.withLock { waiting in
            // A read with nothing ahead of it is kept as it came, not copied.
            if waiting.bytes.isEmpty { waiting.bytes = bytes } else { waiting.bytes += bytes }
            if timesArrivals { waiting.arrivals.append(arrived) }
            defer { waiting.hopQueued = true }
            return !waiting.hopQueued
        }
        guard queuesHop else { return }
        // The main queue runs hops in the order they were queued; a Task hop does not promise that.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.drain() }
        }
    }

    @MainActor private func drain() {
        let (bytes, arrivals) = waiting.withLock { waiting in
            defer { waiting = Waiting() }
            return (waiting.bytes, waiting.arrivals)
        }
        deliver(bytes, arrivals)
    }
}
