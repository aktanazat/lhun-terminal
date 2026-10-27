import Foundation
import Testing
@testable import LhunKit

/// A shell's prompt line as the host draws it: "$ " and what it has echoed since, with the cursor after.
private struct PromptLine: EchoScreen {
    let cols = 40
    var cursorCol = 2
    var cursorRow = 3
    private var cells: [Int: UInt8] = [0: UInt8(ascii: "$")]

    func byte(col: Int, row: Int) -> UInt8? {
        row == cursorRow ? cells[col] ?? 0x20 : 0x20
    }

    mutating func echo(_ text: String) {
        for byte in text.utf8 {
            cells[cursorCol] = byte
            cursorCol += 1
        }
    }

    /// The shell's answer to Delete: back one, blank it.
    mutating func stepBack() {
        cursorCol -= 1
        cells[cursorCol] = nil
    }
}

/// Keys typed at the prompt line and the host's answers, on a clock the test moves.
private struct Typing {
    var echo = EchoPrediction()
    var line = PromptLine()
    var now: TimeInterval = 1000

    /// A link whose echo has taken 300 ms eight times running, so guesses show, and the cursor after a
    /// space. Nothing was drawn on the way: the eighth echo comes after the last key.
    static func slow() -> Typing {
        var typing = Typing()
        for character in "echo hiy" {
            typing.type(String(character))
            typing.answer(after: 0.3) { $0.echo(String(character)) }
        }
        typing.type("a ")
        typing.answer(after: 0.3) { $0.echo("a ") }
        return typing
    }

    mutating func type(_ text: String, guessable: Bool = true) {
        for byte in text.utf8 {
            echo.sent([byte], at: now, on: line, guessable: guessable)
        }
    }

    mutating func send(_ bytes: [UInt8]) {
        echo.sent(bytes, at: now, on: line, guessable: true)
    }

    /// The host's output, reaching the screen `delay` from now, once the timeout has run on the way.
    mutating func answer(after delay: TimeInterval, _ change: (inout PromptLine) -> Void) {
        now += delay
        echo.expire(at: now)
        change(&line)
        echo.check(line, at: now)
    }

    /// The characters drawn over the line, left to right, a dot where a step back emptied a cell.
    var drawn: String {
        guard let shown = echo.shown else { return "" }
        return String(shown.cells.sorted { $0.key < $1.key }.map { $0.value == 0x20 ? "." : Character(UnicodeScalar($0.value)) })
    }
}

@Test("Typed characters show only once eight echoes running took longer than 40 ms")
func guessesWaitForASlowLink() {
    var typing = Typing()
    for character in "echohiy" {
        typing.type(String(character))
        typing.answer(after: 0.3) { $0.echo(String(character)) }
    }
    typing.type("x")
    #expect(typing.drawn == "", "seven slow echoes are not enough")
    typing.answer(after: 0.3) { $0.echo("x") }
    typing.type("y")
    #expect(typing.drawn == "y")
}

@Test("One echo faster than 30 ms stops typed characters showing")
func aFastEchoTurnsGuessesOff() {
    var typing = Typing.slow()
    typing.type("l")
    typing.answer(after: 0.01) { $0.echo("l") }
    typing.type("s")
    #expect(typing.drawn == "")
}

@Test("A typed character shows at the cursor with the cursor after it, and goes once its echo matches")
func guessesShowUntilEchoed() throws {
    var typing = Typing.slow()
    let start = typing.line.cursorCol
    typing.type("ls")
    let shown = try #require(typing.echo.shown)
    #expect(shown.cells == [start: UInt8(ascii: "l"), start + 1: UInt8(ascii: "s")])
    #expect(shown.cursorCol == start + 2)
    #expect(shown.row == typing.line.cursorRow)
    typing.answer(after: 0.3) { $0.echo("l") }
    #expect(typing.drawn == "s", "the s waits for its own echo")
    typing.answer(after: 0.01) { $0.echo("s") }
    #expect(typing.echo.shown == nil)
    #expect(typing.echo.counts.shown == 2)
    #expect(typing.echo.counts.confirmed == 2)
    #expect(typing.echo.counts.erased == 0)
}

@Test("An echo that differs takes every typed character away at once, and the next waits for an echo")
func aWrongEchoErasesEverything() {
    var typing = Typing.slow()
    typing.type("abc")
    typing.answer(after: 0.3) { $0.echo("A") }
    #expect(typing.echo.shown == nil)
    #expect(typing.echo.counts.shown == 3)
    #expect(typing.echo.counts.confirmed == 0)
    #expect(typing.echo.counts.erased == 3)
    #expect(typing.echo.counts.erasures == 1, "all three go in one erasure")
    typing.answer(after: 0.01) { $0.echo("bc") }
    typing.type("d")
    #expect(typing.drawn == "", "a key after a wrong guess shows only once an echo matched again")
    typing.answer(after: 0.3) { $0.echo("d") }
    typing.type("e")
    #expect(typing.drawn == "e")
}

