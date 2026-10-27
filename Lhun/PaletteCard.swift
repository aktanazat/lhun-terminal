import SwiftUI
import UIKit

/// The card the palette, the path picker, the theme picker and the inbox share: a search field over a
/// list, floating on a dimmed backdrop that closes it when tapped. The arrow keys move the highlight,
/// Return runs it, and Esc closes. Only the rows in sight are drawn, however many it lists.
/// The card hangs just under the strip, and its list never runs past the room above the keyboard, so the
/// card's foot always shows and the card stays put as the keyboard comes and goes.
struct PaletteCard<Leading: View, Rows: View>: View {
    let prompt: String
    @Binding var query: String
    /// Names the field for UI tests, and the card after it: "<fieldID>.card".
    let fieldID: String
    /// The highlighted row's id; the list scrolls to keep it in view.
    let highlightedID: String?
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onClose: () -> Void
    /// Backspace on a hardware keyboard with nothing typed.
    let onDeleteEmpty: (() -> Void)?
    /// Tab, 1, or Shift-Tab, -1, for a list that jumps between its groups.
    let onTab: ((Int) -> Void)?
    /// The tallest the list grows before it scrolls, room allowing.
    let rowsHeight: CGFloat
    /// Keeping it still leaves the field as it is. Each change gives the field the keyboard again, the way
    /// the card takes it when it opens: for a sheet that took the keyboard and has gone, as the theme
    /// picker's file importer does.
    let focusRequest: Int
    let leading: Leading
    let rows: Rows
    @FocusState private var focused: Bool
    @Environment(AppModel.self) private var model

    init(
        prompt: String,
        query: Binding<String>,
        fieldID: String,
        highlightedID: String?,
        onMove: @escaping (Int) -> Void,
        onSubmit: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onDeleteEmpty: (() -> Void)? = nil,
        onTab: ((Int) -> Void)? = nil,
        rowsHeight: CGFloat = 360,
        focusRequest: Int = 0,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder rows: () -> Rows
    ) {
        self.prompt = prompt
        _query = query
        self.fieldID = fieldID
        self.highlightedID = highlightedID
        self.onMove = onMove
        self.onSubmit = onSubmit
        self.onClose = onClose
        self.onDeleteEmpty = onDeleteEmpty
        self.onTab = onTab
        self.rowsHeight = rowsHeight
        self.focusRequest = focusRequest
        self.leading = leading()
        self.rows = rows()
    }

    // Computed: a generic type can't store statics.
    /// From the top of the screen's safe area to the card, 8 points under the strip.
    private static var top: CGFloat { 56 }
    private static var fieldHeight: CGFloat { 48 }
    /// Room kept below the card, above the keyboard or the screen's foot.
    private static var foot: CGFloat { Metrics.near }

    var body: some View {
        GeometryReader { space in
            ZStack(alignment: .top) {
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onClose)
                VStack(spacing: 0) {
                    HStack(spacing: Metrics.near) {
                        leading
                        TextField(prompt, text: $query)
                            .font(.body)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focused)
                            .accessibilityIdentifier(fieldID)
                            .onSubmit(onSubmit)
                            .onKeyPress(.downArrow) {
                                onMove(1)
                                return .handled
                            }
                            .onKeyPress(.upArrow) {
                                onMove(-1)
                                return .handled
                            }
                            .onKeyPress(.escape) {
                                onClose()
                                return .handled
                            }
                            .onKeyPress(.delete) {
                                guard query.isEmpty, let onDeleteEmpty else { return .ignored }
                                onDeleteEmpty()
                                return .handled
                            }
                            .onKeyPress(.tab, phases: .down) { press in
                                guard let onTab else { return .ignored }
                                onTab(press.modifiers.contains(.shift) ? -1 : 1)
                                return .handled
                            }
                    }
                    .padding(.horizontal, Metrics.inset)
                    .frame(height: Self.fieldHeight)
                    // A bar of fixed height: its text grows only as far as the bar holds it.
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) { rows }
                                .padding(Metrics.rowInset)
                        }
                        // At least a row and a half shows, so the list reads as one that scrolls.
                        .frame(maxHeight: max(min(rowsHeight, space.size.height - Self.top - Self.fieldHeight - Self.foot), Metrics.touch * 1.5))
                        .fixedSize(horizontal: false, vertical: true)
                        .onChange(of: highlightedID) { _, id in
                            if let id { proxy.scrollTo(id) }
                        }
                    }
                }
                .frame(maxWidth: 560)
                .background(Theme.raised, in: .rect(cornerRadius: Metrics.radius, style: .continuous))
                .lifted()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("\(fieldID).card")
                .probeFrame("\(fieldID).card")
                .padding(.horizontal, Metrics.inset)
                .padding(.top, Self.top)
            }
            .frame(width: space.size.width, height: space.size.height, alignment: .top)
        }
        .onAppear {
            model.keyboardAway = true
            // The field takes the keyboard at the next frame, with the card on screen: taking it costs the iPad
            // about 60 ms, and taken here, in the card's own update, it would hold the card back as long.
            NextFrame.wait { _ in focused = true }
        }
        // However it closes, a session it opened takes the keyboard once it has gone: that terminal comes
        // on screen in the same update, too late to take it from the field as the overlay closes.
        .onDisappear { model.focusTerminal() }
        // A sheet that took the keyboard has gone: the field takes it back the way it does when the card opens.
        .onChange(of: focusRequest) {
            focused = false
            NextFrame.wait { _ in focused = true }
        }
    }
}

