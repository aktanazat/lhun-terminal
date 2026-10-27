import Testing
@testable import LhunKit

/// What tmux 3.7c wrote to a client attaching to a 24 by 4 pane showing "one" and "two", its status line
/// off (recorded 2026-10-09). First the alternate screen and its clear, modes and a scroll region:
private let clearing = """
    \u{1B}[?1049h\u{1B}[22;0;0t\u{1B}[?1h\u{1B}=\u{1B}[H\u{1B}[2J\u{1B}[?12l\u{1B}[?25h\u{1B}[?1000l\u{1B}[?1002l\
    \u{1B}[?1003l\u{1B}[?1006l\u{1B}[?1005l\u{1B}[?2004h\u{1B}[?2031h\u{1B}[?996n\u{1B}(B\u{1B}[m\u{1B}[?12l\
    \u{1B}[?25h\u{1B}[?1006l\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[1;1H\u{1B}[1;4r
    """
/// Then its questions: device attributes, secondary device attributes, and the terminal's name and version.
private let questions = ["\u{1B}[c", "\u{1B}[>c", "\u{1B}[>q"]
/// Then the two colors it asks about.
private let colors = "\u{1B}]10;?\u{1B}\\\u{1B}]11;?\u{1B}\\"
private let beforeRedraw = clearing + questions.joined() + colors
/// Then the redraw, in an update, as both hosts' tmux settings have it.
private let markedRedraw = """
    \u{1B}[3;1H\u{1B}[?2026h\u{1B}[?25l\u{1B}[Hone\u{1B}[K\r\ntwo\u{1B}[K\r\n\u{1B}[K\r\n\u{1B}[K\u{1B}[?12l\
    \u{1B}[?25h\u{1B}[A\u{1B}[?2026l
    """

/// How Lhûn holds tmux's redraw after an attach until it can show all of it at once.
struct RedrawHoldTests {
    @Test("A redraw in an update is held until the update ends, however the output is cut up", arguments: [1, 7, 4096])
    func markedRedrawWaitsForItsEnd(chunk: Int) {
        var hold = RedrawHold()
        let reads = Self.reads(of: beforeRedraw + markedRedraw, chunk: chunk)
        let redrawn = reads.map { hold.take($0).redrawn }
        // The update's end is the last byte, in the last read.
        #expect(redrawn == Array(repeating: false, count: reads.count - 1) + [true])
    }

    @Test("All of tmux's output is held but its questions, which come out once each, however it is cut up", arguments: [1, 7, 4096])
    func questionsComeOutOfTheHeldOutput(chunk: Int) {
        var hold = RedrawHold()
        let asked = Self.reads(of: beforeRedraw + markedRedraw, chunk: chunk).flatMap { hold.take($0).questions }
        #expect(asked == questions.map { Array($0.utf8) })
        #expect(hold.held == Array((clearing + colors + markedRedraw).utf8))
    }

    /// tmux takes an answer that comes more than five seconds after it asked for typed keys.
    @Test("tmux's questions come out with the read that brings them, while the redraw is still held")
    func questionsComeOutAtOnce() {
        var hold = RedrawHold()
        let step = hold.take(Array(beforeRedraw.utf8))
        #expect(!step.redrawn)
        #expect(step.questions == questions.map { Array($0.utf8) })
    }

    /// As tmux 3.7c redraws without the hosts' settings.
    @Test("Without updates, the hold ends at the first thing tmux draws after its clear", arguments: [
        // A pane showing text: the cursor goes home, then the first row's text.
        ("\u{1B}[3;1H\u{1B}[?25l\u{1B}[H", "one"),
        // A blank pane: the first row is erased.
        ("\u{1B}[1;1H\u{1B}[?25l", "\u{1B}[K"),
    ])
    func unmarkedRedrawShowsAtOnce(before: String, drawing: String) {
        var hold = RedrawHold()
        let held = hold.take(Array((beforeRedraw + before).utf8))
        let drawn = hold.take(Array(drawing.utf8))
        #expect(!held.redrawn && drawn.redrawn)
    }

    @Test("Text the host prints before tmux clears the screen does not end the hold")
    func textBeforeTheClearIsHeld() {
        var hold = RedrawHold()
        let step = hold.take(Array(("warning: setlocale: LC_CTYPE: cannot change locale (en_US.UTF-8)\r\n" + beforeRedraw).utf8))
        #expect(!step.redrawn)
    }

    /// The bytes of `text` in reads of `chunk` bytes, the last one shorter.
    private static func reads(of text: String, chunk: Int) -> [[UInt8]] {
        let bytes = Array(text.utf8)
        return stride(from: 0, to: bytes.count, by: chunk).map { Array(bytes[$0..<min($0 + chunk, bytes.count)]) }
    }
}
