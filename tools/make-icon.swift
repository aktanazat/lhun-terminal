// Lhûn's app icon, kept as an Icon Composer document: flat SVG layers and the icon.json that stacks
// them. Xcode builds every size and appearance (default, dark, clear, tinted) from that document and
// adds the Liquid Glass itself, so the layers carry no highlights, shadows or blur of their own.
//   swift tools/make-icon.swift                         writes LhunApp/AppIcon.icon
//   swift tools/make-icon.swift sheet <dir> [name...]   writes every concept, or the named ones, to <dir>,
//                                                       renders each with Icon Composer's ictool, and lays
//                                                       them out in <dir>/candidates.png
// Run from the repository root.
import AppKit
import Foundation

// MARK: Geometry, on the 1024-point canvas with y running down, as in SVG.

struct V {
    var x: Double
    var y: Double
    init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    static func + (a: V, b: V) -> V { V(a.x + b.x, a.y + b.y) }
    static func - (a: V, b: V) -> V { V(a.x - b.x, a.y - b.y) }
    static func * (a: V, k: Double) -> V { V(a.x * k, a.y * k) }
    var length: Double { (x * x + y * y).squareRoot() }
    var unit: V { self * (1 / length) }
}

/// The point `radius` from `center` at `degrees` counterclockwise from three o'clock, as the eye sees it.
func polar(_ center: V, _ radius: Double, _ degrees: Double) -> V {
    let a = degrees * .pi / 180
    return V(center.x + radius * cos(a), center.y - radius * sin(a))
}

/// Where `point` sits around `center`, in degrees counterclockwise from three o'clock.
func angle(_ point: V, around center: V) -> Double {
    atan2(center.y - point.y, point.x - center.x) * 180 / .pi
}

/// Points along a circular arc, both ends included.
func arc(_ center: V, _ radius: Double, from start: Double, to end: Double, steps: Int = 64) -> [V] {
    (0...steps).map { polar(center, radius, start + (end - start) * Double($0) / Double(steps)) }
}

/// The short arc around `center` from one point to another the same distance away.
func fillet(_ center: V, from a: V, to b: V) -> [V] {
    let start = angle(a, around: center)
    var end = angle(b, around: center)
    if end - start > 180 { end -= 360 }
    if start - end > 180 { end += 360 }
    return arc(center, (a - center).length, from: start, to: end, steps: 16)
}

/// Where two circles cross: the first point is to the left of the line from `a` to `b`, as the eye sees it.
func crossings(_ a: V, _ ra: Double, _ b: V, _ rb: Double) -> (V, V) {
    let d = (b - a).length
    let along = (d * d + ra * ra - rb * rb) / (2 * d)
    let off = (ra * ra - along * along).squareRoot()
    let u = (b - a).unit
    let foot = a + u * along
    let left = V(u.y, -u.x)
    return (foot + left * off, foot - left * off)
}

func cubic(_ p0: V, _ p1: V, _ p2: V, _ p3: V, _ t: Double) -> V {
    let s = 1 - t
    return p0 * (s * s * s) + p1 * (3 * s * s * t) + p2 * (3 * s * t * t) + p3 * (t * t * t)
}

func quadratic(_ p0: V, _ p1: V, _ p2: V, _ t: Double) -> V {
    let s = 1 - t
    return p0 * (s * s) + p1 * (2 * s * t) + p2 * (t * t)
}

func smoothstep(_ x: Double) -> Double {
    let t = min(max(x, 0), 1)
    return t * t * (3 - 2 * t)
}

func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

/// Points along `curve` as t runs from 0 to 1, both ends included.
func sample(_ steps: Int = 240, _ curve: (Double) -> V) -> [V] {
    (0...steps).map { curve(Double($0) / Double(steps)) }
}

/// The path a pen draws by steering: from `start`, heading `heading` degrees clockwise from three
/// o'clock, it turns by `curvature(s)` (one over the radius, clockwise when positive) at each distance s.
func steer(from start: V, heading: Double, length: Double, steps: Int = 300, curvature: (Double) -> Double) -> [V] {
    var p = start, phi = heading * .pi / 180
    var points = [p]
    let ds = length / Double(steps)
    for i in 0..<steps {
        let k = curvature((Double(i) + 0.5) * ds)
        let mid = phi + k * ds / 2
        p = p + V(cos(mid), sin(mid)) * ds
        phi += k * ds
        points.append(p)
    }
    return points
}

