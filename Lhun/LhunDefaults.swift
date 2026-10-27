import Foundation

/// The one place LhunKit keeps its settings. Inside the Lhûn app that is the app's standard defaults, where
/// everything it saved before LhunKit was a package still is, and where the launch arguments its UI tests and
/// probes pass (`-keySeen YES`, `-layout sidebar`) land. An app that embeds LhunKit has settings of its own
/// under the same names ("fontSize", "appearance", "host", "selection"), so there LhunKit keeps its settings
/// in a suite of its own, and neither side reads or overwrites the other's.
enum LhunDefaults {
    /// The Lhûn app's bundle identifier, as project.yml sets it.
    static let lhunApp = "com.aktanazat.lhun"
    static let suiteName = "com.aktanazat.lhun.kit"

    /// The store for the app running LhunKit. Worked out at each use, since `UserDefaults` is not `Sendable` and
    /// so cannot be a static constant; settings are read at launch and written on his changes, never per frame.
    static var shared: UserDefaults { forApp(Bundle.main.bundleIdentifier) }

    /// The store for the app with this bundle identifier. `UserDefaults(suiteName:)` returns nil only for an app
    /// whose own bundle identifier is the suite's name, and that app's standard defaults are the suite.
    static func forApp(_ bundleID: String?) -> UserDefaults {
        guard bundleID != lhunApp else { return .standard }
        return UserDefaults(suiteName: suiteName) ?? .standard
    }
}
