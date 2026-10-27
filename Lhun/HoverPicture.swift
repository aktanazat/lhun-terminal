import SwiftUI

/// With a trackpad or mouse, the pointer resting half a second on a session's pill or sidebar row shows a
/// small picture of that session's screen, captured and painted as the peek paints its pictures, until the
/// pointer leaves. Nothing is captured before the pointer rests, and the picture is let go as it leaves;
/// without a pointer nothing here runs.
@MainActor @Observable
final class HoverPicture {
    /// Under a pill in the strip, or right of a row in the sidebar.
    enum Place {
        case below
        case beside
    }

    struct Shown {
        let ref: SessionRef
        let picture: CGImage
        /// In points: the screen's shape at a set width.
        let size: CGSize
    }

    /// How long the pointer rests before the picture is taken.
    static let delay: Duration = .milliseconds(500)
    private nonisolated static let width: CGFloat = 400
    private nonisolated static let heights: ClosedRange<CGFloat> = 160...300

    /// What the probe reports: screens captured since launch, and the session pictured now with the
    /// picture's pixels, or none.
    private(set) static var measurements: [String: Any] = ["captures": 0]
    private static var captures = 0

    private(set) var shown: Shown?
    @ObservationIgnored private var resting: SessionRef?
    @ObservationIgnored private var work: Task<Void, Never>?

    /// The pointer came to `ref`: its picture shows once the pointer has rested there.
    func rest(on ref: SessionRef, link: HostLink, dark: Bool, scale: CGFloat, font: TerminalFont) {
        guard ref != resting else { return }
        clear()
        resting = ref
        let palette = ThemeStore.shared.palette(for: ref.host, dark: dark)
        work = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled else { return }
            Self.captures += 1
            Self.measurements = ["captures": Self.captures]
            guard let output = try? await link.run(Tmux.capture(screenOf: ref.name), timeout: .seconds(5)) else { return }
            let painted = await Task.detached(priority: .userInitiated) {
                HoverPicture.paint(output, palette: palette, font: font, scale: scale)
            }.value
            guard let self, !Task.isCancelled, let painted else { return }
            self.shown = Shown(ref: ref, picture: painted.picture, size: painted.size)
            Self.measurements = [
                "captures": Self.captures,
                "session": "\(ref.host).\(ref.name)",
                "pixels": painted.picture.width * painted.picture.height,
            ]
        }
    }

    /// The pointer left `ref`: its picture goes, and so does a capture still on its way.
    func leave(_ ref: SessionRef) {
        guard ref == resting else { return }
        clear()
    }

    private func clear() {
        work?.cancel()
        work = nil
        resting = nil
        shown = nil
        Self.measurements = ["captures": Self.captures]
    }

    /// The captured screen, painted at the set width and as tall as its shape asks, within bounds.
    private nonisolated static func paint(
        _ output: String, palette: Theme.Palette, font: TerminalFont, scale: CGFloat
    ) -> (picture: CGImage, size: CGSize)? {
        guard let screen = Tmux.parseScreens(output).first else { return nil }
        let height = (width / PeekPainter.aspect(of: screen, font: font)).rounded()
        let size = CGSize(width: width, height: min(max(height, heights.lowerBound), heights.upperBound))
        guard let picture = PeekPainter.picture(of: screen, palette: palette, font: font, size: size, scale: scale)
        else { return nil }
        return (picture, size)
    }
}

extension AppModel {
    /// The pointer came to a session's pill or row. A session on screen is its own picture, and a host that
    /// is not online is not asked.
    fileprivate func restPointer(on ref: SessionRef, dark: Bool, scale: CGFloat) {
        guard !shownPanes.contains(ref), let link = link(for: ref), link.status == .online else { return }
        hover.rest(on: ref, link: link, dark: dark, scale: scale, font: terminalFont)
    }
}

extension View {
    /// The pointer resting on this view shows a picture of `ref`'s screen `place`d by it.
    func hoverPicture(_ ref: SessionRef, place: HoverPicture.Place) -> some View {
        modifier(HoverSource(ref: ref, place: place))
    }

