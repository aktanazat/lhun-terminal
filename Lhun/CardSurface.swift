import SwiftUI

/// A card's surface, in the colors of its session's host. In the usual layout it is rounded and set off from
/// the wash by its color alone, with a gutter of wash around it; in the compact layout it is square and edge
/// to edge, and carries on under the home indicator and the hidden keyboard's bar so no strip of wash shows
/// below it. Either way its terminal dims while the other card has the focus, and its text keeps a wider
/// distance from the card there so faint text still reads through the dim (Contrast.swift). The header stays
/// clear of the dim, so the session's name and folder read as well as on the focused card.
struct CardSurface: ViewModifier {
    let compact: Bool
    let dimmed: Bool
    /// The height of the header over the terminal: `CardHeader.height`, or 0 for a card without one.
    let header: CGFloat
    let chrome: Chrome

    /// The wash between two cards, and around them.
    static func gutter(compact: Bool) -> CGFloat { compact ? 0 : Metrics.gutter }
    static func radius(compact: Bool) -> CGFloat { compact ? 0 : Metrics.radius }

    func body(content: Content) -> some View {
        content
            .background(chrome.card)
            .overlay { dim.padding(.top, header) }
            .clipShape(.rect(cornerRadius: Self.radius(compact: compact), style: .continuous))
            .background(alignment: .bottom) {
                if compact {
                    // No taller than the bottom safe area: a line at the card's foot, grown down into it.
                    ZStack {
                        chrome.card
                        dim
                    }
                    .frame(height: 0)
                    .ignoresSafeArea(edges: .bottom)
                }
            }
    }

    private var dim: some View {
        chrome.wash
            .opacity(dimmed ? 0.45 : 0)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.15), value: dimmed)
    }
}

/// The line between two cards in the compact layout, one pixel thick.
struct CardDivider: View {
    /// Between stacked cards the line runs across.
    var across = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Theme.hairline
            .frame(width: across ? nil : 1 / displayScale, height: across ? 1 / displayScale : nil)
            .allowsHitTesting(false)
    }
}
