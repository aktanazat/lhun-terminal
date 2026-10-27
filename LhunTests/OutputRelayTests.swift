import Foundation
import Testing
@testable import LhunKit

/// How a shell's output crosses from the network's thread to the main actor.
@MainActor
struct OutputRelayTests {
    @Test("Reads that land while the main thread is busy reach the terminal as one feed, in order")
    func readsBehindAWaitingHopShareIt() async {
        let feeds = Feeds()
        let relay = OutputRelay(timesArrivals: true) { bytes, arrivals in feeds.take(bytes, arrivals) }
        // The test holds the main thread, as a long frame would, while three reads land.
        for read in ["one ", "two ", "three"] { relay.append(Array(read.utf8)) }
        await mainQueueTurn()
        #expect(feeds.text == ["one two three"])
        // The probe still sees when each read came off the network.
        #expect(feeds.arrivals.map(\.count) == [3])
    }

    @Test("A read that lands after a feed went out reaches the terminal in a feed of its own")
    func readAfterAFeedQueuesAnother() async {
        let feeds = Feeds()
        let relay = OutputRelay(timesArrivals: false) { bytes, arrivals in feeds.take(bytes, arrivals) }
        relay.append(Array("one".utf8))
        await mainQueueTurn()
        relay.append(Array("two".utf8))
        await mainQueueTurn()
        #expect(feeds.text == ["one", "two"])
    }
}

/// What reached the main actor, feed by feed.
@MainActor
private final class Feeds {
    private(set) var text: [String] = []
    private(set) var arrivals: [[TimeInterval]] = []

    func take(_ bytes: [UInt8], _ arrived: [TimeInterval]) {
        text.append(String(decoding: bytes, as: UTF8.self))
        arrivals.append(arrived)
    }
}

/// Returns once everything already queued on the main queue has run.
private func mainQueueTurn() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}
