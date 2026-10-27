import SwiftUI

/// The whole terminal space: strip or sidebar, cards, palette, history. The Lhûn app shows it alone; the
/// app embedding LhunKit shows it as one of its spaces.
public struct TerminalSpace: View {
    private let lhun: Lhun
    @Environment(\.scenePhase) private var scenePhase

    public init(_ lhun: Lhun) {
        self.lhun = lhun
    }

    public var body: some View {
        RootView()
            .environment(lhun.model)
            // While it is on screen, the sessions on its cards are live here and on no chat card, and the
            // scene's phase comes from here (`AppModel.scenePhaseChanged`).
            .overlay(alignment: .top) { PendingActionKeys() }
            .onAppear {
                lhun.model.terminalSpaceAppeared()
                lhun.model.loadActions()
            }
            .onDisappear {
                ActionBindings.shared.cancel()
                lhun.model.terminalSpaceDisappeared()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { ActionBindings.shared.cancel() }
            }
    }
}

private struct PendingActionKeys: View {
    @State private var bindings = ActionBindings.shared

    var body: some View {
        if bindings.isPending {
            let choices = bindings.pendingChoices
            VStack(alignment: .leading, spacing: Metrics.tight) {
                HStack {
                    Text(bindings.pendingTitle).font(.subheadline.weight(.medium))
                    Spacer(minLength: Metrics.near)
                    Button("Cancel") { bindings.cancel() }
                        .frame(minHeight: Metrics.touch)
                }
                if !choices.isEmpty {
                    Text(choices).font(.footnote).foregroundStyle(Theme.detail).lineLimit(2)
                }
            }
            .padding(.horizontal, Metrics.inset)
            .padding(.bottom, Metrics.near)
            .frame(maxWidth: 560)
            .background(Theme.raised, in: .rect(cornerRadius: Metrics.radius))
            .lifted()
            .padding(.horizontal, Metrics.inset)
            .padding(.top, 56)
            .accessibilityIdentifier("bindings.pending")
        }
    }
}

extension View {
    /// Puts the appearance chosen with the palette's Appearance command on the window, so its sheets,
    /// alerts and keyboard follow it too; "Match iPad" leaves the system's. The Lhûn app applies it to its
    /// window. An app embedding LhunKit that leaves it off keeps its own appearance, and the command then
    /// changes nothing.
    public func lhunWindowAppearance() -> some View {
        modifier(LhunWindowAppearance())
    }
}

private struct LhunWindowAppearance: ViewModifier {
    func body(content: Content) -> some View {
        content.background { WindowAppearance(style: ThemeStore.shared.appearance.style) }
    }
}

/// The terminal space's keyboard shortcuts and menus. Everything else on the keyboard goes straight to the
/// terminal. Like any app's commands, they act whichever space is on screen.
public struct LhunCommands: Commands {
    private let model: AppModel

    public init(_ lhun: Lhun) {
        model = lhun.model
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session") { model.performAction("new") }
                .keyboardShortcut("t")
        }
        // The system's place for it, in the View menu, with the system's shortcut.
        CommandGroup(replacing: .sidebar) {
            Button(model.sidebar.isOn ? "Hide Sidebar" : "Show Sidebar") { model.performAction("sidebar") }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(!model.sidebar.replacesStrip)
            Button(model.sidebar.showingActivity ? "Clear Activity Filter" : "Filter by Activity") { model.performAction("activity") }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!model.sidebar.replacesStrip)
        }
        CommandMenu("Session") {
            Button("Commands…") { model.performAction("palette") }
                .keyboardShortcut("k")
            Button("Insert Path…") { model.performAction("insert-path") }
                .keyboardShortcut("p")
                .disabled(model.selection == nil)
            Button("Get File…") { model.performAction("get-file") }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model.selection == nil)
            Button("Go to Folder…") { model.performAction("go-to-folder") }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Divider()
            Button("Previous Tab") { model.performAction("previous-tab") }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Tab") { model.performAction("next-tab") }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Show All Sessions") { model.performAction("peek") }
                .keyboardShortcut("\\", modifiers: [.command, .shift])
            Button("Inbox") { model.performAction("inbox") }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
            Button("Split Right") { model.performAction("split") }
                .keyboardShortcut("d")
                .disabled(model.panes.isEmpty)
            Button("Split Down") { model.performAction("split-down") }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(model.panes.isEmpty)
            Button(model.panes.count > 2 ? "Previous Card" : model.stacked ? "Focus Top Card" : "Focus Left Card") { model.performAction("focus-previous-card") }
                .keyboardShortcut("[")
                .disabled(!model.isSplit)
            Button(model.panes.count > 2 ? "Next Card" : model.stacked ? "Focus Bottom Card" : "Focus Right Card") { model.performAction("focus-next-card") }
                .keyboardShortcut("]")
                .disabled(!model.isSplit)
            Button(model.zoomed == nil ? "Zoom Card" : "Restore Cards") { model.performAction("zoom-card") }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(!model.isSplit)
            Button("Balance Cards") { model.performAction("balance-cards") }
                .keyboardShortcut("0", modifiers: [.command, .option, .control])
                .disabled(!model.isSplit)
            Button("Grow Focused Card") { model.performAction("grow-card") }
                .keyboardShortcut("=", modifiers: [.command, .option, .control])
                .disabled(!model.isSplit)
            Button("Shrink Focused Card") { model.performAction("shrink-card") }
                .keyboardShortcut("-", modifiers: [.command, .option, .control])
                .disabled(!model.isSplit)
            Button("One-Shot Keys") { model.performAction("one-shot-keys") }
            Divider()
            Button("Move Window Left") { model.performAction("move-window-left") }
                .keyboardShortcut("[", modifiers: [.command, .option])
                .disabled(model.selection == nil)
            Button("Move Window Right") { model.performAction("move-window-right") }
                .keyboardShortcut("]", modifiers: [.command, .option])
                .disabled(model.selection == nil)
            Divider()
            ForEach(Array(model.tabOrder.prefix(9).enumerated()), id: \.element) { index, ref in
                Button(ref.name) { model.performAction("tab.\(index + 1)") }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
            }
            Divider()
            Button("Rename…") { model.performAction("rename") }
                .disabled(model.selection == nil)
            Button("Close Session") { model.performAction("close-session") }
                .keyboardShortcut("w")
                .disabled(model.selection == nil)
            Button("Send Escape") { model.performAction("escape") }
                .keyboardShortcut(".")
                .disabled(model.selection == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("Bigger Text") { model.performAction("bigger") }
                .keyboardShortcut("=")
            Button("Smaller Text") { model.performAction("smaller") }
                .keyboardShortcut("-")
            Button("Actual Size") { model.performAction("actual") }
                .keyboardShortcut("0")
        }
    }
}