extension PaletteCard where Leading == EmptyView {
    init(
        prompt: String,
        query: Binding<String>,
        fieldID: String,
        highlightedID: String?,
        onMove: @escaping (Int) -> Void,
        onSubmit: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onDeleteEmpty: (() -> Void)? = nil,
        onTab: ((Int) -> Void)? = nil,
        rowsHeight: CGFloat = 360,
        focusRequest: Int = 0,
        @ViewBuilder rows: () -> Rows
    ) {
        self.init(
            prompt: prompt, query: query, fieldID: fieldID, highlightedID: highlightedID, onMove: onMove,
            onSubmit: onSubmit, onClose: onClose, onDeleteEmpty: onDeleteEmpty, onTab: onTab, rowsHeight: rowsHeight,
            focusRequest: focusRequest, leading: { EmptyView() }, rows: rows
        )
    }
}

/// The hairline between one group of rows and the next: 16 points between the groups, the line in the
/// middle, in line with the rows' text.
struct PaletteDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 0.5)
            .padding(.horizontal, Metrics.inset - Metrics.rowInset)
            .padding(.vertical, Metrics.apart / 2)
            .accessibilityHidden(true)
    }
}

extension View {
    /// A palette row's shape: at least 44 points tall, a full touch target, its text 16 points in from the
    /// card's edge, softly filled while highlighted, the fill's corners following the card's.
    func paletteRow(isHighlighted: Bool) -> some View {
        padding(.horizontal, Metrics.inset - Metrics.rowInset)
            .frame(minHeight: Metrics.touch)
            .background(
                isHighlighted ? Theme.pill : .clear,
                in: .rect(cornerRadius: Metrics.radius(inside: Metrics.rowInset), style: .continuous)
            )
            .contentShape(.rect)
    }
}

extension AppModel {
    /// Gives the keyboard back to the open session's terminal once what held it has gone, an overlay, a
    /// preview, an alert or the share sheet, unless what it ran put something else that takes typing in its
    /// place: it waits for the caller to finish.
    func focusTerminal() {
        Task { takeKeyboardBack() }
    }

    /// The open session's terminal takes the keyboard now, unless an overlay, an alert or the key sheet
    /// takes typing. The terminals keep their grids (`keyboardAway`) until the keyboard is back and has
    /// stopped moving, or let go at once when nothing takes it back; an overlay still up keeps them. A
    /// terminal not on screen yet, a session the overlay opened, takes it once the overlay has gone.
    func takeKeyboardBack() {
        let overlay = pathPicker != nil || inbox != nil || themePicker != nil || showingPalette || akylPresented
        guard !overlay, let terminal = selectedTerminal, renaming == nil, killing == nil, renamingWindow == nil, !showingKey
        else {
            if !overlay { keyboardAway = false }
            return
        }
        if terminal.view.window != nil { _ = terminal.view.becomeFirstResponder() }
        Task {
            await keyboardMotion.stillness()
            if pathPicker == nil, inbox == nil, themePicker == nil, !showingPalette, !akylPresented { keyboardAway = false }
        }
    }
}

/// Follows the on-screen keyboard through UIKit's notifications: the room it takes at the foot of the
/// window, which the cards keep clear of (`inset`), where its latest move ends (`heading`), and when it
/// has stopped moving.
@MainActor
@Observable
final class KeyboardMotion: NSObject {
    /// How far the keyboard reaches above the window's bottom safe area, frame for frame as it moves. A
    /// view no one sees runs each move on the duration and curve UIKit gives the keyboard, and each frame
    /// `inset` takes where that view will be as the frame shows. SwiftUI's own keyboard room ran on a curve
    /// of its own: coming up, the cards stopped 11 frames before the keyboard did, and going down they
    /// stayed 34 points short of the foot until the key row had gone, then jumped there. A SwiftUI spring
    /// fitted to the keyboard's set off a frame late and came to rest 20 frames after it.
    private(set) var inset: CGFloat = 0
    /// The room the keyboard's latest move ends at: `inset` once it has stopped.
    private(set) var heading: CGFloat = 0
    /// The screen width the last accepted keyboard report belongs to, so a turn waits for its new report.
    private(set) var screenWidth: CGFloat = 0
    /// Where the keyboard's latest move ends, until it gets there.
    @ObservationIgnored private var destination: CGRect?
    /// Runs each move as the keyboard does, its top at the room.
    @ObservationIgnored private var tracker: UIView?
    @ObservationIgnored private var link: CADisplayLink?
    /// The tracker's room at the last frame, and when, for its speed.
    @ObservationIgnored private var last: (room: CGFloat, at: CFTimeInterval)?
    @ObservationIgnored private var waiting: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        let center = NotificationCenter.default
        // With no queue a block runs as its notification posts, so the tracker sets off in the same
        // transaction as the keyboard.
        observers = [
            center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: nil) { [weak self] note in
                let info = note.userInfo
                let end = info?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                let duration = (info?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0
                let curve = (info?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 0
                MainActor.assumeIsolated { self?.moving(to: end, over: duration, curve: curve) }
            },
            center.addObserver(forName: UIResponder.keyboardDidChangeFrameNotification, object: nil, queue: nil) { [weak self] note in
                let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                MainActor.assumeIsolated { self?.arrived(at: end) }
            },
        ]
    }

