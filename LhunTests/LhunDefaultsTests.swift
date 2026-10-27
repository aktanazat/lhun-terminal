import Foundation
import Testing
@testable import LhunKit

/// LhunKit's settings carry names an app's own settings carry too ("fontSize", "appearance", "host"), so in
/// an app that embeds it they live in a suite of LhunKit's own. In the Lhûn app they stay in its standard
/// defaults, where its saved state and the launch arguments its tests pass have always been.
struct LhunDefaultsTests {
    @Test func theLhunAppKeepsItsStandardDefaultsAndAnotherAppGetsTheSuite() {
        let key = "lhunDefaultsTests.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults(suiteName: LhunDefaults.suiteName)?.removeObject(forKey: key)
        }
        // These tests run inside the Lhûn app.
        LhunDefaults.shared.set("lhun", forKey: key)
        #expect(UserDefaults.standard.string(forKey: key) == "lhun")

        LhunDefaults.forApp("com.aktanazat.akyl").set("akyl", forKey: key)
        #expect(UserDefaults.standard.string(forKey: key) == "lhun")
        #expect(UserDefaults(suiteName: LhunDefaults.suiteName)?.string(forKey: key) == "akyl")
    }
}
