import CoreGraphics

/// Where the session peek rests.
enum PeekState {
    case closed
    /// A row of the strip's host's sessions above the card.
    case row
    /// Every session on every host, with the card waiting below the screen.
    case grid
}

/// Where the peek puts things, from the room below the strip, the card's height and the reader's text size.
struct PeekLayout {
    /// The room below the strip, the keyboard's included once it has stepped aside for the peek.
    let area: CGSize
    /// The card's height, which it keeps while the peek is out. Without one, the card fills the room.
    let cardHeight: CGFloat
    /// A card's title line at the reader's text size: `titleLine`, scaled with the caption style.
    let titleHeight: CGFloat

    init(area: CGSize, cardHeight: CGFloat? = nil, titleHeight: CGFloat = PeekLayout.titleLine) {
        self.area = area
        self.cardHeight = cardHeight ?? area.height
        self.titleHeight = titleHeight
    }

    /// From the screen's edge to the cards.
    static let margin = Metrics.inset
    /// Between cards.
    static let spacing = Metrics.apart
    /// Around a card's title and picture, and between the two. The picture's corners are rounded less by
    /// as much, so they stay concentric with the card's.
    static let padding = Metrics.near
    /// A card's title line at the default text size, set in the caption style.
    static let titleLine: CGFloat = 16
    /// Above and below the row.
    static let rowPadding = Metrics.near

    /// The terminal's shape, which every picture keeps: the card without its margins.
    var aspect: CGFloat { max(area.width - 16, 1) / max(cardHeight - 8, 1) }

    var rowPicture: CGSize {
        let height = min(150, max(area.height * 0.28, 60))
        return CGSize(width: height * aspect, height: height)
    }

    /// How far the card moves down to show the row: a card, its title over its picture with the padding
    /// around and between them, and the row's own padding.
    var rowRest: CGFloat { rowPicture.height + titleHeight + 3 * Self.padding + 2 * Self.rowPadding }

    /// Pulled past this, letting go opens the grid.
    var gridFrom: CGFloat { rowRest + 120 }

    /// In the grid the card waits just below the screen.
    var gridRest: CGFloat { area.height + 24 }

    /// How far below its place the card rests in `state`.
    func rest(in state: PeekState) -> CGFloat {
        switch state {
        case .closed: 0
        case .row: rowRest
        case .grid: gridRest
        }
    }

    var gridColumns: Int {
        min(max(Int((area.width - 2 * Self.margin + Self.spacing) / (260 + Self.spacing)), 1), 4)
    }

    var gridCardWidth: CGFloat {
        let columns = CGFloat(gridColumns)
        return max((area.width - 2 * Self.margin - (columns - 1) * Self.spacing) / columns, 1)
    }

    var gridPicture: CGSize {
        let width = max(gridCardWidth - 2 * Self.padding, 1)
        return CGSize(width: width, height: width / aspect)
    }

    /// Where the card settles when the finger lets go with it `offset` points down, moving at `velocity`
    /// points a second: a flick goes its way, otherwise the card goes to the nearest place.
    func state(releasedAt offset: CGFloat, velocity: CGFloat) -> PeekState {
        if velocity < -500 { return .closed }
        if velocity > 500 { return offset > rowRest ? .grid : .row }
        if offset < rowRest / 2 { return .closed }
        return offset < gridFrom ? .row : .grid
    }
}

/// A key the peek acts on, read from the bytes the terminal would send for it.
enum PeekKey: Equatable {
    enum Direction {
        case up, down, left, right
    }

    case close
    case open
    case move(Direction)
    /// Text typed, which narrows the grid.
    case type(String)
    /// Delete, which takes back the filter's last character.
    case erase

    /// Escape closes, Return opens the highlighted session, the arrows move. Arrows come in both cursor
    /// modes, and Escape and Return also in the kitty keyboard protocol's form. Text with no control
    /// character in it is typed, and Delete erases. Anything else is not a peek key, and goes on to tmux.
    init?(_ bytes: [UInt8]) {
        switch bytes {
        case [0x1B], Array("\u{1B}[27u".utf8):
            self = .close
        case [0x0D], [0x0A], Array("\u{1B}[13u".utf8):
            self = .open
        case [0x7F], [0x08]:
            self = .erase
        case _ where !bytes.isEmpty && !bytes.contains(where: { $0 < 0x20 || $0 == 0x7F }):
            guard let text = String(validating: bytes, as: UTF8.self) else { return nil }
            self = .type(text)
        default:
            guard bytes.count == 3, bytes[0] == 0x1B, bytes[1] == UInt8(ascii: "[") || bytes[1] == UInt8(ascii: "O") else {
                return nil
            }
            switch bytes[2] {
            case UInt8(ascii: "A"): self = .move(.up)
            case UInt8(ascii: "B"): self = .move(.down)
            case UInt8(ascii: "C"): self = .move(.right)
            case UInt8(ascii: "D"): self = .move(.left)
            default: return nil
            }
        }
    }
}