    /// Returns once the keyboard has stopped moving: at once when it is still.
    func stillness() async {
        guard destination != nil else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// A report with no width holds no keyboard: UIKit sends `.zero`, timed, as the app returns from a
    /// quick app switch, and taking its top as the keyboard's gave the keyboard the whole window. Timed
    /// moves are real keyboard moves. During a turn, an instant report must match the screen's
    /// width and describe the keyboard docked at its foot, or gone below it. UIKit also reports our key
    /// row alone at the foot while the keyboard is still up; that is not a keyboard dismissal.
    static func settles(_ end: CGRect, on screen: CGRect, over duration: Double, accessoryHeight: CGFloat) -> Bool {
        guard end.width > 0 else { return false }
        if duration > 0 { return true }
        guard abs(end.width - screen.width) < 1 else { return false }
        let docked = abs(end.maxY - screen.maxY) < 1 && end.height > accessoryHeight + 1
        let gone = end.minY >= screen.maxY - 1
        return docked || gone
    }

    private func moving(to end: CGRect?, over duration: Double, curve: UInt) {
        let scenes = UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }
        guard let end, let window = scenes.compactMap(\.keyWindow).first, let screen = window.windowScene?.screen,
              Self.settles(end, on: screen.coordinateSpace.bounds, over: duration, accessoryHeight: KeyRow.height)
        else { return }
        destination = end
        screenWidth = screen.coordinateSpace.bounds.width
        let top = window.convert(end, from: screen.coordinateSpace).minY
        let room = max(0, window.bounds.maxY - window.safeAreaInsets.bottom - top)
        guard room != heading else { return }
        heading = room
        guard duration > 0 else {
            stop()
            inset = room
            return
        }
        let tracker = self.tracker.flatMap { $0.window === window ? $0 : nil } ?? {
            let view = UIView(frame: CGRect(x: 0, y: inset, width: 1, height: 1))
            view.isUserInteractionEnabled = false
            view.accessibilityElementsHidden = true
            view.alpha = 0
            window.addSubview(view)
            self.tracker = view
            return view
        }()
        if link == nil {
            UIView.performWithoutAnimation { tracker.frame.origin.y = inset }
            let link = CADisplayLink(target: self, selector: #selector(step(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        // A move that overtakes one under way sets off from where the keyboard is, as the keyboard's does.
        UIView.animate(
            withDuration: duration, delay: 0, options: [UIView.AnimationOptions(rawValue: curve << 16), .beginFromCurrentState]
        ) {
            tracker.frame.origin.y = room
        }
    }

    /// Puts `inset` where the tracker will be as this frame shows. Its presentation layer gives where it
    /// is now, a few milliseconds before that, so the room runs on at the tracker's speed since the last
    /// frame, never past where the move ends, and takes that end on the frame the move does. Waiting for
    /// Core Animation to take the finished animation away left the cards creeping the last half point
    /// three frames after the keyboard had stopped.
    @objc private func step(_ link: CADisplayLink) {
        guard let tracker else { return stop() }
        let layer = tracker.layer
        let shows = layer.convertTime(link.targetTimestamp, from: nil)
        // Core Animation gives an animation its start as the transaction holding it commits.
        let moving = (layer.animationKeys() ?? []).lazy.compactMap { layer.animation(forKey: $0) }
            .contains { $0.beginTime == 0 || shows < $0.beginTime + $0.duration }
        guard moving, let shown = layer.presentation()?.frame.minY else {
            stop()
            if inset != heading { inset = heading }
            return
        }
        let now = CACurrentMediaTime()
        var room = shown
        if let last, now > last.at {
            room += (shown - last.room) / (now - last.at) * (link.targetTimestamp - now)
        }
        last = (shown, now)
        let next = heading >= inset ? min(room, heading) : max(room, heading)
        if inset != next { inset = next }
    }

    private func stop() {
        link?.invalidate()
        link = nil
        last = nil
    }

    private func arrived(at end: CGRect?) {
        // A move a later one overtook ends short of where the keyboard is headed now.
        guard end == destination else { return }
        destination = nil
        let ready = waiting
        waiting = []
        for each in ready { each.resume() }
    }
}

/// What is left of the keyboard's move for a part of the screen: how much shorter the part gets before the
/// keyboard stops (`left`, less than zero while it goes down), and the room the move heads for
/// (`KeyboardMotion.heading`), which tells one move from the next.
struct KeyboardTravel: Equatable {
    var left: CGFloat = 0
    var heading: CGFloat = 0
    var screenWidth: CGFloat = 0
}