/// The outline of a brush stroke along `spine`, `width(t)` across, where t runs from 0 to 1 by
/// distance along it; the ends are round wherever the width is not zero.
func brush(_ spine: [V], width: (Double) -> Double) -> [V] {
    var distance = [0.0]
    for i in 1..<spine.count { distance.append(distance[i - 1] + (spine[i] - spine[i - 1]).length) }
    let total = distance[spine.count - 1]
    let radius = distance.map { width($0 / total) / 2 }
    let side = spine.indices.map { i -> V in
        let along = (spine[min(i + 1, spine.count - 1)] - spine[max(i - 1, 0)]).unit
        return V(along.y, -along.x)
    }
    func cap(_ i: Int, _ outward: V) -> [V] {
        let r = radius[i]
        guard r > 0.5 else { return [] }
        let toward = V(-outward.y, outward.x)
        return (1..<24).map { k in
            let a = Double.pi * Double(k) / 24
            return spine[i] + outward * (r * cos(a)) + toward * (r * sin(a))
        }
    }
    let left = spine.indices.map { spine[$0] + side[$0] * radius[$0] }
    let right = spine.indices.map { spine[$0] - side[$0] * radius[$0] }
    let last = spine.count - 1
    return left + cap(last, side[last]) + right.reversed() + cap(0, side[0] * -1)
}

/// `shape` moved so it looks centered on `center`: halfway between the middle of its bounds and its
/// centroid, since the eye weighs both the outline and the mass.
func centered(_ shape: [V], at center: V = V(512, 512)) -> [V] {
    let xs = shape.map(\.x), ys = shape.map(\.y)
    let bounds = V((xs.min()! + xs.max()!) / 2, (ys.min()! + ys.max()!) / 2)
    var area = 0.0, moment = V(0, 0)
    for (p, q) in zip(shape, shape.dropFirst() + [shape[0]]) {
        let cross = p.x * q.y - q.x * p.y
        area += cross
        moment = moment + (p + q) * cross
    }
    let offset = center - (bounds + moment * (1 / (3 * area))) * 0.5
    return shape.map { $0 + offset }
}

/// A rectangle with continuous corners: each corner is a superellipse quadrant, so the bend eases in
/// from the straight sides as it does on the system's own shapes.
func roundedRect(x: Double, y: Double, width w: Double, height h: Double, radius r: Double) -> [V] {
    let exponent = 2 / 5.0
    func corner(_ c: V, _ start: Double) -> [V] {
        (0...32).map { k in
            let a = (start + 90 * Double(k) / 32) * .pi / 180
            let u = cos(a), v = sin(a)
            return V(c.x + r * copysign(pow(abs(u), exponent), u), c.y - r * copysign(pow(abs(v), exponent), v))
        }
    }
    return corner(V(x + w - r, y + r), 0) + corner(V(x + r, y + r), 90)
        + corner(V(x + r, y + h - r), 180) + corner(V(x + w - r, y + h - r), 270)
}

// MARK: SVG path data

func number(_ v: Double) -> String { String(format: "%.2f", v) }
func point(_ p: V) -> String { "\(number(p.x)) \(number(p.y))" }

/// A closed path of straight segments, short enough to read as curves where the points bend.
func lines(_ p: [V]) -> String { "M" + p.map(point).joined(separator: "L") + "Z" }

/// A closed path that bends smoothly through every point (Catmull-Rom, written as cubic Béziers).
func curves(_ p: [V]) -> String {
    let n = p.count
    var d = "M\(point(p[0]))"
    for i in 0..<n {
        let p0 = p[(i + n - 1) % n], p1 = p[i], p2 = p[(i + 1) % n], p3 = p[(i + 2) % n]
        d += "C\(point(p1 + (p2 - p0) * (1.0 / 6))) \(point(p2 - (p3 - p1) * (1.0 / 6))) \(point(p2))"
    }
    return d + "Z"
}

// MARK: The document

func colorString(_ hex: UInt32) -> String {
    let c = [hex >> 16 & 0xFF, hex >> 8 & 0xFF, hex & 0xFF].map { String(format: "%.5f", Double($0) / 255) }
    return "srgb:\(c.joined(separator: ",")),1.00000"
}

