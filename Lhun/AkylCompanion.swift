import SwiftUI
import UIKit

struct AkylBreadcrumb: View {
    @Environment(AppModel.self) private var model
    let visit: AkylVisit

    var body: some View {
        HStack(spacing: Metrics.near) {
            Button { model.showAkylPreview() } label: {
                HStack(spacing: Metrics.near) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("From Akyl").font(.caption).foregroundStyle(.secondary)
                        Text(visit.context.taskTitle).font(.subheadline).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: Metrics.touch)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Akyl task: \(visit.context.taskTitle)")
            .accessibilityHint("Review the original context and any pending selection")
            .accessibilityIdentifier("akyl.context")
            Button { model.showAkylPreview() } label: {
                Label(visit.pending?.selected == nil ? "Back to Akyl" : "Review return", systemImage: "arrow.uturn.backward")
                    .font(.subheadline)
                    .frame(minHeight: Metrics.touch)
            }
            .accessibilityIdentifier("akyl.back")
        }
        .padding(.horizontal, Metrics.inset)
        .background(Theme.raised)
    }
}

struct AkylCompanionPreview: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var removing = false
    @State private var discarding = false

    var body: some View {
        NavigationStack {
            if let visit = model.akylVisit {
                Form {
                    Section("Original Akyl task") {
                        Text(visit.context.taskTitle).textSelection(.enabled)
                        Text("Akyl keeps the task, draft and reading place. Returning never sends a message.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Session") {
                        LabeledContent("Host", value: visit.context.terminalPlace.host)
                        LabeledContent("Session", value: visit.context.terminalPlace.session)
                        if let window = visit.context.terminalPlace.window {
                            Text("Window \(window) is saved task context. Lhûn opens the session only; its current window is unchanged.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if model.akylOpening {
                            ProgressView("Opening the existing session…")
                        } else if let problem = model.akylOpenProblem {
                            Text(problem).foregroundStyle(.secondary)
                            Button("Retry task session") { model.openAkylTaskSession() }
                        } else {
                            Button("Show task session") { model.openAkylTaskSession(); dismiss() }
                        }
                    }
                    if let frozen = visit.context.frozenContext {
                        Section("Frozen evidence") {
                            Text(frozen.title).font(.headline)
                            Text(frozen.context).textSelection(.enabled)
                                .accessibilityIdentifier("akyl.frozenContext")
                            DisclosureGroup("Original source and capture") {
                                LabeledContent("Source", value: frozen.source.item)
                                LabeledContent("Source time", value: frozen.source.sourceAt.formatted())
                                LabeledContent("Selected", value: frozen.selectedAt.formatted())
                                LabeledContent("Card path", value: frozen.source.cardPath.map(String.init).joined(separator: " › "))
                                if let revision = frozen.source.revision { LabeledContent("Revision", value: String(revision)) }
                                if let task = frozen.source.task { LabeledContent("Source task", value: task) }
                                if let capture = frozen.captureConditions {
                                    Text(capture.scenario)
                                    LabeledContent("Device", value: capture.device)
                                    LabeledContent("Original viewport", value: "\(capture.viewportWidth.formatted()) × \(capture.viewportHeight.formatted()) points")
                                    LabeledContent("Appearance", value: capture.appearance.rawValue)
                                    LabeledContent("Text size", value: capture.textSize)
                                    LabeledContent("Reduce Motion", value: capture.reduceMotion ? "On" : "Off")
                                }
                            }
                        }
                    }
                    if let selected = visit.pending?.selected {
                        Section("Selected text to return") {
                            Text(selected.text).font(.body.monospaced()).textSelection(.enabled)
                                .accessibilityIdentifier("akyl.selectedText")
                            LabeledContent("Selected host", value: selected.host)
                            LabeledContent("Selected session", value: selected.session)
                            LabeledContent("Captured", value: selected.capturedAt.formatted())
                            Button("Discard pending selection", role: .destructive) { discarding = true }
                        }
                    }
                    Section("Return to the original task") {
                        if visit.pending?.selected != nil {
                            AkylOpenInButton(model: model, includingSelection: true)
                                .frame(minHeight: Metrics.touch)
                                .accessibilityIdentifier("akyl.returnSelection")
                        }
                        AkylOpenInButton(model: model, includingSelection: false)
                            .frame(minHeight: Metrics.touch)
                            .accessibilityIdentifier("akyl.openIn")
                        Text("Choose Akyl in Open In. Akyl checks that the original task is still available. The complete selection stays here until you explicitly discard it.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let note = visit.deliveryNote { Text(note).font(.footnote) }
                        if let recipient = visit.recipient {
                            LabeledContent("OS recipient", value: recipient).font(.footnote)
                            Text("The system reported delivery, not acceptance by the original task.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Section("Lhûn workspace") {
                        Button("Restore previous workspace") { model.restoreBeforeAkyl(); dismiss() }
                        Button("Remove local task link…", role: .destructive) { removing = true }
                    }
                }
                .navigationTitle("Akyl task")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
        }
        .confirmationDialog("Discard the pending selected text?", isPresented: $discarding, titleVisibility: .visible) {
            Button("Discard selection", role: .destructive) { model.discardAkylSelection() }
        } message: { Text("This removes only Lhûn's pending excerpt. The original task and frozen evidence stay unchanged.") }
        .confirmationDialog("Remove this local task link?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove link and pending selection", role: .destructive) { model.removeAkylLink() }
        } message: { Text("Lhûn returns to its previous workspace and removes this local link and pending text. The Akyl task and all terminal sessions remain.") }
        .presentationDetents([.large])
    }
}

/// A real native control gives the Open In menu its own popover anchor on iPad.
private struct AkylOpenInButton: UIViewRepresentable {
    let model: AppModel
    let includingSelection: Bool

    @MainActor
    final class Coordinator {
        let model: AppModel
        var includingSelection: Bool

        init(model: AppModel, includingSelection: Bool) {
            self.model = model
            self.includingSelection = includingSelection
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model, includingSelection: includingSelection) }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.addAction(UIAction { [weak button, weak coordinator = context.coordinator] _ in
            guard let button, let coordinator else { return }
            coordinator.model.openAkylReturn(from: button, includingSelection: coordinator.includingSelection)
        }, for: .touchUpInside)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.includingSelection = includingSelection
        var configuration = UIButton.Configuration.tinted()
        configuration.title = includingSelection ? "Return selected text to Akyl" : "Back to Akyl without adding text"
        configuration.image = UIImage(systemName: "arrow.uturn.backward")
        configuration.imagePadding = 8
        button.configuration = configuration
    }
}

/// Owned by the existing AppModel. Neither dismissing the menu nor OS delivery deletes pending data.
@MainActor
final class AkylReturnDocument: NSObject, @MainActor UIDocumentInteractionControllerDelegate {
    static let file = URL.cachesDirectory.appending(path: "akyl-return.akylreply", directoryHint: .notDirectory)
    private let controller: UIDocumentInteractionController
    private var delivered = false
    var onReceipt: ((String?, String) -> Void)?

    init(_ returned: AkylTaskReturn) throws {
        try AkylDocument.encoder().encode(returned).write(to: Self.file, options: [.atomic, .completeFileProtection])
        controller = UIDocumentInteractionController(url: Self.file)
        super.init()
        controller.uti = AkylDocument.returnType
        controller.name = "Return to Akyl"
        controller.delegate = self
    }

    func present(from anchor: UIView) {
        delivered = false
        if !controller.presentOpenInMenu(from: anchor.bounds, in: anchor, animated: true) {
            onReceipt?(nil, "No compatible app is available in Open In. Keep this selection here and open Akyl when it is available.")
        }
    }

    func documentInteractionController(_ controller: UIDocumentInteractionController, didEndSendingToApplication application: String?) {
        delivered = true
        onReceipt?(application, "The system handed off the document. Its acceptance by the original Akyl task is not confirmed; the full selection is still here.")
    }

    func documentInteractionControllerDidDismissOpenInMenu(_ controller: UIDocumentInteractionController) {
        if !delivered { onReceipt?(nil, "Open In closed without confirmed delivery. The full selection and original task link are still here.") }
    }

    func discard() throws {
        controller.dismissMenu(animated: false)
        try Self.discardFile()
    }

    static func discardFile() throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }
}
