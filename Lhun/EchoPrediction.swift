import Foundation

/// What local echo reads of the terminal: its width, where the cursor is, and what a cell holds.
protocol EchoScreen {
    var cols: Int { get }
    /// Zero-based, on the screen.
    var cursorCol: Int { get }
    var cursorRow: Int { get }
    /// The cell's character when it is printable ASCII, 0x20 for an empty cell, nil for anything else.
    func byte(col: Int, row: Int) -> UInt8?
}

/// Local echo, after Mosh's: while the host's echo is slow, a printable character typed at the cursor
/// shows at once, and goes again as the host's own output settles it. Nothing here touches the terminal
/// or what goes to the host; TerminalModel tells it what was sent and when output arrived, and the view
/// draws `shown` over the terminal's cells.
///
/// Each key sent becomes a guess at what the screen will show once the host has echoed it: a printable
/// character lands where the cursor is and moves it on, and Delete steps back over a character guessed
/// before. Guesses settle oldest first, each once the one before it has: a character is right when the
/// cursor has moved past its cell and the cell holds it, and wrong when the cursor has moved past and
/// the cell holds something else; a step back is right when the cursor is back on its cell. One wrong
/// guess, or one left unsettled past the timeout, drops them all.
///
/// Any other key (Return, Tab, control keys, arrows, Esc, characters outside ASCII, a paste) cannot be
/// guessed. It starts a new epoch, as does a wrong guess: guesses of an epoch show only once one of them
/// came true, so nothing shows while the host may not be echoing at all, as at a password prompt or
/// after a program turned echo off. A space proves nothing that way: an empty cell holds one too.
///
/// Guesses show only while the echo is slow: once the last `window` echoes all took longer than `slow`.
/// A single echo faster than `fast` stops them showing again. Guessing goes on all the while, cheaply,
/// since the echoes it settles are the measure.
struct EchoPrediction {
    /// What the view draws: the guessed cells of one row, by column, and where the cursor will be.
    struct Shown: Equatable {
        let row: Int
        /// Columns and the character each will show, 0x20 where a step back emptied it.
        let cells: [Int: UInt8]
        let cursorCol: Int
    }

    /// Counts since the terminal opened, for the probe.
    struct Counts: Equatable {
        /// Keys guessed, drawn or not.
        var guessed = 0
        /// Guessed characters drawn on screen.
        var shown = 0
        /// Drawn ones the host's echo then matched.
        var confirmed = 0
        /// Drawn ones taken away unmatched: wrong, timed out, or dropped with the connection.
        var erased = 0
        /// Times guesses on screen were taken away unmatched, all at once each time.
        var erasures = 0
    }

    static let window = 8
    static let slow: TimeInterval = 0.040
    static let fast: TimeInterval = 0.030

    private(set) var counts = Counts()
    /// Whether guesses show: the echo is slow.
    private(set) var isOn = false
    /// The last echo delays the guesses measured, oldest first.
    private(set) var delays: [TimeInterval] = []

    private var guesses: [Guess] = []
    private var epoch = 1
    /// The latest epoch with a guess that came true.
    private var trustedEpoch = 0

    private struct Guess {
        enum Effect: Equatable {
            case character(UInt8)
            case stepBack
        }

        let col: Int
        let row: Int
        let effect: Effect
        let sent: TimeInterval
        let epoch: Int
        var shown = false

        /// Where the cursor will be once the host has echoed this key.
        var next: (col: Int, row: Int) {
            switch effect {
            case .character: (col: col + 1, row: row)
            case .stepBack: (col: col, row: row)
            }
        }
    }

    private enum Verdict {
        case pending
        case right
        case wrong
    }

    /// The shortest of the last echo delays.
    var floor: TimeInterval? { delays.min() }

    /// A guess on screen left unsettled this long means the host is not echoing it: three times the
    /// longest recent echo, so one slower echo stretches it at once, and a second at least.
    var timeout: TimeInterval { max(1, 3 * (delays.max() ?? 0)) }

    /// How long a guess not on screen waits for its echo: long enough to measure a link far slower than
    /// the timeout before anything shows, which a guess given up before its echo came never would.
    static let patience: TimeInterval = 10

    /// When the oldest unsettled guess runs out of time, while there is one. Guesses on screen are always
    /// the oldest ones.
    var deadline: TimeInterval? {
        guesses.first.map { $0.sent + ($0.shown ? timeout : max(Self.patience, timeout)) }
    }