enum Fill {
    case solid(UInt32)
    /// From the first color to the second, between two points given as fractions of the shape's
    /// bounds from its left and top edges; top to bottom unless told otherwise.
    case gradient(UInt32, UInt32, from: (Double, Double) = (0.5, 0), to: (Double, Double) = (0.5, 1))

    var json: Any {
        switch self {
        case .solid(let hex):
            return ["solid": colorString(hex)]
        case let .gradient(a, b, from, to):
            return [
                "linear-gradient": [colorString(a), colorString(b)],
                "orientation": ["start": ["x": from.0, "y": from.1], "stop": ["x": to.0, "y": to.1]],
            ]
        }
    }
}

struct Layer {
    var name: String
    var path: String
    var fill: Fill
    var dark: Fill?
    var opacity = 1.0
    var glass = true
}

struct Group {
    var name: String
    var layers: [Layer]
    var shadow = 0.5
    var translucency: Double?
    var lighting = "combined"
}

struct Icon {
    var name: String
    var line: String
    var background: Fill
    var dark: Fill
    /// Front first, as Icon Composer lists them.
    var groups: [Group]
}

func json(_ icon: Icon) -> [String: Any] {
    [
        "fill-specializations": [["value": icon.background.json], ["appearance": "dark", "value": icon.dark.json]],
        "groups": icon.groups.map { group -> [String: Any] in
            [
                "name": group.name,
                "lighting": group.lighting,
                "specular": true,
                "blur-material": NSNull(),
                "shadow": ["kind": group.shadow > 0 ? "neutral" : "none", "opacity": group.shadow],
                "translucency": ["enabled": group.translucency != nil, "value": group.translucency ?? 0.5],
                "layers": group.layers.map { layer -> [String: Any] in
                    var l: [String: Any] = [
                        "name": layer.name,
                        "image-name": "\(layer.name).svg",
                        "glass": layer.glass,
                        "opacity": layer.opacity,
                    ]
                    if let dark = layer.dark {
                        l["fill-specializations"] = [["value": layer.fill.json], ["appearance": "dark", "value": dark.json]]
                    } else {
                        l["fill"] = layer.fill.json
                    }
                    return l
                },
            ]
        },
        "supported-platforms": ["squares": "shared"],
    ]
}

