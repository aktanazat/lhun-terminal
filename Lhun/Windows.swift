import os
import SwiftUI

private let log = Logger(subsystem: "com.aktanazat.lhun", category: "windows")

/// A session's tmux windows, as listed the last time the palette opened over it.
struct WindowList: Equatable {
    let session: SessionRef
    let windows: [TmuxWindow]
}

/// One window of a session, named for the rename dialog.
struct WindowTarget: Equatable {
    let session: SessionRef
    let index: Int
    let name: String
}

extension AppModel {
    /// Lists the open session's windows over its host's list connection; the palette calls this when it
    /// opens. A list for another session is dropped at once, so the palette never offers its windows.
    func loadWindows() {
        guard let ref = selection, let link = link(for: ref) else {
            windowList = nil
            return
        }
        if windowList?.session != ref { windowList = nil }
        Task {
            do {
                let windows = Tmux.parseWindows(try await link.run(Tmux.windows(of: ref.name), timeout: .seconds(10)))
                if selection == ref { windowList = WindowList(session: ref, windows: windows) }
            } catch {
                log.info("\(ref.name, privacy: .public) windows not listed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func selectWindow(_ index: Int, in ref: SessionRef) {
        changeWindows(of: ref, with: Tmux.selectWindow(index, in: ref.name))
    }

    /// Opens a window in the session, in the folder of the pane it shows; the session then shows it.
    func newWindow(in ref: SessionRef) {
        changeWindows(of: ref, with: Tmux.newWindow(in: ref.name))
    }

    func renameWindow(_ target: WindowTarget, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != target.name else { return }
        changeWindows(of: target.session, with: Tmux.renameWindow(target.index, in: target.session.name, to: name))
    }

    /// ⌃⇥ and ⌃⇧⇥: the open session shows its next or previous window, round from the last to the first.
    func stepWindow(_ step: Int) {
        guard let ref = selection else { return }
        changeWindows(of: ref, with: Tmux.stepWindow(step, in: ref.name))
    }

    /// ⌥⌘[ and ⌥⌘]: the window the open session shows trades places with its neighbour and stays shown.
    func moveWindow(_ step: Int) {
        guard let ref = selection else { return }
        changeWindows(of: ref, with: Tmux.moveWindow(step, in: ref.name))
    }

    /// The listed windows stop being true once a command changes them; the next palette lists them again.
    private func changeWindows(of ref: SessionRef, with command: String) {
        guard let link = link(for: ref) else { return }
        windowList = nil
        perform(on: link) {
            _ = try await link.run(command)
        }
    }
}

extension View {
    /// The dialog that renames a window of the open session, shown while `renamingWindow` is set.
    func windowRenameAlert() -> some View {
        modifier(WindowRenameAlert())
    }
}

private struct WindowRenameAlert: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var draftName = ""

    func body(content: Content) -> some View {
        content
            .alert(
                "Rename Window",
                isPresented: Binding(get: { model.renamingWindow != nil }, set: { if !$0 { model.renamingWindow = nil } }),
                presenting: model.renamingWindow
            ) { target in
                TextField("Name", text: $draftName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Rename") {
                    model.renameWindow(target, to: draftName)
                    model.renamingWindow = nil
                    model.focusTerminal()
                }
                Button("Cancel", role: .cancel) {
                    model.renamingWindow = nil
                    model.focusTerminal()
                }
            }
            .onChange(of: model.renamingWindow) { _, target in
                draftName = target?.name ?? ""
            }
    }
}
