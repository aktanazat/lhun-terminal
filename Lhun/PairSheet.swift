import SwiftUI

/// Pairs a Mac or the server with this device: a script to paste on the machine, or steps for an agent there,
/// and the pairing link it answers with. A link opened from a QR code lands here too, waiting on his word.
struct PairSheet: View {
    let line: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var copied: Copied?

    private enum Copied { case script, instructions, key }

    private let device = UIDevice.current.localizedModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.wide) {
                    if let paired = model.pairing {
                        offer(paired)
                    }
                    VStack(alignment: .leading, spacing: Metrics.near) {
                        Text("On the new Mac or server, paste this into a terminal. It adds this \(device)'s key and copies a pairing link back.")
                        copy(.script, "Copy Setup") { Pairing.script(deviceKey: line) }
                            .buttonStyle(.borderedProminent)
                            // The accent is ink, near white in dark, so the label takes the background's color.
                            .foregroundStyle(Color(uiColor: .systemBackground))
                    }
                    VStack(alignment: .leading, spacing: Metrics.near) {
                        Text("Then paste the link here, or scan its QR code with the Camera.")
                        PasteButton(payloadType: String.self) { texts in
                            let paired = texts.lazy.compactMap(Pairing.host(inText:)).first
                            Task { @MainActor in model.offerPairing(paired) }
                        }
                        .accessibilityIdentifier("pair.paste")
                        if let problem = model.pairingProblem {
                            Text(problem)
                                .foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: Metrics.near) {
                        Text("Or have an agent on that machine do it.")
                            .foregroundStyle(.secondary)
                        copy(.instructions, "Copy Instructions for an Agent") { Pairing.agentInstructions(deviceKey: line) }
                            .buttonStyle(.bordered)
                    }
                    key
                }
                .padding(Metrics.wide)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Pair a Mac or Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
    }

    /// The machine a link named, and the choice to put it in its host's place.
    private func offer(_ paired: PairedHost) -> some View {
        let place = Host.builtIn.first { $0.id == paired.id }
        let previous = Host.all.first { $0.id == paired.id }
        return VStack(alignment: .leading, spacing: Metrics.near) {
            Text("Pair “\(paired.machine)” as \(place?.phrase ?? paired.id)?")
                .font(.headline)
            Text(verbatim: "\(paired.user) at \(paired.address):\(paired.port ?? 22)")
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
            if let previous, previous.address != paired.address || previous.user != paired.user || previous.port != (paired.port ?? 22) {
                Text("Lhûn signs in there instead of \(previous.user) at \(previous.address):\(previous.port).")
                    .foregroundStyle(.secondary)
            }
            if let codeURL = paired.codeURL {
                Text("VS Code: \(codeURL.absoluteString)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: Metrics.near) {
                Button("Pair") { model.pair(paired) }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .accessibilityIdentifier("pair.confirm")
                Button("Not Now") { model.pairing = nil }
                    .buttonStyle(.bordered)
            }
        }
        .padding(Metrics.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.pill, in: .rect(cornerRadius: Metrics.radius, style: .continuous))
    }

    private var key: some View {
        VStack(alignment: .leading, spacing: Metrics.near) {
            #if targetEnvironment(simulator)
            Text("This simulator's key is stored in the app's local files. This is the public half.")
                .foregroundStyle(.secondary)
            #else
            Text("This \(device)'s key, made inside its Secure Enclave. The private half never leaves the chip; this public half is safe to share.")
                .foregroundStyle(.secondary)
            #endif
            Text(line)
                // A key is code, so it takes SF Mono, where I and l read apart. It is no language either, so
                // it breaks where the line ends rather than at a hyphen it never had.
                .font(.footnote.monospaced())
                .typesettingLanguage(Locale.Language(identifier: "zxx"))
                .textSelection(.enabled)
                .padding(Metrics.inset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.pill, in: .rect(cornerRadius: Metrics.radius, style: .continuous))
            copy(.key, "Copy Key") { line }
                .buttonStyle(.bordered)
        }
    }

    private func copy(_ what: Copied, _ title: String, _ text: @escaping () -> String) -> some View {
        Button(copied == what ? "Copied" : title) {
            UIPasteboard.general.string = text()
            copied = what
        }
    }
}