func write(_ icon: Icon, to bundle: URL) throws {
    let files = FileManager.default
    let assets = bundle.appending(path: "Assets")
    try files.createDirectory(at: assets, withIntermediateDirectories: true)
    let layers = icon.groups.flatMap(\.layers)
    // A layer the icon no longer has goes to the Trash rather than lingering in the bundle.
    for stale in try files.contentsOfDirectory(atPath: assets.path) where !layers.contains(where: { "\($0.name).svg" == stale }) {
        try files.trashItem(at: assets.appending(path: stale), resultingItemURL: nil)
    }
    for layer in layers {
        // The color here is only what Icon Composer shows before the fill in icon.json applies.
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\
        <path d="\(layer.path)" fill="#808080"/></svg>

        """
        try Data(svg.utf8).write(to: assets.appending(path: "\(layer.name).svg"))
    }
    let data = try JSONSerialization.data(withJSONObject: json(icon), options: [.prettyPrinted, .sortedKeys])
    try (data + Data("\n".utf8)).write(to: bundle.appending(path: "icon.json"))
}

// MARK: Palette: Mies, and the sea.

let foam: UInt32 = 0xF4F1EA
let sand: UInt32 = 0xE9DDC4
let washTop: UInt32 = 0xEEEBF1
let washBottom: UInt32 = 0xF3F0E8
let nightTop: UInt32 = 0x1D1C21
let nightBottom: UInt32 = 0x121211

// MARK: Concepts

/// Two headlands seen from above, a prompt's chevron, with still water inside and the mouth at its point.
func headlands() -> Icon {
    func headland(_ from: V, _ via: V, _ to: V) -> String {
        curves(brush(sample { quadratic(from, via, to, $0) }) { mix(178, 112, smoothstep($0)) })
    }
    return Icon(
        name: "headlands", line: "Two headlands from above make a prompt's chevron; still water inside, the mouth at its point.",
        background: .gradient(0x6C9C98, 0x143840, from: (0.15, 0.5), to: (0.95, 0.5)),
        dark: .gradient(0x355A58, 0x0B1E22, from: (0.15, 0.5), to: (0.95, 0.5)),
        groups: [Group(name: "land", layers: [
            Layer(name: "north", path: headland(V(-90, 110), V(360, 250), V(704, 436)), fill: .solid(sand)),
            Layer(name: "south", path: headland(V(-90, 914), V(360, 774), V(704, 588)), fill: .solid(sand)),
        ], lighting: "individual")]
    )
}

/// A crescent shore cradling a round lagoon, lighter than the sea outside it.
func crescent() -> Icon {
    let shore = V(468, 512), lagoon = V(548, 512)
    let (top, bottom) = crossings(shore, 318, lagoon, 256)
    let outer = angle(top, around: shore), inner = angle(top, around: lagoon)
    let land = arc(shore, 318, from: outer, to: 360 - outer) + arc(lagoon, 256, from: 360 - inner, to: inner)
    _ = bottom
    let water = arc(lagoon, 232, from: 0, to: 360).dropLast()
    return Icon(
        name: "crescent", line: "A crescent shore cradles a round lagoon, paler and calmer than the sea outside.",
        background: .gradient(0x24545A, 0x0E282E), dark: .gradient(0x16302F, 0x081416),
        groups: [
            Group(name: "shore", layers: [Layer(name: "shore", path: lines(land), fill: .solid(sand))]),
            Group(name: "lagoon", layers: [Layer(
                name: "lagoon", path: curves(Array(water)),
                fill: .gradient(0xB6D9D2, 0x5A9893, from: (0.2, 0.1), to: (0.8, 0.9)), opacity: 0.9
            )], translucency: 0.4),
        ]
    )
}

/// The shell's sign for home, ~, drawn as one calm wave.
func tilde() -> Icon {
    let wave = brush(sample { t in V(236 + 552 * t, 512 - 84 * sin(2 * .pi * t)) }) { _ in 132 }
    return Icon(
        name: "tilde", line: "The shell's sign for home, ~, drawn as one calm wave.",
        background: .gradient(washTop, washBottom), dark: .gradient(nightTop, nightBottom),
        groups: [Group(name: "wave", layers: [Layer(
            name: "wave", path: curves(wave), fill: .gradient(0x5E9C97, 0x24585C), dark: .gradient(0x8FC2BC, 0x4F8A87)
        )])]
    )
}

/// A cursor and its reflection: water this still only lies in a cove.
func mirror() -> Icon {
    let cursor = roundedRect(x: 452, y: 268, width: 120, height: 252, radius: 36)
    let bands = [(576.0, 64.0), (650, 50), (712, 38), (764, 26)].map { y, height in
        lines(roundedRect(x: 452, y: y, width: 120, height: height, radius: min(18, height / 2)))
    }.joined()
    return Icon(
        name: "mirror", line: "A cursor and its reflection: water this still only lies in a cove.",
        background: .gradient(0xF1EEF3, 0xE3ECEA), dark: .gradient(nightTop, 0x0F1A1A),
        groups: [Group(name: "cursor", layers: [
            Layer(name: "cursor", path: lines(cursor), fill: .solid(0x2A5558), dark: .solid(0xA9CFCB)),
            Layer(name: "reflection", path: bands, fill: .solid(0x2A5558), dark: .solid(0xA9CFCB), opacity: 0.32, glass: false),
        ])]
    )
}

/// The round cove with the narrow mouth, as Lulworth looks from the air: land all round, sea beyond.
func lulworth() -> Icon {
    let c = V(512, 430), r = 236.0, left = 466.0, right = 558.0, sea = 872.0, f = 36.0
    // Where the neck meets the bay: a fillet circle touching the bay's edge and the neck's wall.
    let dy = ((r + f) * (r + f) - (c.x - (left - f)) * (c.x - (left - f))).squareRoot()
    let westFillet = V(left - f, c.y + dy), eastFillet = V(right + f, c.y + dy)
    let westBay = c + (westFillet - c) * (r / (r + f)), eastBay = c + (eastFillet - c) * (r / (r + f))
    var water: [V] = [V(-40, 1064), V(-40, sea)]
    water += fillet(V(left - f, sea - f), from: V(left - f, sea), to: V(left, sea - f))
    water += fillet(westFillet, from: V(left, westFillet.y), to: westBay)
    water += arc(c, r, from: angle(westBay, around: c), to: angle(eastBay, around: c) - 360, steps: 160)
    water += fillet(eastFillet, from: eastBay, to: V(right, eastFillet.y))
    water += fillet(V(right + f, sea - f), from: V(right, sea - f), to: V(right + f, sea))
    water += [V(1064, sea), V(1064, 1064)]
    return Icon(
        name: "lulworth", line: "The round cove with a narrow mouth, as Lulworth looks from the air.",
        background: .gradient(0xF4ECDD, 0xE6D6B8), dark: .gradient(0x2A2620, 0x171511),
        groups: [Group(name: "water", layers: [Layer(
            name: "water", path: lines(water), fill: .gradient(0x8CC3BC, 0x2E6A6E), dark: .gradient(0x6FA9A3, 0x1E4A4E)
        )])]
    )
}

/// The icon Lhûn ships: one brush stroke that is a wave and a C. It starts as a thin wake at the lower
/// right, runs round the back of the wave and over the crest, and curls its lip over the hollow.
func wave() -> Icon {
    // The back of the wave turns 240 degrees, gently at first and tighter toward the crest, so the
    // wave leans forward; the bend then tightens over 120 points into a lip of radius 65 that turns
    // 135 degrees more.
    let radius = 250.0, sweep = 240.0, lean = 0.75, lip = 65.0, ease = 120.0, hook = 135.0
    let back = radius * sweep * .pi / 180
    let crest = (1 + lean / 2) / radius
    let spine = steer(from: V(0, 0), heading: 360 - sweep, length: back + ease + lip * hook * .pi / 180) { s in
        s < back ? (1 - lean / 2 + lean * s / back) / radius : mix(crest, 1 / lip, smoothstep((s - back) / ease))
    }
    // Thin at the wake, full along the back, thinning over the crest to a round tip.
    let stroke = brush(spine) { t in 168 * mix(0.13, 1, smoothstep(t / 0.35)) * mix(1, 0.18, smoothstep((t - 0.55) / 0.45)) }
    return Icon(
        name: "wave", line: "One brush stroke: a wave rises, crests and curls its lip over the hollow, and the stroke is a C.",
        background: .gradient(0x4A8F8B, 0x0A2328), dark: .gradient(0x1B3034, 0x0A1416),
        groups: [Group(name: "wave", layers: [Layer(name: "wave", path: curves(centered(stroke)), fill: .gradient(foam, 0x9FC9C3))])]
    )
}

/// The view out of a cove at dusk: two headlands on the horizon frame the mouth, and the cursor is
/// the sun going down in the gap, laying a path of light across the water.
func dusk() -> Icon {
    let horizon = 600.0
    var west: [V] = [V(-40, 616), V(-40, 470)]
    west += sample(40) { cubic(V(-40, 470), V(110, 436), V(250, 452), V(330, 514), $0) }
    west += sample(40) { cubic(V(330, 514), V(372, 546), V(398, 590), V(418, 616), $0) }
    var east: [V] = [V(1064, 616), V(1064, 530)]
    east += sample(40) { cubic(V(1064, 530), V(930, 512), V(800, 520), V(730, 556), $0) }
    east += sample(40) { cubic(V(730, 556), V(680, 580), V(632, 600), V(606, 616), $0) }
    let sea = lines([V(-40, horizon), V(1064, horizon), V(1064, 1064), V(-40, 1064)])
    // The sun stands in the sea, which hides its foot.
    let sun = roundedRect(x: 445, y: 372, width: 134, height: 290, radius: 36)
    let glint = [(134.0, 626.0), (100, 654), (66, 680)].map { width, y in
        lines(roundedRect(x: 512 - width / 2, y: y, width: width, height: 12, radius: 6))
    }.joined()
    return Icon(
        name: "dusk", line: "Looking out of a cove at dusk: headlands frame the mouth, and the cursor is the sun setting in the gap.",
        background: .gradient(0x253049, 0xF2B38A, from: (0.5, 0), to: (0.5, 0.59)),
        dark: .gradient(0x10141F, 0x4A3640, from: (0.5, 0), to: (0.5, 0.59)),
        groups: [
            Group(name: "headlands", layers: [Layer(name: "headlands", path: lines(west) + lines(east), fill: .solid(0x1B1F30))]),
            Group(name: "glint", layers: [Layer(name: "glint", path: glint, fill: .solid(0xF6C98A), opacity: 0.6, glass: false)], shadow: 0),
            Group(name: "sea", layers: [Layer(name: "sea", path: sea, fill: .gradient(0x6E6170, 0x121624), glass: false)], shadow: 0),
            Group(name: "sun", layers: [Layer(name: "sun", path: lines(sun), fill: .gradient(0xFFF4DC, 0xF4BB6C))]),
        ]
    )
}

/// The icon Lhûn ships.
let appIcon = wave()
/// Every concept the sheet shows, the shipped one first.
let concepts = [appIcon, dusk(), headlands(), crescent(), tilde(), mirror(), lulworth()]

// MARK: Rendering, with the ictool inside Xcode's Icon Composer

func ictool() -> String {
    let select = Process()
    let pipe = Pipe()
    select.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    select.arguments = ["-p"]
    select.standardOutput = pipe
    try! select.run()
    select.waitUntilExit()
    let developer = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return URL(fileURLWithPath: developer).deletingLastPathComponent()
        .appending(path: "Applications/Icon Composer.app/Contents/Executables/ictool").path
}

func render(_ bundle: URL, _ rendition: String, points: Int, scale: Int, to file: URL) {
    let run = Process()
    run.executableURL = URL(fileURLWithPath: ictool())
    run.arguments = [
        bundle.path, "--export-image", "--output-file", file.path, "--platform", "iOS", "--rendition", rendition,
        "--width", "\(points)", "--height", "\(points)", "--scale", "\(scale)",
    ]
    run.standardOutput = FileHandle.nullDevice
    try! run.run()
    run.waitUntilExit()
    guard run.terminationStatus == 0, let _ = NSImage(contentsOf: file) else {
        fatalError("ictool could not render \(bundle.lastPathComponent) as \(rendition)")
    }
}

// MARK: The contact sheet

/// A home-screen neighbor: a system app's icon, cut out of the margin macOS draws around it.
func neighbor(_ path: String) -> NSImage {
    let icon = NSWorkspace.shared.icon(forFile: path)
    let image = NSImage(size: NSSize(width: 824, height: 824))
    image.lockFocus()
    icon.draw(in: NSRect(x: -100, y: -100, width: 1024, height: 1024))
    image.unlockFocus()
    return image
}

func makeSheet(_ icons: [Icon], renders: URL, to file: URL) throws {
    let big = 300.0, pad = 24.0, label = 300.0, panel = 500.0
    let rowHeight = big + pad * 2
    let width = label + 3 * (big + pad) + 2 * (panel + pad) + pad
    let height = 120 + rowHeight * Double(icons.count)
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    bitmap.size = NSSize(width: width, height: height)
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
    let cg = context.cgContext
    cg.translateBy(x: 0, y: height)
    cg.scaleBy(x: 1, y: -1)

    func fill(_ rect: NSRect, _ hex: UInt32) {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1).setFill()
        rect.fill()
    }
    func gradient(_ rect: NSRect, _ top: UInt32, _ bottom: UInt32) {
        func color(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        NSGradient(starting: color(top), ending: color(bottom))!.draw(in: rect, angle: 90)
    }
    func text(_ string: String, at rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .black,
              center: Bool = false) {
        let style = NSMutableParagraphStyle()
        style.alignment = center ? .center : .left
        string.draw(in: rect, withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style,
        ])
    }
    func image(_ url: URL, _ rect: NSRect) {
        NSImage(contentsOf: url)!.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
    func homeScreen(_ origin: NSPoint, dark: Bool, icon: Icon) {
        let rect = NSRect(x: origin.x, y: origin.y, width: panel, height: big)
        if dark { gradient(rect, 0x1B2233, 0x07080C) } else { gradient(rect, 0xC9D7EA, 0xF1E3D6) }
        let ink: NSColor = dark ? .white : NSColor(white: 0.1, alpha: 1)
        // A row of 60-point icons at 2x, Lhûn among real ones, as on an iPad's home screen.
        let apps = [("Safari", "/Applications/Safari.app"), ("Lhûn", ""),
                    ("Terminal", "/System/Applications/Utilities/Terminal.app"), ("Notes", "/System/Applications/Notes.app")]
        for (i, (name, path)) in apps.enumerated() {
            let frame = NSRect(x: origin.x + 18 + Double(i) * 122, y: origin.y + 14, width: 120, height: 120)
            if path.isEmpty {
                image(renders.appending(path: "\(icon.name)-\(dark ? "Dark" : "Default")-60@2x.png"), frame)
            } else {
                neighbor(path).draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            text(name, at: NSRect(x: frame.minX - 10, y: origin.y + 140, width: 140, height: 24), size: 19, color: ink, center: true)
        }
        // A 29-point row, as Settings and Spotlight show it.
        let row = NSRect(x: origin.x + 22, y: origin.y + 190, width: panel - 44, height: 84)
        NSColor(white: dark ? 0.12 : 1, alpha: dark ? 0.9 : 0.85).setFill()
        NSBezierPath(roundedRect: row, xRadius: 22, yRadius: 22).fill()
        image(renders.appending(path: "\(icon.name)-\(dark ? "Dark" : "Default")-29@2x.png"), NSRect(x: row.minX + 26, y: row.minY + 13, width: 58, height: 58))
        text("Lhûn", at: NSRect(x: row.minX + 104, y: row.minY + 26, width: 200, height: 34), size: 26, color: ink)
    }

    fill(NSRect(x: 0, y: 0, width: width, height: height), 0xF5F5F4)
    text("Lhûn icon candidates, rendered by Icon Composer's ictool: default, dark and tinted at 1024 px; on home screens at 60 pt and 29 pt (2x, actual size)",
         at: NSRect(x: pad, y: 36, width: width - 2 * pad, height: 40), size: 26, weight: .semibold)
    for (row, icon) in icons.enumerated() {
        let y = 120 + Double(row) * rowHeight + pad
        let title = icon.name == appIcon.name ? "\(icon.name), shipped" : icon.name
        text(title, at: NSRect(x: pad, y: y + 10, width: label - pad * 2, height: 40), size: 30, weight: .bold)
        text(icon.line, at: NSRect(x: pad, y: y + 56, width: label - pad * 2, height: big - 56), size: 20, color: .darkGray)
        var x = label
        for (rendition, backdrop) in [("Default", UInt32(0xE4E4E2)), ("Dark", 0x161616), ("TintedDark", 0x161616)] {
            fill(NSRect(x: x, y: y, width: big, height: big), backdrop)
            image(renders.appending(path: "\(icon.name)-\(rendition)-1024.png"), NSRect(x: x + 10, y: y + 10, width: big - 20, height: big - 20))
            x += big + pad
        }
        homeScreen(NSPoint(x: x, y: y), dark: false, icon: icon)
        homeScreen(NSPoint(x: x + panel + pad, y: y), dark: true, icon: icon)
    }
    NSGraphicsContext.current = nil
    try bitmap.representation(using: .png, properties: [:])!.write(to: file)
}

// MARK: Commands

let arguments = CommandLine.arguments.dropFirst()
if arguments.first == "sheet" {
    guard let dir = arguments.dropFirst().first else { fatalError("usage: swift tools/make-icon.swift sheet <dir> [name...]") }
    let out = URL(fileURLWithPath: dir)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let names = Set(arguments.dropFirst(2))
    let picked = names.isEmpty ? concepts : concepts.filter { names.contains($0.name) }
    for icon in picked {
        let bundle = out.appending(path: "\(icon.name).icon")
        try write(icon, to: bundle)
        for rendition in ["Default", "Dark", "TintedDark"] {
            render(bundle, rendition, points: 1024, scale: 1, to: out.appending(path: "\(icon.name)-\(rendition)-1024.png"))
        }
        for rendition in ["Default", "Dark"] {
            for points in [60, 29] {
                render(bundle, rendition, points: points, scale: 2, to: out.appending(path: "\(icon.name)-\(rendition)-\(points)@2x.png"))
            }
        }
    }
    try makeSheet(picked, renders: out, to: out.appending(path: "candidates.png"))
    print("wrote \(out.appending(path: "candidates.png").path)")
} else {
    try write(appIcon, to: URL(fileURLWithPath: "LhunApp/AppIcon.icon"))
    print("wrote LhunApp/AppIcon.icon")
}
