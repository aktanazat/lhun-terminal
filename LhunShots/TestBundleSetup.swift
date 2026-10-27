import ObjectiveC
import XCTest

/// The test bundle's principal class: XCTest creates it once, before any test runs.
@objc(TestBundleSetup)
final class TestBundleSetup: NSObject {
    override init() {
        super.init()
        Self.skipAnimationsIdle()
    }

    /// Before each step XCUITest waits for the app's run loop to go idle and for UIKit to report
    /// every started animation as stopped. On the iPad the keyboard's glass background sometimes
    /// reports one animation as started twice and stopped once. UIKit's count then never returns
    /// to zero, and every later step waits a full minute. The animation is Apple's, so the checks
    /// keep the run-loop wait, drop the animation count, and wait for the state each one needs.
    private static func skipAnimationsIdle() {
        guard let process = NSClassFromString("XCUIApplicationProcess") else {
            fatalError("XCUIApplicationProcess is gone; the quiescence wait needs a new hook")
        }
        let wait = NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:isPreEvent:")
        guard let waitMethod = class_getInstanceMethod(process, wait) else {
            fatalError("XCUIApplicationProcess has no \(wait)")
        }
        typealias Wait = @convention(c) (AnyObject, Selector, Bool, Bool) -> Void
        nonisolated(unsafe) let originalWait = unsafeBitCast(method_getImplementation(waitMethod), to: Wait.self)
        let skippingWait: @convention(block) @Sendable (AnyObject, Bool, Bool) -> Void = { process, _, preEvent in
            originalWait(process, wait, false, preEvent)
        }
        method_setImplementation(waitMethod, imp_implementationWithBlock(skippingWait))

        let activityWait = NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:usingActivity:isPreEvent:")
        guard let activityMethod = class_getInstanceMethod(process, activityWait) else {
            fatalError("XCUIApplicationProcess has no \(activityWait)")
        }
        typealias ActivityWait = @convention(c) (AnyObject, Selector, Bool, Bool, Bool) -> Void
        nonisolated(unsafe) let originalActivityWait = unsafeBitCast(
            method_getImplementation(activityMethod), to: ActivityWait.self
        )
        let skippingActivityWait: @convention(block) @Sendable (AnyObject, Bool, Bool, Bool) -> Void = {
            process, _, activity, preEvent in
            originalActivityWait(process, activityWait, false, activity, preEvent)
        }
        method_setImplementation(activityMethod, imp_implementationWithBlock(skippingActivityWait))
    }
}
