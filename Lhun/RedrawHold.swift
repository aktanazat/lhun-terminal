/// tmux's first redraw after an attach, held back until all of it is in (TerminalModel.received), so the
/// screen goes from the last one shown to the redrawn one in a single frame however slowly it comes.
///
/// As a client attaches, tmux clears its screen, asks the terminal what it is, and redraws. Told that the
/// terminal takes synchronized updates, as both hosts' tmux settings tell it, tmux draws in updates that
/// begin with ESC [ ? 2026 h and end with ESC [ ? 2026 l, the clear and the questions coming before the
/// first one, outside it. tmux redraws only once everything before has gone out, and writes an update's
/// end right behind the update, in the same go: once the first update has begun, its end is on its way,
/// and the hold waits for it, with no deadline to cut the redraw off halfway. A tmux not told draws
/// outside updates, so the first thing it draws after its clear ends the hold, and its redraw shows as it
/// arrives.
///
/// tmux takes an answer to its questions that comes more than five seconds after it asked for typed keys,
/// and hands it to the program in the pane. So the questions do not wait with the redraw: each one comes
/// out of the held output once it is whole, for the terminal to answer straight away.
struct RedrawHold {
    /// What a read brought.
    struct Step {
        /// tmux's questions in it, each whole, for the terminal to answer now.
        var questions: [[UInt8]] = []
        /// All of the redraw is in, or tmux draws outside updates: `held` is ready to show.
        var redrawn = false
    }

    /// Everything read since the attach, but the questions taken out of it.
    private(set) var held: [UInt8] = []

    /// How far into `held` reading has got.
    private var read = 0
    private var scan = Scan.text
    /// Where in `held` the escape sequence being read began.
    private var start = 0
    /// tmux has cleared the screen, so what it draws from here on is the redraw.
    private var cleared = false
    /// tmux has begun an update.
    private var updating = false

    /// What reading is in the middle of.
    private enum Scan {
        case text
        /// The byte after ESC.
        case escape
        /// A control sequence, from ESC [ to its final byte.
        case control
        /// A string, such as a color query, from ESC ] to BEL or ESC \.
        case string
    }

    /// The parameters of ESC [ ? 2026 h and l, which begin and end an update.
    private static let update = Array("?2026".utf8)
    /// tmux's questions, by their parameters and final byte: device attributes, ESC [ c; secondary device
    /// attributes, ESC [ > c; and the terminal's name and version, ESC [ > q. tmux waits five seconds for
    /// these answers. Its color queries, ESC ] 10 ; ? and ESC ] 11 ; ?, it takes whenever they come.
    private static let questions: [(parameters: [UInt8], final: UInt8)] = [
        ([], UInt8(ascii: "c")), (Array(">".utf8), UInt8(ascii: "c")), (Array(">".utf8), UInt8(ascii: "q")),
    ]
    /// The final bytes of the control sequences that draw: erase in display, once the screen is cleared,
    /// and in line; insert and delete characters and lines; scroll; erase characters; and repeat.
    private static let drawing = Array("JK@PLMSTXb".utf8)

    /// Holds a read, takes tmux's questions out of it, and tells whether the redraw is all in.
    mutating func take(_ bytes: [UInt8]) -> Step {
        held += bytes
        var step = Step()
        while read < held.count, !step.redrawn {
            let byte = held[read]
            read += 1
            switch (scan, byte) {
            case (_, 0x1b):
                scan = .escape
                start = read - 1
            case (_, 0x18), (_, 0x1a), (.string, 0x07):
                // CAN or SUB cuts a sequence off; BEL ends a string.
                scan = .text
            case (.text, _):
                // Printable: ASCII past the controls, or part of a UTF-8 character.
                if byte >= 0x20, byte != 0x7f, cleared, !updating { step.redrawn = true }
            case (.escape, UInt8(ascii: "[")):
                scan = .control
            case (.escape, UInt8(ascii: "]")), (.escape, UInt8(ascii: "P")), (.escape, UInt8(ascii: "X")),
                 (.escape, UInt8(ascii: "^")), (.escape, UInt8(ascii: "_")):
                scan = .string
            case (.escape, 0x20...0x2f):
                // An intermediate byte, as in ESC ( B.
                break
            case (.escape, _):
                scan = .text
            case (.control, 0x40...0x7e):
                scan = .text
                ended(&step)
            case (.control, _), (.string, _):
                break
            }
        }
        return step
    }

    /// The control sequence from `start` to `read` has ended.
    private mutating func ended(_ step: inout Step) {
        let parameters = held[(start + 2)..<(read - 1)], final = held[read - 1]
        if Self.questions.contains(where: { $0.final == final && $0.parameters.elementsEqual(parameters) }) {
            step.questions.append(Array(held[start..<read]))
            held.removeSubrange(start..<read)
            read = start
        } else if parameters.elementsEqual(Self.update), final == UInt8(ascii: "h") {
            updating = true
        } else if parameters.elementsEqual(Self.update), final == UInt8(ascii: "l") {
            step.redrawn = true
        } else if !cleared {
            cleared = final == UInt8(ascii: "J")
        } else if !updating, Self.drawing.contains(final) {
            step.redrawn = true
        }
    }
}
