import Testing
import UIKit
@testable import LhunKit

@MainActor
@Test("Saved key sequences and one-shot keys dispatch once without swallowing unrelated typing")
func actionKeyBindings() {
    let defaults = LhunDefaults.shared
    let previous = defaults.data(forKey: "actionBindings")
    defaults.removeObject(forKey: "actionBindings")
    defer {
        if let previous {
            defaults.set(previous, forKey: "actionBindings")
        } else {
            defaults.removeObject(forKey: "actionBindings")
        }
    }
    let manager = ActionBindings()
    let action = "binding-test-\(UUID())"
    let prefix = ActionKey("u", [.command, .control, .alternate, .shift])
    let second = ActionKey("z")
    let oneShot = ActionKey("q")

    #expect(manager.save(actionID: action, title: "Test Action", keys: [prefix, second], scope: .shortcut) == nil)
    #expect(manager.save(actionID: action, title: "Test Action", keys: [oneShot], scope: .oneShot) == nil)
    if case .consumed = manager.receive(prefix) {} else { Issue.record("the prefix reached the terminal") }
    #expect(manager.isPending)
    if case .action(let selected) = manager.receive(second) {
        #expect(selected == action)
    } else { Issue.record("the second key did not run the action") }
    #expect(!manager.isPending)

    manager.startOneShot()
    if case .action(let selected) = manager.receive(oneShot) {
        #expect(selected == action)
    } else { Issue.record("the one-shot key did not run the action") }
    #expect(!manager.isPending)
    manager.startOneShot()
    if case .pass = manager.receive(ActionKey("j")) {} else { Issue.record("an unbound key did not reach the terminal") }
    #expect(!manager.isPending)
    #expect(manager.problem(for: [ActionKey("k", .command), second], scope: .shortcut, actionID: action) != nil)
}
