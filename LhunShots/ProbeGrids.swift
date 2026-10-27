import XCTest

/// One terminal on screen as the probe reports it.
struct Grid: Equatable, CustomStringConvertible {
    let session: String
    let cols: Int
    let rows: Int
    let font: Int
    let fit: String
    let view: [Double]
    let card: [Double]
    let cell: [Double]

    var description: String {
        "\(session) \(cols)x\(rows) font \(font) view \(view) card \(card) cell \(cell): \(fit)"
    }
}

/// Where the probe saw Lhûn's chrome (`View.probeFrame`), by name, and the window it should lie in, both in
/// the window's own points, with the session whose card has the focus.
struct Chrome: Equatable, CustomStringConvertible {
    let window: CGRect
    let frames: [String: CGRect]
    let selection: String

    var description: String {
        "window \(window.size), focus on \(selection): "
            + frames.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }
}

extension XCTestCase {
    /// The probe's latest sample: seconds since launch, and the terminals on screen.
    @MainActor
    func probeGrids(_ probe: XCUIElement) -> (t: Double, grids: [Grid])? {
        probeSample(probe).map { ($0.t, $0.grids) }
    }

    /// The probe's latest sample: seconds since launch, the terminals on screen, and where the chrome sits.
    @MainActor
    func probeSample(_ probe: XCUIElement) -> (t: Double, grids: [Grid], chrome: Chrome)? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(probe.label.utf8)) as? [String: Any],
              let t = (object["t"] as? NSNumber)?.doubleValue,
              let list = object["grids"] as? [[String: Any]]
        else { return nil }
        let numbers = { (value: Any?) in (value as? [NSNumber] ?? []).map(\.doubleValue) }
        let grids = list.map { grid in
            Grid(
                session: grid["session"] as? String ?? "",
                cols: (grid["cols"] as? NSNumber)?.intValue ?? 0,
                rows: (grid["rows"] as? NSNumber)?.intValue ?? 0,
                font: (grid["font"] as? NSNumber)?.intValue ?? 0,
                fit: grid["fit"] as? String ?? "",
                view: numbers(grid["view"]),
                card: numbers(grid["card"]),
                cell: numbers(grid["cell"])
            )
        }
        let rect = { (value: Any?) -> CGRect? in
            let edges = numbers(value)
            return edges.count == 4 ? CGRect(x: edges[0], y: edges[1], width: edges[2], height: edges[3]) : nil
        }
        let size = numbers(object["window"])
        let chrome = Chrome(
            window: size.count == 2 ? CGRect(x: 0, y: 0, width: size[0], height: size[1]) : .null,
            frames: (object["chrome"] as? [String: Any] ?? [:]).compactMapValues(rect),
            selection: (object["selection"] as? [String: Any])?["name"] as? String ?? ""
        )
        return (t, grids, chrome)
    }
}
