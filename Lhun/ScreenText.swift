import UIKit

extension AppModel {
    /// Puts the open session's screen on the clipboard as plain text, and flashes its card.
    func copyScreen() {
        withScreenText { [weak self] text in
            UIPasteboard.general.string = text
            guard let view = self?.selectedTerminal?.view, let card = view.superview else { return }
            CopyFlash.flash([card.bounds], in: card, color: view.nativeForegroundColor, strength: .card)
        }
    }

    /// Offers the open session's screen as plain text in the share sheet; the terminal gets the keyboard
    /// back once the sheet goes away.
    func shareScreen() {
        withScreenText { [weak self] text in
            ShareSheet.present(text) { self?.focusTerminal() }
        }
    }

    private func withScreenText(_ use: @escaping @MainActor (String) -> Void) {
        guard let ref = selection, let link = link(for: ref) else { return }
        Task {
            do {
                use(Tmux.screenText(try await link.run(Tmux.capture(ref.name))))
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// The system share sheet for a piece of text.
@MainActor
enum ShareSheet {
    static func present(_ text: String, then done: @escaping @MainActor () -> Void) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let window = scene?.keyWindow, var top = window.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, _, _, _ in done() }
        // On the iPad the sheet is a popover, which needs something to point at: the middle of the top strip.
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = window
            popover.sourceRect = CGRect(x: window.bounds.midX, y: window.safeAreaInsets.top + 44, width: 1, height: 1)
            popover.permittedArrowDirections = .up
        }
        top.present(sheet, animated: true)
    }
}