    var isGuessing: Bool { !guesses.isEmpty }

    var shown: Shown? {
        let drawn = guesses.prefix { $0.shown }
        guard let first = drawn.first, let last = drawn.last else { return nil }
        var cells: [Int: UInt8] = [:]
        for guess in drawn {
            switch guess.effect {
            case .character(let byte): cells[guess.col] = byte
            case .stepBack: cells[guess.col] = 0x20
            }
        }
        return Shown(row: first.row, cells: cells, cursorCol: last.next.col)
    }

    /// Bytes just written to the host. `guessable` is false while the cursor is hidden or a full-screen
    /// program has the pane: keys there are not echoed at the cursor.
    mutating func sent(_ bytes: some Collection<UInt8>, at time: TimeInterval, on screen: some EchoScreen, guessable: Bool) {
        guard guessable, bytes.count == 1, let byte = bytes.first else { return startEpoch() }
        let at = guesses.last?.next ?? (col: screen.cursorCol, row: screen.cursorRow)
        switch byte {
        case 0x20...0x7E:
            guard at.col <= screen.cols - 2 else { return startEpoch() }
            guesses.append(Guess(col: at.col, row: at.row, effect: .character(byte), sent: time, epoch: epoch))
        case 0x7F, 0x08:
            guard canStepBack(over: at.col - 1, row: at.row, on: screen) else { return startEpoch() }
            guesses.append(Guess(col: at.col - 1, row: at.row, effect: .stepBack, sent: time, epoch: epoch))
        default:
            return startEpoch()
        }
        counts.guessed += 1
        reveal()
    }

    /// Settles guesses against the screen after output reached it, oldest first.
    mutating func check(_ screen: some EchoScreen, at time: TimeInterval) {
        while let guess = guesses.first {
            switch verdict(on: guess, screen) {
            case .pending:
                reveal()
                return
            case .right:
                guesses.removeFirst()
                guard case .character(let byte) = guess.effect else { continue }
                if guess.shown { counts.confirmed += 1 }
                // Right either way, but an empty cell would have matched a space the host never echoed.
                guard byte != 0x20 else { continue }
                trustedEpoch = max(trustedEpoch, guess.epoch)
                measured(time - guess.sent)
            case .wrong:
                drop()
                return
            }
        }
    }

    /// Drops every guess once the oldest has waited past the timeout: the host is not echoing.
    mutating func expire(at time: TimeInterval) {
        guard let deadline, time >= deadline else { return }
        drop()
    }

    /// Drops every guess: the screen changed under them, or the connection did.
    mutating func drop() {
        counts.erased += guesses.filter { $0.shown && $0.effect != .stepBack }.count
        if guesses.contains(where: \.shown) { counts.erasures += 1 }
        guesses.removeAll()
        startEpoch()
    }

    private mutating func startEpoch() {
        epoch += 1
    }

    /// Shows the guesses of trusted epochs, while the echo is slow.
    private mutating func reveal() {
        guard isOn else { return }
        for index in guesses.indices where !guesses[index].shown && guesses[index].epoch <= trustedEpoch {
            guesses[index].shown = true
            if case .character = guesses[index].effect { counts.shown += 1 }
        }
    }

    /// Whether Delete there takes back a character typed: one guessed and not yet echoed, or, with no
    /// guess there, a character other than a space on screen. A space might be the end of the prompt.
    private func canStepBack(over col: Int, row: Int, on screen: some EchoScreen) -> Bool {
        guard col >= 0 else { return false }
        if let last = guesses.last(where: { $0.col == col }) { return last.effect != .stepBack }
        guard let byte = screen.byte(col: col, row: row) else { return false }
        return byte != 0x20
    }

    private func verdict(on guess: Guess, _ screen: some EchoScreen) -> Verdict {
        let onRow = screen.cursorRow == guess.row
        switch guess.effect {
        case .character(let byte):
            if onRow, screen.cursorCol <= guess.col { return .pending }
            return screen.byte(col: guess.col, row: guess.row) == byte ? .right : .wrong
        case .stepBack:
            if onRow, screen.cursorCol > guess.col { return .pending }
            return onRow && screen.cursorCol == guess.col ? .right : .wrong
        }
    }

    private mutating func measured(_ delay: TimeInterval) {
        delays = Array((delays + [delay]).suffix(Self.window))
        guard let floor else { return }
        if floor < Self.fast {
            isOn = false
        } else if delays.count == Self.window, floor > Self.slow {
            isOn = true
        }
    }
}
