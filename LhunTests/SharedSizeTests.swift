import Foundation
import Testing
@testable import LhunKit

/// A control client's output as tmux 3.7c printed it for a session the Mac's terminal had open: the
/// attach's own block, the session it joined, the answer to `list-clients` (the Mac's client, Lhûn's
/// watcher and this control client), and an error for a client that was gone. The pid line comes first,
/// and the layout change and the Mac's terminal switching sessions are notifications as tmux writes them.
private let transcript = """
own 40112\r
%begin 1791489487 225923 0\r
%end 1791489487 225923 0\r
%session-changed $1225 lhun-test-size-a\r
%begin 1791489488 225929 1\r
39862 0 0 160 45 1791489486 160 45 /dev/ttys011\r
39896 1 1 80  1791489486 160 45 /dev/ttys012\r
39974 1 1 80  1791489487 160 45 client-39974\r
%end 1791489488 225929 1\r
%client-session-changed /dev/ttys028 $1225 lhun-test-size-a\r
%layout-change @1 b25d,160x45,0,0,1 b25d,160x45,0,0,1 *\r
%begin 1791489489 225931 1\r
can't find client: nonexistent\r
%error 1791489489 225931 1\r
%client-detached /dev/ttys011\r
%exit\r

"""

@Test("A control client's output reads as its pid, its session, answers to its own commands only, changes and the exit, however it is cut up", arguments: [1, 7, 4096])
func controlOutputReads(chunk: Int) {
    var stream = SharedSize.Stream()
    let bytes = Array(transcript.utf8)
    var events: [SharedSize.Event] = []
    for start in stride(from: 0, to: bytes.count, by: chunk) {
        events += stream.feed(Array(bytes[start..<min(start + chunk, bytes.count)]))
    }
    #expect(events == [
        .own("40112"),
        .attached("$1225"),
        .reply([
            "39862 0 0 160 45 1791489486 160 45 /dev/ttys011",
            "39896 1 1 80  1791489486 160 45 /dev/ttys012",
            "39974 1 1 80  1791489487 160 45 client-39974",
        ], ok: true),
        .changed,
        .changed,
        .reply(["can't find client: nonexistent"], ok: false),
        .changed,
        .exit,
    ])
}

/// This screen's client is pid 500; the Mac's terminal is 400, used before this screen's.
private let mine = "500 0 1 193 51 100 160 45 /dev/ttys001"
private let mac = "400 0 0 160 45 90 160 45 /dev/ttys002"
private let watcher = "600 1 1 80  95 160 45 /dev/ttys003"

@Test("tmux's list of clients decides whether this screen follows the window, takes the size, lets it go or stops following", arguments: [
    // Watching: follow the window the Mac's terminal sizes.
    (true, [mine, mac, watcher], SharedSize.Step.watch(cols: 160, rows: 45)),
    // Watching, and the Mac's terminal has gone: take the size back.
    (true, [mine, watcher], .take),
    // tmux does not list this screen's client yet.
    (true, [mac, watcher], .stay),
    // Setting the size, and the window has it.
    (false, ["500 0 0 193 51 100 193 51 /dev/ttys001", "400 0 0 160 45 90 193 51 /dev/ttys002"], .stay),
    // Setting the size, and the Mac's terminal took it by typing: let it go.
    (false, ["500 0 0 193 51 100 160 45 /dev/ttys001", "400 0 0 160 45 120 160 45 /dev/ttys002"], .yield(cols: 160, rows: 45)),
    // tmux has yet to hear this screen's latest size: no other screen took it.
    (false, ["500 0 0 180 40 100 160 45 /dev/ttys001", "400 0 0 160 45 90 160 45 /dev/ttys002"], .stay),
    // Setting the size, and the other clients set none: a control client, and one that ignores sizes.
    (false, ["500 0 0 193 51 100 193 51 /dev/ttys001", "700 0 1 160 45 90 193 51 /dev/ttys004", watcher], .alone),
])
func sharedSizeStep(watching: Bool, lines: [String], expected: SharedSize.Step) throws {
    let report = try #require(SharedSize.report(lines, own: "500"))
    #expect(SharedSize.step(watching: watching, sent: (cols: 193, rows: 51), report: report) == expected)
}
