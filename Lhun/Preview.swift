import SwiftUI
import WebKit

/// A page served on a host's own localhost, shown here through a forwarded port. The port is forwarded
/// only while the preview is open and the app is on screen; the page stays as it was across a trip to
/// the background, and comes back live on return.
@MainActor @Observable
final class Preview {
    let link: HostLink
    /// The port on the host.
    let port: Int
    let page: WebPage
    /// The port on this device the page loads from, once forwarding.
    private(set) var localPort: Int?
    /// Why the page can't be shown, in words.
    private(set) var problem: String?

    @ObservationIgnored private var forwarding = Forwarding.off

    private enum Forwarding {
        case off
        case starting(UUID)
        case on(PortForward)
    }

    init(link: HostLink, port: Int) {
        self.link = link
        self.port = port
        var configuration = WebPage.Configuration()
        // Nothing a previewed page stores outlives the preview.
        configuration.websiteDataStore = .nonPersistent()
        page = WebPage(configuration: configuration)
    }

    /// Starts forwarding, then loads the page. Does nothing while already forwarding.
    func open() {
        guard case .off = forwarding else { return }
        let attempt = UUID()
        forwarding = .starting(attempt)
        problem = nil
        Task {
            do {
                let forward = try await PortForward.start(port: port, on: link)
                // Closed or sent to the background while starting.
                guard case .starting(attempt) = forwarding else {
                    await forward.stop()
                    return
                }
                forwarding = .on(forward)
                localPort = forward.localPort
                if page.url?.port == forward.localPort {
                    // Back from the background: the page is still here, so bring it up to date in place.
                    await show(page.reload())
                } else {
                    await show(page.load(URL(string: "http://localhost:\(forward.localPort)/")))
                }
            } catch {
                guard case .starting(attempt) = forwarding else { return }
                forwarding = .off
                problem = error.localizedDescription
            }
        }
    }

    /// Checks that something still answers on the port, then reloads. Starts over when forwarding had
    /// stopped.
    func reload() {
        guard case .on = forwarding else { return open() }
        problem = nil
        Task {
            do {
                try await PortForward.check(port: port, on: link)
                await show(page.reload())
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// Stops forwarding and closes every connection made through it.
    func stop() {
        if case .on(let forward) = forwarding {
            Task { await forward.stop() }
        }
        forwarding = .off
    }

    private func show(_ navigation: some AsyncSequence<WebPage.NavigationEvent, any Error>) async {
        do {
            for try await _ in navigation {}
        } catch WebPage.NavigationError.failedProvisionalNavigation(let error) {
            // A newer navigation taking over is not a failure.
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            // Most often the server went away; say so when it did.
            do {
                try await PortForward.check(port: port, on: link)
                problem = error.localizedDescription
            } catch {
                problem = error.localizedDescription
            }
        } catch {
            problem = "The page stopped loading."
        }
    }
}

/// The preview panel: the page, under the panel's own bar with the page's name and where it comes from,
/// reload and close.
struct PreviewView: View {
    let preview: Preview
    let close: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                WebView(preview.page)
                if let problem = preview.problem {
                    Text(problem)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(Metrics.section)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.card)
                        .accessibilityIdentifier("preview.problem")
                } else if preview.localPort == nil {
                    ProgressView()
                }
            }
            .overlay(alignment: .top) {
                if preview.page.isLoading {
                    ProgressView(value: preview.page.estimatedProgress)
                        .progressViewStyle(.linear)
                }
            }
            // The page carries its name and the address it loads from on this device, which the UI tests read.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(verbatim: title))
            .accessibilityValue(Text(verbatim: preview.localPort.map { "http://localhost:\($0)" } ?? ""))
            .accessibilityIdentifier("preview.address")
            .background(Theme.card)
            .navigationTitle(title)
            .navigationSubtitle(Text(verbatim: "port \(preview.port) on \(preview.link.host.name)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Reload", systemImage: "arrow.clockwise", action: preview.reload)
                        .keyboardShortcut("r")
                        .accessibilityIdentifier("preview.reload")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close, action: close)
                        .accessibilityIdentifier("preview.close")
                }
            }
        }
    }

    /// The page's own title, or its address until it has one.
    private var title: String {
        preview.page.title.isEmpty ? "localhost:\(preview.port)" : preview.page.title
    }
}