    /// `perform` hears the pointer come to this view, `ref`'s pill or row, and leave it: a trackpad's or
    /// mouse's, or the probe's standing in for one in a UI test (`Probe.pointer`).
    func onPointer(over ref: SessionRef, perform: @escaping (Bool) -> Void) -> some View {
        modifier(PointerOver(ref: ref, perform: perform))
    }
}

private struct PointerOver: ViewModifier {
    let ref: SessionRef
    let perform: (Bool) -> Void
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .onHover(perform: perform)
            .onChange(of: model.probe?.pointer == ref) { _, inside in perform(inside) }
    }
}

/// Where the pill or row under the pointer sits. Only that one says.
struct HoverSpot: PreferenceKey {
    struct Spot {
        let ref: SessionRef
        let place: HoverPicture.Place
        let bounds: Anchor<CGRect>
    }

    static var defaultValue: Spot? { nil }

    static func reduce(value: inout Spot?, nextValue: () -> Spot?) {
        value = value ?? nextValue()
    }
}

private struct HoverSource: ViewModifier {
    let ref: SessionRef
    let place: HoverPicture.Place
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @State private var inside = false

    func body(content: Content) -> some View {
        content
            .onPointer(over: ref) { inside in
                self.inside = inside
                if inside {
                    model.restPointer(on: ref, dark: colorScheme == .dark, scale: displayScale)
                } else {
                    model.hover.leave(ref)
                }
            }
            // A row that goes while the pointer is on it, its session killed or the sidebar hidden, hears
            // no leaving.
            .onDisappear {
                if inside { model.hover.leave(ref) }
            }
            .anchorPreference(key: HoverSpot.self, value: .bounds) { bounds in
                inside ? HoverSpot.Spot(ref: ref, place: place, bounds: bounds) : nil
            }
    }
}

/// The picture, over the strip, the sidebar and the cards, by the pill or row the pointer rests on. It
/// takes no touches.
struct HoverPictureLayer: View {
    let spot: HoverSpot.Spot?
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { proxy in
            if let spot, let shown = model.hover.shown, shown.ref == spot.ref {
                HoverCard(shown: shown)
                    .position(Self.center(of: shown.size, place: spot.place, by: proxy[spot.bounds], in: proxy.size))
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.15), value: model.hover.shown?.ref)
    }

    /// Below a pill and centered on it, or right of a row and level with it, inside the window either way.
    private static func center(of picture: CGSize, place: HoverPicture.Place, by source: CGRect, in area: CGSize) -> CGPoint {
        let half = CGSize(width: picture.width / 2 + HoverCard.frame, height: picture.height / 2 + HoverCard.frame)
        let margin = Metrics.near
        func clamp(_ value: CGFloat, _ half: CGFloat, within length: CGFloat) -> CGFloat {
            max(min(value, length - margin - half), margin + half)
        }
        switch place {
        case .below:
            return CGPoint(x: clamp(source.midX, half.width, within: area.width), y: source.maxY + margin + half.height)
        case .beside:
            return CGPoint(x: source.maxX + margin + half.width, y: clamp(source.midY, half.height, within: area.height))
        }
    }
}

private struct HoverCard: View {
    /// The raised edge around the picture. The picture's corners are rounded less by as much, so they stay
    /// concentric with the card's.
    static let frame = Metrics.near
    let shown: HoverPicture.Shown
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Image(decorative: shown.picture, scale: displayScale)
            .resizable()
            .interpolation(.high)
            .frame(width: shown.size.width, height: shown.size.height)
            .clipShape(.rect(cornerRadius: Metrics.radius(inside: Self.frame), style: .continuous))
            .padding(Self.frame)
            .background(Theme.raised, in: .rect(cornerRadius: Metrics.radius, style: .continuous))
            .lifted()
            .accessibilityElement()
            .accessibilityLabel("\(shown.ref.name)’s screen")
            .accessibilityIdentifier("hover")
            .accessibilityValue("\(shown.ref.host).\(shown.ref.name)")
    }
}
