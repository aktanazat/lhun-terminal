import UIKit
import XCTest

/// Key commands typed into Lhûn, checked against the app's own record of the keys it got: the probe lists
/// the last keys the app saw go down (`keysSeen`) and counts them (`keysSeenCount`), taken at UIApplication's
/// sendEvent, before any of Lhûn's code sees a key. On a simulator, every key XCTest types swaps iOS from
/// the on-screen keyboard to the hardware one and back, and a key typed during the swap can be lost before
/// the app gets it; an iPad with a keyboard attached never swaps. So a command the app never saw go down is
/// typed once more, as an activity named "Retype …" in the test's log; one the app saw is never typed
/// again, so whatever Lhûn did with it stands, and a check that nothing happened knows the key arrived.
extension XCTestCase {
    /// Types `key` with `flags` held, as `typeKey` does, and returns once the probe shows the app saw it go
    /// down; throws when the app saw neither that nor a second try. `key` is one character.
    @MainActor
    func typeCommand(
        _ key: String, _ flags: XCUIElement.KeyModifierFlags, in app: XCUIApplication, probe: XCUIElement
    ) throws {
        let name = Self.commandName(key, flags)
        let before = Self.keysSeen(probe).count
        app.typeKey(key, modifierFlags: flags)
        if Self.sawDown(key, flags, in: probe, since: before) { return }
        XCTContext.runActivity(named: "Retype \(name): the app never saw it go down") { _ in
            app.typeKey(key, modifierFlags: flags)
        }
        guard Self.sawDown(key, flags, in: probe, since: before) else {
            throw KeyNeverArrived(errorDescription: "the app never saw \(name) go down, typed twice")
        }
    }

    /// Types `key` with `flags` as `typeCommand` does, then returns once the keyboard swap that key set off
    /// is over, so the next key is not typed into it. With the on-screen keyboard up, the probe shows it
    /// go down (`keyboardHides` counts up) and come back (`keyboard`, its top edge, above the screen's
    /// bottom again); a key typed between the two is the one a simulator loses, and once it does, it loses
    /// the next ones for a while too. With the keyboard already down there is no swap to wait for.
    @MainActor
    func typeSettled(
        _ key: String, _ flags: XCUIElement.KeyModifierFlags, in app: XCUIApplication, probe: XCUIElement
    ) throws {
        let bottom = app.frame.maxY
        let start = Self.keyboard(probe)
        try typeCommand(key, flags, in: app, probe: probe)
        guard start.top < bottom else { return }
        let name = Self.commandName(key, flags)
        guard Self.holds(within: 3, { Self.keyboard(probe).hides > start.hides }) else { return }
        XCTAssertTrue(
            Self.holds(within: 5, { Self.keyboard(probe).top < bottom }),
            "the on-screen keyboard went down for \(name) and never came back")
    }

    /// Whether, within 3 seconds, the probe lists `key` with exactly `flags` among the keys the app saw go
    /// down after it had seen `before`. The probe's label changes once a second.
    @MainActor
    private static func sawDown(
        _ key: String, _ flags: XCUIElement.KeyModifierFlags, in probe: XCUIElement, since before: Int
    ) -> Bool {
        // A key seen is "<key code> <characters> <characters without modifiers> <modifier flags>".
        let ending = " \(key.debugDescription) \(keyFlags(flags).rawValue)"
        return holds(within: 3) {
            let seen = keysSeen(probe)
            return seen.list.suffix(max(0, seen.count - before)).contains { $0.hasSuffix(ending) }
        }
    }

    /// The probe's last keys seen and its count of them.
    @MainActor
    private static func keysSeen(_ probe: XCUIElement) -> (list: [String], count: Int) {
        let sample = sample(probe)
        return (sample["keysSeen"] as? [String] ?? [], (sample["keysSeenCount"] as? NSNumber)?.intValue ?? 0)
    }

    /// The on-screen keyboard's top edge, as the probe has it, and how many times it has gone down.
    @MainActor
    private static func keyboard(_ probe: XCUIElement) -> (top: CGFloat, hides: Int) {
        let sample = sample(probe)
        return (
            CGFloat((sample["keyboard"] as? NSNumber)?.doubleValue ?? .infinity),
            (sample["keyboardHides"] as? NSNumber)?.intValue ?? 0)
    }

    @MainActor
    private static func sample(_ probe: XCUIElement) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(probe.label.utf8)) as? [String: Any]) ?? [:]
    }

    /// Whether `condition` holds within `seconds`, checked every quarter second.
    @MainActor
    private static func holds(within seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date.now.addingTimeInterval(seconds)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date.now < deadline
        return false
    }

    /// The flags a UIKey carries for the modifiers XCTest holds.
    private static func keyFlags(_ flags: XCUIElement.KeyModifierFlags) -> UIKeyModifierFlags {
        var held: UIKeyModifierFlags = []
        if flags.contains(.shift) { held.insert(.shift) }
        if flags.contains(.control) { held.insert(.control) }
        if flags.contains(.option) { held.insert(.alternate) }
        if flags.contains(.command) { held.insert(.command) }
        return held
    }

    /// "⌃⌘S", as a menu writes it.
    private static func commandName(_ key: String, _ flags: XCUIElement.KeyModifierFlags) -> String {
        let marks: [(XCUIElement.KeyModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return marks.filter { flags.contains($0.0) }.map(\.1).joined() + key.uppercased()
    }
}

private struct KeyNeverArrived: LocalizedError {
    let errorDescription: String?
}
