import CoreText
import UIKit

/// Characters typed and still on their way to the host, drawn over the terminal's cells where they will
/// land, underlined until the host's echo settles them, with the cursor where it will be then
/// (EchoPrediction). It covers only the cells it paints, on one row, and hides while it has none.
final class PredictionView: UIView {
    struct Cell: Equatable {
        enum Look: Equatable {
            /// A guessed character, underlined; or an empty cell where a guess stepped back.
            case guessed
            /// Where the cursor will be.
            case cursor
            /// The terminal's own cell, painted over to hide the terminal's cursor.
            case plain
        }

        let col: Int
        let character: Character?
        let look: Look
    }

    struct Paint: Equatable {
        let row: Int
        let cells: [Cell]
        let cellSize: CGSize
        let font: UIFont
        let foreground: UIColor
        let background: UIColor
        let caret: UIColor
        let caretText: UIColor
    }

    /// What it draws, nil while hidden.
    private(set) var paint: Paint?

    init() {
        super.init(frame: .zero)
        isOpaque = false
        isUserInteractionEnabled = false
        backgroundColor = .clear
        contentMode = .redraw
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The guessed cells it draws.
    var guessedCells: Int { paint?.cells.count(where: { $0.look == .guessed }) ?? 0 }

    /// Shows `paint` over the terminal whose visible top is at `top`, or hides for nil.
    func show(_ paint: Paint?, top: CGFloat) {
        let cols = paint?.cells.map(\.col) ?? []
        guard let paint, let first = cols.min(), let last = cols.max() else {
            self.paint = nil
            isHidden = true
            return
        }
        if paint != self.paint { setNeedsDisplay() }
        self.paint = paint
        frame = CGRect(x: CGFloat(first) * paint.cellSize.width,
                       y: top + CGFloat(paint.row) * paint.cellSize.height,
                       width: CGFloat(last - first + 1) * paint.cellSize.width,
                       height: paint.cellSize.height)
        isHidden = false
    }

    override func draw(_ rect: CGRect) {
        guard let paint, let context = UIGraphicsGetCurrentContext(), let first = paint.cells.map(\.col).min() else { return }
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let cell = paint.cellSize
        // Where SwiftTerm's renderer puts the baseline and the underline (MetalTerminalRenderer).
        let baseline = cell.height - ceil(CTFontGetDescent(paint.font) + CTFontGetLeading(paint.font))
        let thickness = max((scale * 0.63).rounded() / scale, 0.5)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for item in paint.cells {
            let x = CGFloat(item.col - first) * cell.width
            context.setFillColor((item.look == .cursor ? paint.caret : paint.background).cgColor)
            context.fill(CGRect(x: x, y: 0, width: cell.width, height: cell.height))
            guard let character = item.character else { continue }
            let ink = item.look == .cursor ? paint.caretText : paint.foreground
            let text = NSAttributedString(string: String(character), attributes: [
                .font: paint.font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink.cgColor,
            ])
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            if item.look == .guessed {
                context.setFillColor(paint.foreground.cgColor)
                context.fill(CGRect(x: x, y: baseline + 1.2 - thickness / 2, width: ceil(cell.width), height: thickness))
            }
        }
    }
}