@Test("Characters still unechoed after a second go, and the next waits for an echo")
func silenceErasesAfterTheTimeout() throws {
    var typing = Typing.slow()
    typing.type("pw")
    let deadline = try #require(typing.echo.deadline)
    #expect(deadline == typing.now + 1, "3 times the 300 ms floor is under the 1 second minimum")
    typing.echo.expire(at: deadline - 0.001)
    #expect(typing.drawn == "pw")
    typing.echo.expire(at: deadline)
    #expect(typing.echo.shown == nil)
    #expect(typing.echo.counts.erased == 2)
    typing.type("x")
    #expect(typing.drawn == "", "a key after the timeout shows only once an echo matched again")
}

@Test("A guess on screen times out at three times the longest recent echo, when that is over a second")
func timeoutFollowsTheLink() throws {
    var typing = Typing()
    for (character, delay) in zip("echohiya", [0.5, 0.5, 0.5, 0.75, 0.5, 0.5, 0.5, 0.5]) {
        typing.type(String(character))
        typing.answer(after: delay) { $0.echo(String(character)) }
    }
    typing.type("x")
    #expect(typing.drawn == "x")
    #expect(try #require(typing.echo.deadline) == typing.now + 2.25)
}

@Test("Keys not yet on screen wait ten seconds for their echo, so even a link slower than a second turns guesses on")
func aVerySlowLinkTurnsGuessesOn() {
    var typing = Typing()
    for character in "echohiya" {
        typing.type(String(character))
        typing.answer(after: 2) { $0.echo(String(character)) }
    }
    typing.type("x")
    #expect(typing.drawn == "x")
}

@Test("Delete steps back over a typed character, and its echo settles it")
func deleteStepsBack() throws {
    var typing = Typing.slow()
    let start = typing.line.cursorCol
    typing.type("ab")
    typing.send([0x7F])
    let shown = try #require(typing.echo.shown)
    #expect(typing.drawn == "a.")
    #expect(shown.cursorCol == start + 1)
    typing.answer(after: 0.3) { $0.echo("ab") }
    #expect(typing.drawn == ".", "the step back waits for its own echo")
    typing.answer(after: 0.01) { $0.stepBack() }
    #expect(typing.echo.shown == nil)
    #expect(typing.echo.counts.shown == 2)
    #expect(typing.echo.counts.confirmed == 2)
    #expect(typing.echo.counts.erased == 0)
}

@Test("Delete over a space is not guessed: it may be the prompt's")
func deleteNeverEatsThePrompt() {
    var typing = Typing.slow()
    typing.send([0x7F])
    typing.type("x")
    #expect(typing.drawn == "")
}

@Test("Return, control keys, escape sequences, pastes and keys where nothing echoes are never guessed, and the keys after wait for an echo")
func otherKeysAreNotGuessed() {
    for bytes: [UInt8] in [[0x0D], [0x09], [0x03], [0x1B, 0x5B, 0x41], Array("pasted".utf8), Array("é".utf8)] {
        var typing = Typing.slow()
        let guessed = typing.echo.counts.guessed
        typing.send(bytes)
        #expect(typing.echo.counts.guessed == guessed, "\(bytes) was guessed")
        typing.type("x")
        #expect(typing.drawn == "", "after \(bytes)")
    }
    var hidden = Typing.slow()
    let guessed = hidden.echo.counts.guessed
    hidden.type("x", guessable: false)
    #expect(hidden.echo.counts.guessed == guessed, "a key where nothing echoes was guessed")
    hidden.type("y")
    #expect(hidden.drawn == "")
}

@Test("A space that lands on an empty cell proves no echo, so the keys after it still wait for one")
func aSpaceProvesNothing() {
    var typing = Typing.slow()
    typing.send([0x0D])
    typing.type(" x")
    typing.answer(after: 0.3) { $0.echo(" ") }
    #expect(typing.drawn == "", "the space's cell is empty whether or not it was echoed")
    typing.answer(after: 0.01) { $0.echo("x") }
    typing.type("y")
    #expect(typing.drawn == "y")
}

@Test("Nothing is guessed in the last column, where the host may wrap the line")
func lastColumnIsNotGuessed() {
    var typing = Typing.slow()
    typing.answer(after: 0) { $0.echo(String(repeating: "a", count: $0.cols - 2 - $0.cursorCol)) }
    typing.type("b")
    #expect(typing.drawn == "b")
    typing.type("c")
    #expect(typing.drawn == "b")
}

@Test("Dropping the guesses erases the ones showing, and the next key waits for an echo")
func dropErasesEverything() {
    var typing = Typing.slow()
    typing.type("ab")
    typing.echo.drop()
    #expect(typing.echo.shown == nil)
    #expect(typing.echo.counts.erased == 2)
    typing.type("c")
    #expect(typing.drawn == "")
}
