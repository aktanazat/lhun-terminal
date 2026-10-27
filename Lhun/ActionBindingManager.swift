import SwiftUI
import UIKit

struct ActionBindingManager: View {
    let commands: [Command]
    let onBack: () -> Void
    @Environment(AppModel.self) private var model
    @State private var bindings = ActionBindings.shared
    @State private var query = ""
    @State private var highlighted = 0
    @State private var editing: BindingTarget?
    @State private var focusRequest = 0

    private struct BindingTarget: Identifiable {
        let id: String
        let title: String
        let detail: String
    }

    private var targets: [BindingTarget] {
        var targets = commands.filter { $0.opens == nil }.map { BindingTarget(id: $0.id, title: $0.title, detail: $0.detail) }
        let known = Set(targets.map(\.id))
        var missing = Set<String>()
        for binding in bindings.bindings where !known.contains(binding.actionID) && missing.insert(binding.actionID).inserted {
            targets.append(BindingTarget(id: binding.actionID, title: binding.actionTitle, detail: "Unavailable"))
        }
        let search = FuzzyQuery(query)
        return targets.filter { query.isEmpty || FuzzyMatch.score(search, $0.title + " " + $0.detail) != nil }
    }

    var body: some View {
        let shown = targets
        PaletteCard(
            prompt: "Find an action", query: $query, fieldID: "bindings.query",
            highlightedID: shown.indices.contains(highlighted) ? shown[highlighted].id : nil,
            onMove: { step in
                guard !shown.isEmpty else { return }
                highlighted = (highlighted + step + shown.count) % shown.count
            },
            onSubmit: { if shown.indices.contains(highlighted) { editing = shown[highlighted] } },
            onClose: { model.closePalette() }, onDeleteEmpty: onBack, focusRequest: focusRequest,
            leading: {
                Button(action: onBack) { Image(systemName: "chevron.left").frame(width: Metrics.touch, height: Metrics.touch) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
            }
        ) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, target in
                Button { editing = target } label: {
                    HStack(spacing: Metrics.near) {
                        Text(target.title).font(.subheadline).foregroundStyle(.primary)
                        if !target.detail.isEmpty {
                            Text(target.detail).font(.footnote).foregroundStyle(Theme.detail).truncationMode(.middle)
                        }
                        Spacer(minLength: Metrics.near)
                        let saved = bindings.bindings.filter { $0.actionID == target.id }
                        Text(saved.map { $0.scope == .oneShot ? "One-Shot: \($0.title)" : $0.title }.joined(separator: ", "))
                            .font(.footnote)
                            .foregroundStyle(Theme.detail)
                    }
                    .lineLimit(1)
                    .paletteRow(isHighlighted: highlighted == index)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("bindings.\(target.id)")
            }
            if shown.isEmpty {
                Text("No matching actions").font(.subheadline).foregroundStyle(Theme.detail).paletteRow(isHighlighted: false)
            }
        }
        .onChange(of: query) { highlighted = 0 }
        .sheet(item: $editing, onDismiss: { focusRequest += 1 }) { target in
            ActionBindingEditor(actionID: target.id, title: target.title)
        }
    }
}

private struct ActionBindingEditor: View {
    let actionID: String
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var bindings = ActionBindings.shared
    @State private var scope = ActionBinding.Scope.shortcut
    @State private var keyCount = 1
    @State private var keys: [ActionKey] = []
    @State private var recording = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Mode", selection: $scope) {
                        ForEach(ActionBinding.Scope.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Keys", selection: $keyCount) {
                        Text("One Key").tag(1)
                        Text("Two Keys").tag(2)
                    }
                    .pickerStyle(.segmented)
                    Button {
                        keys = []
                        problem = nil
                        recording = true
                    } label: {
                        HStack {
                            Text(recording ? "Press a key…" : keys.isEmpty ? "Record Binding" : "Record Again")
                            Spacer()
                            Text(keys.map(\.title).joined(separator: " ")).foregroundStyle(Theme.detail)
                        }
                        .frame(minHeight: Metrics.touch)
                    }
                    .accessibilityIdentifier("bindings.record")
                    if recording {
                        BindingKeyRecorder { key in
                            if key == ActionKey("escape") {
                                recording = false
                                load()
                                return
                            }
                            keys.append(key)
                            if keys.count == keyCount { recording = false }
                        }
                        .frame(height: 1)
                        .accessibilityHidden(true)
                        Button("Cancel Recording") { recording = false; load() }
                    }
                    if let problem {
                        Text(problem).foregroundStyle(.red)
                    } else if !recording, !keys.isEmpty,
                              let conflict = bindings.problem(for: keys, scope: scope, actionID: actionID) {
                        Text(conflict).foregroundStyle(.red)
                    }
                }
                let defaults = ActionBindings.builtIns.filter { $0.id == actionID }
                if !defaults.isEmpty {
                    Section("Built-In") {
                        Text(defaults.map { $0.key.title }.joined(separator: ", "))
                    }
                }
                if bindings.bindings.contains(where: { $0.actionID == actionID && $0.scope == scope }) {
                    Section {
                        Button("Remove Binding", role: .destructive) {
                            problem = bindings.remove(actionID: actionID, scope: scope)
                            if problem == nil { dismiss() }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        problem = bindings.save(actionID: actionID, title: title, keys: keys, scope: scope)
                        if problem == nil { dismiss() }
                    }
                    .disabled(recording || keys.count != keyCount || bindings.problem(for: keys, scope: scope, actionID: actionID) != nil)
                    .accessibilityIdentifier("bindings.save")
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: scope) { recording = false; load() }
        .onChange(of: keyCount) { recording = false; problem = nil }
    }

    private func load() {
        let saved = bindings.bindings.first { $0.actionID == actionID && $0.scope == scope }
        keyCount = saved?.keys.count ?? 1
        keys = saved?.keys ?? []
        problem = nil
    }
}

private struct BindingKeyRecorder: UIViewRepresentable {
    let onKey: (ActionKey) -> Void

    func makeUIView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onKey = onKey
        return view
    }

    func updateUIView(_ view: RecorderView, context: Context) { view.onKey = onKey }

    final class RecorderView: UIView {
        var onKey: ((ActionKey) -> Void)?
        override var canBecomeFirstResponder: Bool { true }

        override var keyCommands: [UIKeyCommand]? {
            ActionBindings.reserved.map { key in
                let command = UIKeyCommand(input: key.commandInput, modifierFlags: UIKeyModifierFlags(rawValue: key.modifiers), action: #selector(captureCommand))
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { becomeFirstResponder() }
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard presses.count == 1, let key = presses.first?.key, let chord = ActionKey(key) else { return }
            onKey?(chord)
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {}

        @objc private func captureCommand(_ command: UIKeyCommand) {
            guard let input = command.input else { return }
            onKey?(ActionKey(input, command.modifierFlags))
        }
    }
}
