import CryptoKit
import Foundation
import MetalKit
import Observation
import os
import SwiftTerm
import SwiftUI
import UIKit

/// Measurement for performance work, off unless the app is launched with `-probe YES`.
///
/// Once a second it appends a line to Documents/probe.jsonl with the process's physical footprint (the
/// number jetsam and Xcode's memory gauge use), how many terminals are open and how many draw with
/// Metal, the frames they have presented, the lines and bytes their local scrollback holds, the bytes
/// of output fed to them, how each terminal on screen sits in its card, and the session the app has open
/// (`selection`, its host and name, empty while none is). Each line carries the wall clock too, so a run
/// can be lined up with the host's record of the sizes it was sent, and the top of the on-screen keyboard
/// in screen points (`keyboard`, absent until it first moves), which sets the card's height, with how many
/// times it has left the screen since launch (`keyboardHides`). Launch, open, background and every move of
/// the keyboard get lines of their own. Every launch adds to the
/// file, and tools/device-test.sh empties it before a run, so the file holds each launch of that run. The
/// latest line is also the label of an invisible element named "probe", which is how the UI test reads it.
/// Each line says which way the interface stands too (`orientation`, UIInterfaceOrientation's raw value),
/// so a check can turn its screenshots upright: XCTest takes the screen as the panel lies, in portrait.
/// Each line also says where the window's chrome sits, in the window's points (`chrome`: the frames of the
/// views marked with `View.probeFrame`, by name, and of the on-screen keyboard as `keyboard`, each as x, y,
/// width and height), and how big the window is (`window`), so a check can see the chrome lies inside it and
/// above the keyboard: XCTest's frames for a window short of the screen mix the window's points with the
/// screen's, and the keyboard's own frame is in the screen's.
///
/// Each key typed gets a line too, with the parts of its trip to the screen in milliseconds: the system
/// delivering the key (`delivered`), the system's text input handing its text back (`texted`, zero for
/// keys Lhûn or SwiftTerm take straight from the press), Lhûn and SwiftTerm turning it into bytes for the
/// SSH channel (`handled`), the network and host echoing it (`network`), the main thread picking the echo
/// up (`queued`), and the frame that shows it reaching the screen (`drawn`). `direct` says whether Lhûn
/// typed the key itself; every sample counts those keys in `keysDirect`, and carries the bytes Lhûn has
/// written to the SSH channels (`sentCount`) with the last 256 of them in hex (`sent`), so a check can see
/// what a key sent, and the last 16 keys the app saw go down (`keysSeen`: key code, characters, the
/// characters without modifiers, and the modifier flags) with how many it has seen since launch
/// (`keysSeenCount`), so a check can see what the system delivered. The app sees a key at UIApplication's
/// sendEvent, before any of Lhûn's views, menus or key commands, so a key missing there never reached Lhûn.
///
/// Each copy Lhûn makes to the device's clipboard, a program's OSC 52 or a selection's, gets a line too
/// (`copy`): how many it has made since launch, and the size and SHA-256 of the text the clipboard holds
/// right after, in UTF-8, read back from the clipboard itself. Later lines carry the latest, which is how a
/// check sees a copy: the test runner cannot read the device's clipboard.
///
/// Each chime that plays gets a line too (`chime`), and that line and every later one list the sessions
/// the last 16 chimes were for, oldest first (`chimes`: host and name), so a check can tell which session
/// a chime was for.
///
/// Every sample also counts the sidebar rows drawn (`sidebarRows`). A UI test can mark a 10-second window for
/// XCTest to count the frames Lhûn presents: it posts the Darwin notification `framesWindow`, and the probe
/// brackets the next 10 seconds with an animation signpost (subsystem com.aktanazat.lhun, category probe,
/// name "frames"). The invisible label holds still meanwhile, or its redraw each second would be counted.
///
/// When a terminal's connection drops, the probe keeps the text its screen showed, and reads the screen
/// again as each of its frames is drawn, until 3 seconds after it is attached again. Every sample then
/// lists the latest of these (`reconnects`): the frames drawn, how many showed anything but the screen
/// from before the drop (`broken`: cleared, or redrawn halfway), whether the screen ended as it was
/// (`matched`), and the milliseconds from the drop until the session was attached again (`liveMs`).
/// A UI test can have the output stall partway through each attach, as a slow link would: with the launch
/// arguments `-stallAt <byte>` and `-stallFor <seconds>`, a terminal's output from that byte of each attach
/// on reaches it that many seconds late (`OutputStall`).
///
/// Every sample carries the open session's local echo too (`prediction`, EchoPrediction): the keys it
/// guessed (`guessed`), the guessed characters it drew (`shown`), how many of those the echo matched
/// (`confirmed`), how many were taken away unmatched (`erased`) and in how many goes (`erasures`), whether
/// guesses show (`on`), the echo delays it last measured (`delaysMs`), the guessed cells on screen now
/// (`showing`), whether the pane is on the alternate screen (`alternateScreen`) and shows its cursor
/// (`cursorShown`), and, for the last 64 keys whose guess was drawn, the milliseconds and display frames
/// from the key going down to the frame that shows the guess (`drawnMs`, `drawnFrames`).
///
/// The command palette gets a line each time it puts up what a key asked for (`palette`): `step` says
/// whether it opened, narrowed to what was typed, or moved its highlight, with the milliseconds and display
/// frames from that key going down to the frame that shows it (`ms`, `frames`), the milliseconds of those
/// that passed before Lhûn got the key (`received`, where XCTest's keyboard can add a tenth of a second a
/// real one does not), the rows it lists (`rows`) and the rows drawn for that frame (`drawn`), which stays
/// at what fits on the card however long the list. `focusedFirst` says a text field took the keyboard
/// after the key and before that frame began: taking it costs the iPad about 60 ms, which the frame then
/// waits out.
///
/// Every sample also carries what the process has spent since it started, for a check to take
/// differences of (`costs()`): CPU time, instructions, wakeups, the kernel's energy estimate, GPU time,
/// and memory beyond the footprint; and how many sessions the hosts list (`sessionsListed`), each a pill
/// that costs memory. The launch line and each return to the screen carry the milliseconds since the
/// process started (`sinceExec`), and the launch line the scene a test names with the launch argument
/// `-probeRun` (`run`), so a run that launches Lhûn several times can tell its parts apart. A launch that
/// opens a session logs the first frame that shows it with any text (`readable`) and the first that shows
/// tmux's own redraw of it (`current`), each with the milliseconds since the process started.
///
/// A UI test can have a stretch measured with the probe out of the way: it posts the Darwin notification
/// `window`, and for the next 30 seconds the probe takes no samples of its own and holds its label still,
/// logging one sample as the window opens ("window") and one as it closes ("window end"), so the costs
/// between are Lhûn's alone; later samples carry how much each counter grew in it (`lastWindow`). An
/// animation signpost (name "window") brackets the same 30 seconds for XCTest's frame and hitch counts.
///
/// Each time a terminal builds its Metal renderer, as it comes on screen, the probe measures what the build
/// took, in bytes of heap (`rendererHeap`) and of Metal memory (`rendererMetal`), most of it the glyph
/// atlases it starts with. Later samples carry the latest.
///
/// A UI test can have one thing it does traced frame by frame (`MotionTrace`): it posts the Darwin
/// notification `motion`, and for the next 4 seconds the probe takes no samples of its own and holds its
/// label still. The log gets the trace's summary and every position it took ("motion trace"), and later
/// samples carry the summary (`lastMotion`).
@MainActor @Observable
final class Probe {
    static let isOn = LhunDefaults.shared.bool(forKey: "probe")

    private(set) var latest = ""

    @ObservationIgnored private let terminals: () -> [TerminalModel]
    @ObservationIgnored private let selection: () -> SessionRef?
    /// How many sessions the hosts list, each a pill in the strip.
    @ObservationIgnored private let listed: () -> Int
    @ObservationIgnored private let file: FileHandle?
    @ObservationIgnored private let start = Date()
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    @ObservationIgnored private var frames: NSObjectProtocol?
    @ObservationIgnored private var keyboardMoves: NSObjectProtocol?
    @ObservationIgnored private var keyboardTop: Double?
    @ObservationIgnored private var keyboardHideCount = 0
    @ObservationIgnored private var keystroke: Keystroke?
    @ObservationIgnored private var keysTimed = 0
    @ObservationIgnored private var keysDirect = 0
    @ObservationIgnored private var lastSent: [UInt8] = []
    @ObservationIgnored private var sentCount = 0
    @ObservationIgnored private var keysSeen: [String] = []
    @ObservationIgnored private var keysSeenCount = 0
    /// When the latest key went down, by the event's own time, and when Lhûn got it, until the palette times
    /// a step from it.
    @ObservationIgnored private var lastPress: (down: TimeInterval, received: TimeInterval)?
    @ObservationIgnored private var fieldsFocused: NSObjectProtocol?
    /// When a text field last took the keyboard.
    @ObservationIgnored private var fieldFocused: TimeInterval?
    @ObservationIgnored private var holdsLabel = false
    @ObservationIgnored private var clipboardChanges: NSObjectProtocol?
    @ObservationIgnored private var copies = 0
    @ObservationIgnored private var copy: [String: Any]?
    @ObservationIgnored private var chimes: [[String: String]] = []
    /// Terminals whose connection dropped, by view, from the drop until 3 seconds after they are back.
    @ObservationIgnored private var reconnecting: [ObjectIdentifier: Reconnect] = [:]
    @ObservationIgnored private var reconnects: [[String: Any]] = []
    /// Key down to the frame showing its guess, for the last keys whose guess was drawn.
    @ObservationIgnored private var guessesDrawn: [(ms: Double, frames: Int)] = []
    /// What the last measuring window cost, once it has closed.
    @ObservationIgnored private var lastWindow: [String: Any]?
    /// What the last terminal renderer build took, in bytes (`measureRenderer`).
    @ObservationIgnored private var renderer: [String: Int]?
    /// What the last motion trace saw, once it has ended.
    @ObservationIgnored private var lastMotion: [String: Any]?
    /// The launch has shown the open session with text on it, and with tmux's redraw of it.
    @ObservationIgnored private var launchReadable = false
    @ObservationIgnored private var launchCurrent = false
    /// Where the views marked with `View.probeFrame` sit in the window, by name, while they are on screen, and
    /// the on-screen keyboard as `keyboard`.
    @ObservationIgnored var chrome: [String: CGRect] = [:]
    /// The session a UI test has the pointer rest on, standing in for a trackpad: XCTest's hover reaches no
    /// SwiftUI hover handler, on the simulator or the iPad. The test names the session with the launch
    /// argument `-probePointer <host>.<name>` and posts `pointerRest` and `pointerLeave`.
    private(set) var pointer: SessionRef?

    static let framesWindow = "com.aktanazat.lhun.probe.frames"
    static let window = "com.aktanazat.lhun.probe.window"
    static let windowSeconds = 30
    static let pointerRest = "com.aktanazat.lhun.probe.pointer.rest"
    static let pointerLeave = "com.aktanazat.lhun.probe.pointer.leave"
    static let motion = "com.aktanazat.lhun.probe.motion"
    static let motionSeconds = 4
    private static let signposter = OSSignposter(subsystem: "com.aktanazat.lhun", category: "probe")

    /// One key on its way to the screen, in seconds on the CACurrentMediaTime clock.
    private struct Keystroke {
        /// The key went down: the event's own time.
        let pressed: TimeInterval
        /// The terminal view got the event.
        let received: TimeInterval
        /// The key's text reached SwiftTerm.
        var inserted: TimeInterval?
        /// Lhûn typed the key itself instead of waiting for the system's text input.
        var directly = false
        /// Its bytes went to the SSH channel.
        var sent: TimeInterval?
        /// The first output after that came off the network.
        var echoed: TimeInterval?
        /// That output reached the main thread, which feeds it to the terminal.
        var dequeued: TimeInterval?
    }

    init(
        terminals: @escaping () -> [TerminalModel], selection: @escaping () -> SessionRef?, listed: @escaping () -> Int
    ) {
        self.terminals = terminals
        self.selection = selection
        self.listed = listed
        let url = URL.documentsDirectory.appending(path: "probe.jsonl")
        if !FileManager.default.fileExists(atPath: url.path()) {
            FileManager.default.createFile(atPath: url.path(), contents: nil)
        }
        file = try? FileHandle(forWritingTo: url)
        _ = try? file?.seekToEnd()
        record("launch", details: [
            "sinceExec": Self.sinceExec() ?? -1,
            "run": LhunDefaults.shared.string(forKey: "probeRun") ?? "",
        ])
        ticker = tick()
        Self.watchPresses(self)
        fieldsFocused = NotificationCenter.default.addObserver(
            forName: UITextField.textDidBeginEditingNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fieldFocused = CACurrentMediaTime() }
        }
        // SwiftTerm posts this on the main thread for every frame a terminal presents, with the terminal's
        // view. Without a queue the block runs right there, so the time it reads carries no extra hop.
        frames = NotificationCenter.default.addObserver(
            forName: .terminalViewMetalRendererStatusDidChange, object: nil, queue: nil
        ) { [weak self] note in
            let view = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { self?.framePresented(by: view) }
        }
        keyboardMoves = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            MainActor.assumeIsolated { self?.keyboardMoved(to: frame) }
        }
        // iOS posts this for the app's own changes only, so reading the clipboard back never asks to paste.
        clipboardChanges = NotificationCenter.default.addObserver(
            forName: UIPasteboard.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clipboardChanged() }
        }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let probe = Unmanaged<Probe>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in probe.markFrameWindow() }
            },
            Self.framesWindow as CFString, nil, .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let probe = Unmanaged<Probe>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in probe.markWindow() }
            },
            Self.window as CFString, nil, .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let probe = Unmanaged<Probe>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in probe.pointer = Probe.pointerTarget() }
            },
            Self.pointerRest as CFString, nil, .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let probe = Unmanaged<Probe>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in probe.pointer = nil }
            },
            Self.pointerLeave as CFString, nil, .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let probe = Unmanaged<Probe>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in probe.markMotion() }
            },
            Self.motion as CFString, nil, .deliverImmediately
        )
    }

    /// The session `-probePointer <host>.<name>` names.
    private static func pointerTarget() -> SessionRef? {
        guard let target = LhunDefaults.shared.string(forKey: "probePointer"),
              let dot = target.firstIndex(of: ".")
        else { return nil }
        return SessionRef(host: String(target[..<dot]), name: String(target[target.index(after: dot)...]))
    }

    /// Samples once a second until cancelled.
    private func tick() -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.record(nil)
            }
        }
    }

    /// Measures the next 30 seconds with the probe out of the way: no samples between the two at its
    /// ends, the label held still, an animation signpost around it for XCTest.
    private func markWindow() {
        guard !holdsLabel else { return }
        ticker?.cancel()
        holdsLabel = true
        let opened = record("window")
        let window = Self.signposter.beginAnimationInterval("window", id: Self.signposter.makeSignpostID())
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.windowSeconds))
            Self.signposter.endInterval("window", window)
            guard let self else { return }
            holdsLabel = false
            lastWindow = Self.spent(from: opened, to: record("window end"))
            ticker = tick()
        }
    }

    /// How much each counter grew between two samples, for the samples after a window (`lastWindow`).
    private static func spent(from opened: [String: Any], to closed: [String: Any]) -> [String: Any] {
        var spent: [String: Any] = ["seconds": windowSeconds]
        for key in ["frames", "bytesFed", "cpuMs", "instructions", "wakeups", "idleWakeups", "energyMj", "gpuMs"] {
            guard let start = (opened[key] as? NSNumber)?.doubleValue, let end = (closed[key] as? NSNumber)?.doubleValue
            else { continue }
            spent[key] = ((end - start) * 10).rounded() / 10
        }
        return spent
    }

    /// Brackets the next 10 seconds for XCTest's frame count, holding the label still meanwhile.
    private func markFrameWindow() {
        guard !holdsLabel else { return }
        record("frames window")
        holdsLabel = true
        let window = Self.signposter.beginAnimationInterval("frames", id: Self.signposter.makeSignpostID())
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            Self.signposter.endInterval("frames", window)
            self?.holdsLabel = false
            self?.record("frames window end")
        }
    }

    /// Traces the next 4 seconds frame by frame (`MotionTrace`), with the probe out of the way meanwhile.
    private func markMotion() {
        guard !holdsLabel else { return }
        ticker?.cancel()
        holdsLabel = true
        record("motion")
        let trace = MotionTrace(terminals: terminals)
        trace.start()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.motionSeconds))
            let (summary, frames) = trace.stop()
            guard let self else { return }
            lastMotion = summary
            record("motion trace", details: ["motionFrames": frames])
            holdsLabel = false
            record("motion end")
            ticker = tick()
        }
    }

    /// Keeps sampling for 15 seconds after the app leaves the screen, long enough to measure it after
    /// 10 seconds away; iOS would otherwise suspend it within a few seconds.
    func enteredBackground() {
        record("background")
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            self?.endBackgroundTask()
        }
    }

    func becameActive() {
        record("active", details: ["sinceExec": Self.sinceExec() ?? -1])
    }

    /// The chime played for these sessions.
    func chimed(_ sessions: [SessionRef]) {
        chimes = Array((chimes + sessions.map { ["host": $0.host, "name": $0.name] }).suffix(16))
        record("chime")
    }

    @discardableResult
    func record(_ event: String?, details: [String: Any] = [:]) -> [String: Any] {
        let open = terminals()
        let views = open.map(\.view)
        let scrollback = views.map { $0.getTerminal().getTopVisibleRow() }
        let scene = UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first
        let window = scene?.effectiveGeometry.coordinateSpace.bounds.size
        var sample: [String: Any] = [
            "t": (Date().timeIntervalSince(start) * 10).rounded() / 10,
            "footprint": Self.footprint(),
            "terminals": views.count,
            "metal": views.filter { $0.metalRendererStatus.state != .disabled }.count,
            "frames": views.reduce(0) { $0 + Int($1.metalRendererStatus.presentedFrameCount) },
            "scrollbackLines": scrollback.reduce(0, +),
            "scrollbackBytes": zip(views, scrollback).reduce(0) {
                $0 + $1.1 * $1.0.getTerminal().cols * MemoryLayout<CharData>.stride
            },
            "bytesFed": open.reduce(0) { $0 + $1.bytesFed },
            "sessionsListed": listed(),
            "grids": open.compactMap(Self.grid(of:)),
            "at": (Date().timeIntervalSince1970 * 100).rounded() / 100,
            "keys": keysTimed,
            "contrastHits": Theme.contrast.hits,
            "contrastMisses": Theme.contrast.misses,
            "theme": ThemeStore.shared.probe,
            "backgrounds": views.map { String(format: "%06X", Theme.hex($0.nativeBackgroundColor)) },
            "keysDirect": keysDirect,
            "sent": lastSent.map { String(format: "%02x", $0) }.joined(),
            "sentCount": sentCount,
            "keysSeen": keysSeen,
            "keysSeenCount": keysSeenCount,
            "reduceMotion": UIAccessibility.isReduceMotionEnabled,
            "sidebarRows": SessionSidebar.rows,
            // The sidebar's folds since launch: those that slid, and those that happened at once.
            "sidebarFolds": SessionSidebar.folds,
            // The open history overlay, or none once it has closed and let go of what it read.
            "history": HistoryView.latest?.measurements ?? [:],
            // Copy flashes and kill fades on screen; none once they have ended and let go of their layers.
            "effects": Effects.running,
            // Screens the hover picture captured, and the one it shows with its pixels; none once it goes.
            "hover": HoverPicture.measurements,
            "selection": selection().map { ["host": $0.host, "name": $0.name] } ?? [:],
            "orientation": scene?.effectiveGeometry.interfaceOrientation.rawValue ?? 0,
            "chrome": chrome.compactMapValues { frame in
                let numbers = [frame.minX, frame.minY, frame.width, frame.height]
                return numbers.allSatisfy(\.isFinite) ? numbers.map(Self.hundredths) : nil
            },
            "window": window.map { [$0.width, $0.height].map(Self.hundredths) } ?? [],
        ]
        if let event { sample["event"] = event }
        if let keyboardTop {
            sample["keyboard"] = keyboardTop
            sample["keyboardHides"] = keyboardHideCount
        }
        if let copy { sample["copy"] = copy }
        if !chimes.isEmpty { sample["chimes"] = chimes }
        if !reconnects.isEmpty { sample["reconnects"] = reconnects }
        if let selected = selection(), let terminal = open.first(where: { $0.ref == selected }) {
            sample["prediction"] = prediction(of: terminal)
        }
        if let lastWindow { sample["lastWindow"] = lastWindow }
        if let lastMotion { sample["lastMotion"] = lastMotion }
        if let renderer { sample.merge(renderer) { _, built in built } }
        sample.merge(details) { _, detail in detail }
        sample.merge(Self.costs()) { current, _ in current }
        guard let line = try? JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys]) else { return sample }
        file?.write(line + Data([0x0A]))
        if !holdsLabel { latest = String(decoding: line, as: UTF8.self) }
        return sample
    }

    // MARK: Typing

    func keyDown(at pressed: TimeInterval) {
        keystroke = Keystroke(pressed: pressed, received: CACurrentMediaTime())
    }

    /// Has every key the app receives go to `pressed(_:)` as it goes down, from UIApplication's sendEvent,
    /// the first place the app gets a key.
    private static func watchPresses(_ probe: Probe) {
        let selector = #selector(UIApplication.sendEvent(_:))
        guard let method = class_getInstanceMethod(UIApplication.self, selector) else { return }
        typealias Send = @convention(c) (UIApplication, Selector, UIEvent) -> Void
        let send = unsafeBitCast(method_getImplementation(method), to: Send.self)
        let watched: @convention(block) (UIApplication, UIEvent) -> Void = { [weak probe] app, event in
            MainActor.assumeIsolated {
                if let presses = event as? UIPressesEvent {
                    for press in presses.allPresses where press.phase == .began {
                        if let key = press.key { probe?.pressed(key, at: press.timestamp) }
                    }
                }
                send(app, selector, event)
            }
        }
        method_setImplementation(method, imp_implementationWithBlock(watched))
    }

    private func pressed(_ key: UIKey, at time: TimeInterval) {
        lastPress = (time, CACurrentMediaTime())
        let seen = "\(key.keyCode.rawValue) \(key.characters.debugDescription) \(key.charactersIgnoringModifiers.debugDescription) \(key.modifierFlags.rawValue)"
        keysSeen = Array((keysSeen + [seen]).suffix(16))
        keysSeenCount += 1
    }

    func keyInserted(directly: Bool) {
        guard keystroke != nil, keystroke?.inserted == nil, keystroke?.sent == nil else { return }
        keystroke?.inserted = CACurrentMediaTime()
        keystroke?.directly = directly
    }

    func keySent(_ bytes: ArraySlice<UInt8>) {
        lastSent = Array((lastSent + bytes).suffix(256))
        sentCount += bytes.count
        guard keystroke != nil, keystroke?.sent == nil else { return }
        keystroke?.sent = CACurrentMediaTime()
    }

    /// `echoed` is when the output came off the network, read on the network's thread.
    func outputArrived(at echoed: TimeInterval) {
        guard let sent = keystroke?.sent, echoed > sent, keystroke?.echoed == nil else { return }
        keystroke?.echoed = echoed
        keystroke?.dequeued = CACurrentMediaTime()
    }

    /// Builds a terminal's Metal renderer, measuring the heap and Metal memory the build took.
    func measureRenderer(_ build: () throws -> Void) rethrows {
        let device = MTLCreateSystemDefaultDevice()
        let heap = Self.heapInUse(), metal = device?.currentAllocatedSize ?? 0
        try build()
        renderer = [
            "rendererHeap": Self.heapInUse() - heap,
            "rendererMetal": (device?.currentAllocatedSize ?? 0) - metal,
        ]
    }

    private func framePresented(by view: ObjectIdentifier?) {
        if !launchCurrent, let view { launchFrame(view) }
        guard let key = keystroke, let sent = key.sent, let echoed = key.echoed, let dequeued = key.dequeued
        else { return }
        let shown = CACurrentMediaTime()
        keystroke = nil
        keysTimed += 1
        if key.directly { keysDirect += 1 }
        let ms = { (seconds: TimeInterval) in (seconds * 10_000).rounded() / 10 }
        let texted = key.inserted ?? key.received
        record("key", details: [
            "delivered": ms(key.received - key.pressed),
            "texted": ms(texted - key.received),
            "handled": ms(sent - texted),
            "network": ms(echoed - sent),
            "queued": ms(dequeued - echoed),
            "drawn": ms(shown - dequeued),
            "direct": key.directly,
        ])
    }

    /// Logs the first frames after launch that show the open session: with any text on it, and with tmux's
    /// own redraw of it.
    private func launchFrame(_ view: ObjectIdentifier) {
        guard let terminal = terminals().first(where: { ObjectIdentifier($0.view) == view }), terminal.ref == selection()
        else { return }
        let screen = terminal.view.getTerminal()
        if !launchReadable, (0..<screen.rows).contains(where: { !Self.blank(screen, row: $0) }) {
            launchReadable = true
            record("readable", details: ["sinceExec": Self.sinceExec() ?? -1, "session": terminal.name])
        }
        if terminal.redrawsShown > 0 {
            launchCurrent = true
            record("current", details: ["sinceExec": Self.sinceExec() ?? -1, "session": terminal.name])
        }
    }

    /// `frame` is where the keyboard is going, in the screen's points. The samples carry its top as it is, and
    /// `chrome` its frame in the window's points.
    private func keyboardMoved(to frame: CGRect) {
        let window = UIApplication.shared.connectedScenes.lazy.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        if let window, let screen = window.windowScene?.screen {
            chrome["keyboard"] = window.convert(frame, from: screen.coordinateSpace)
        }
        let top = Double(frame.minY.rounded())
        guard top != keyboardTop else { return }
        keyboardTop = top
        if let screen = window?.windowScene?.screen, !frame.intersects(screen.coordinateSpace.bounds) {
            keyboardHideCount += 1
        }
        record("keyboard")
    }

    private func clipboardChanged() {
        let text = Data((UIPasteboard.general.string ?? "").utf8)
        copies += 1
        copy = [
            "count": copies,
            "bytes": text.count,
            "sha256": SHA256.hash(data: text).map { String(format: "%02x", $0) }.joined(),
        ]
        record("copy")
    }

    // MARK: Local echo

    private func prediction(of terminal: TerminalModel) -> [String: Any] {
        let prediction = terminal.prediction
        return [
            "guessed": prediction.counts.guessed,
            "shown": prediction.counts.shown,
            "confirmed": prediction.counts.confirmed,
            "erased": prediction.counts.erased,
            "erasures": prediction.counts.erasures,
            "on": prediction.isOn,
            "delaysMs": prediction.delays.map { ($0 * 10_000).rounded() / 10 },
            "showing": terminal.view.predictionCells,
            "alternateScreen": terminal.alternateScreen,
            "cursorShown": terminal.view.cursorShown,
            "drawnMs": guessesDrawn.map(\.ms),
            "drawnFrames": guessesDrawn.map(\.frames),
        ]
    }

    /// The key just sent had its guess drawn: times it from the key going down to the frame that shows it,
    /// the next the display puts up.
    func guessShown() {
        guard let pressed = keystroke?.pressed else { return }
        NextFrame.wait { [weak self] link in
            guard let self else { return }
            let ms = (link.targetTimestamp - pressed) * 1000
            let frame = (link.targetTimestamp - link.timestamp) * 1000
            let drawn = (ms: (ms * 10).rounded() / 10, frames: Int((ms / frame).rounded(.up)))
            guessesDrawn = Array((guessesDrawn + [drawn]).suffix(64))
        }
    }

    // MARK: Palette

    /// The palette has just taken in what a key asked for, its `step`, and lists `rows` rows: times it from
    /// the key going down to the frame that shows it, the next the display puts up. A step no key asked
    /// for in the last second, such as a tap, is not timed.
    func paletteDrawn(_ step: String, rows: Int) {
        guard let press = lastPress else { return }
        lastPress = nil
        NextFrame.wait { [weak self] link in
            let ms = (link.targetTimestamp - press.down) * 1000
            guard let self, ms < 1000 else { return }
            let frame = (link.targetTimestamp - link.timestamp) * 1000
            let focusedFirst = fieldFocused.map { $0 > press.down && $0 < link.timestamp } ?? false
            record("palette", details: [
                "step": step, "ms": (ms * 10).rounded() / 10, "frames": Int((ms / frame).rounded(.up)), "rows": rows,
                "drawn": Palette.rowsDrawn, "received": ((press.received - press.down) * 10000).rounded() / 10,
                "focusedFirst": focusedFirst,
            ])
        }
    }

    // MARK: Reconnecting

    /// One terminal between its connection dropping and 3 seconds after it is attached again.
    private struct Reconnect {
        let session: String
        /// The text the screen showed when the connection dropped.
        let screen: String
        let dropped: TimeInterval
        let watch: DrawWatch?
        var attached: TimeInterval?
        var frames = 0
        var broken = 0
    }

    /// The terminal's connection dropped while it was attached.
    func connectionDropped(_ terminal: TerminalModel) {
        let view = terminal.view
        let id = ObjectIdentifier(view)
        reconnecting[id]?.watch?.end()
        let watch = DrawWatch(view) { [weak self, weak view] in
            guard let self, let view, let screen = self.reconnecting[id]?.screen else { return }
            self.reconnecting[id]?.frames += 1
            if Self.screen(of: view) != screen { self.reconnecting[id]?.broken += 1 }
        }
        reconnecting[id] = Reconnect(
            session: terminal.name, screen: Self.screen(of: view), dropped: CACurrentMediaTime(), watch: watch
        )
        record("dropped \(terminal.name)")
    }

    /// The terminal is attached again, after a drop or for the first time.
    func attached(_ terminal: TerminalModel) {
        let id = ObjectIdentifier(terminal.view)
        guard reconnecting[id] != nil, reconnecting[id]?.attached == nil else { return }
        reconnecting[id]?.attached = CACurrentMediaTime()
        Task { [weak self, weak terminal] in
            try? await Task.sleep(for: .seconds(3))
            self?.endReconnect(id, terminal)
        }
    }

    private func endReconnect(_ id: ObjectIdentifier, _ terminal: TerminalModel?) {
        guard let reconnect = reconnecting.removeValue(forKey: id), let attached = reconnect.attached else { return }
        reconnect.watch?.end()
        reconnects = Array((reconnects + [[
            "session": reconnect.session,
            "frames": reconnect.frames,
            "broken": reconnect.broken,
            "matched": terminal.map { Self.screen(of: $0.view) == reconnect.screen } ?? false,
            "liveMs": ((attached - reconnect.dropped) * 1000).rounded(),
        ]]).suffix(20))
        record("redrawn \(reconnect.session)")
    }

    /// A stall for one attach's output, when the launch arguments ask for one.
    func outputStall() -> OutputStall? {
        let seconds = LhunDefaults.shared.double(forKey: "stallFor")
        guard seconds > 0 else { return nil }
        return OutputStall(at: LhunDefaults.shared.integer(forKey: "stallAt"), seconds: seconds)
    }

    /// The text on a terminal's screen, row by row.
    private static func screen(of view: TerminalView) -> String {
        let terminal = view.getTerminal()
        return (0..<terminal.rows)
            .map { terminal.getLine(row: $0)?.translateToString(trimRight: true) ?? "" }
            .joined(separator: "\n")
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// How a terminal on screen sits in its card. It fits when its view lies inside the card, its grid of
    /// whole cells covers the view exactly, and the card has no room left for another column or row. While
    /// another screen sets the session's size the grid is that screen's window instead: never bigger, and
    /// smaller only where the card has no room for more. It also says whether the terminal takes typing,
    /// how many sizes it has sent tmux since it attached, and whether it keeps its grid for now (`held`)
    /// while the cards move or the keyboard is away (`TerminalHost.holdsGrid`), fitting once they rest.
    /// Last, what reaches the eye: whether the view shows at all (`seen`), how many of its rows hold text
    /// (`textRows`), and whether the cursor's row does (`cursorText`), where a program such as omp keeps
    /// its input line.
    private static func grid(of terminal: TerminalModel) -> [String: Any]? {
        let view = terminal.view
        guard let card = view.superview else { return nil }
        let size = view.getTerminal()
        let cols = CGFloat(size.cols), rows = CGFloat(size.rows)
        let grid = view.getOptimalFrameSize().size
        let cell = terminal.cellSize
        let frame = view.frame
        let padding = TerminalHost.padding
        let room = CGSize(
            width: card.bounds.width - padding.left - padding.right,
            height: card.bounds.height - padding.top - padding.bottom
        )
        var problems: [String] = []
        if !card.bounds.contains(frame) { problems.append("outside the card") }
        if !(cols * cell.width <= frame.width && frame.width < (cols + 1) * cell.width) {
            problems.append("columns disagree with the view")
        }
        if !(rows * cell.height <= frame.height && frame.height < (rows + 1) * cell.height) {
            problems.append("rows disagree with the view")
        }
        if abs(frame.width - grid.width) > 0.01 { problems.append("part of a column") }
        if abs(frame.height - grid.height) > 0.01 { problems.append("part of a row") }
        var watched: (cols: CGFloat, rows: CGFloat)?
        if case .watch(let cols, let rows) = terminal.sizing { watched = (CGFloat(cols), CGFloat(rows)) }
        if let watched, cols > watched.cols || rows > watched.rows { problems.append("bigger than the window") }
        if cols < watched?.cols ?? .infinity, room.width >= (cols + 1) * cell.width { problems.append("room for another column") }
        if rows < watched?.rows ?? .infinity, room.height >= (rows + 1) * cell.height { problems.append("room for another row") }
        var entry: [String: Any] = [
            "session": terminal.name,
            "cols": size.cols,
            "rows": size.rows,
            "font": Double(terminal.fontSize),
            "face": terminal.face.rawValue,
            "fit": problems.isEmpty ? "ok" : problems.joined(separator: ", "),
            "view": [frame.minX, frame.minY, frame.width, frame.height].map(Self.hundredths),
            "card": [card.bounds.width, card.bounds.height].map(Self.hundredths),
            "cell": [cell.width, cell.height].map(Self.hundredths),
            "focused": view.isFirstResponder,
            "resizes": terminal.resizes,
            "shared": terminal.shared,
            "held": (card as? TerminalHost)?.holdsGrid ?? false,
            "seen": !view.isHidden && view.alpha > 0,
            "textRows": (0..<size.rows).count { !Self.blank(size, row: $0) },
            "cursorText": !Self.blank(size, row: size.getCursorLocation().y),
        ]
        if let watched { entry["window"] = "\(Int(watched.cols))x\(Int(watched.rows))" }
        return entry
    }

    /// Whether a row of the screen holds no text.
    private static func blank(_ terminal: Terminal, row: Int) -> Bool {
        terminal.getLine(row: row)?.translateToString(trimRight: true).isEmpty ?? true
    }

    /// A point measure to two decimal places, as the samples carry it.
    private static func hundredths(_ value: CGFloat) -> Double {
        Double((value * 100).rounded() / 100)
    }

    /// The process's physical footprint in bytes.
    static func footprint() -> Int {
        vmInfo().map { Int($0.phys_footprint) } ?? -1
    }

    private static func vmInfo() -> task_vm_info_data_t? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info : nil
    }

    /// What the process has spent since it started: CPU time in milliseconds (`cpuMs`), instructions
    /// retired (`instructions`), wakeups (`wakeups`) with those that brought a core out of idle, the ones
    /// that cost battery, apart (`idleWakeups`), the energy the kernel reckons the CPU spent on it in
    /// millijoules (`energyMj`: the kernel's estimate from the cores' own counters, not a battery reading),
    /// and GPU time in milliseconds (`gpuMs`). Beside the footprint: the most it has ever been (`peak`),
    /// the graphics memory held (`graphics`: textures, drawables and other surfaces), and the bytes malloc
    /// has handed out and not had back (`heap`).
    private static func costs() -> [String: Any] {
        var costs: [String: Any] = [:]
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            let micros = (usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000_000
                + Int(usage.ru_utime.tv_usec) + Int(usage.ru_stime.tv_usec)
            costs["cpuMs"] = Double(micros / 100) / 10
        }
        var counts = task_inspect_basic_counts_data_t()
        var countsSize = mach_msg_type_number_t(
            MemoryLayout<task_inspect_basic_counts_data_t>.size / MemoryLayout<natural_t>.size
        )
        let counted = withUnsafeMutablePointer(to: &counts) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(countsSize)) {
                task_inspect(mach_task_self_, TASK_INSPECT_BASIC_COUNTS.rawValue, $0, &countsSize)
            }
        }
        if counted == KERN_SUCCESS { costs["instructions"] = counts.instructions }
        var power = task_power_info_v2_data_t()
        var powerSize = mach_msg_type_number_t(MemoryLayout<task_power_info_v2_data_t>.size / MemoryLayout<natural_t>.size)
        let powered = withUnsafeMutablePointer(to: &power) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(powerSize)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO_V2), $0, &powerSize)
            }
        }
        if powered == KERN_SUCCESS {
            costs["wakeups"] = power.cpu_energy.task_interrupt_wakeups
            costs["idleWakeups"] = power.cpu_energy.task_platform_idle_wakeups
            // The Intel simulator's power info has no energy total, and a simulator build compiles that slice too.
            #if arch(arm64)
            costs["energyMj"] = Double(power.task_energy / 1000) / 1000
            #endif
            costs["gpuMs"] = Double(power.gpu_energy.task_gpu_utilisation / 100_000) / 10
        }
        if let info = vmInfo() {
            costs["peak"] = Int(info.ledger_phys_footprint_peak)
            costs["graphics"] = Int(info.ledger_tag_graphics_footprint)
        }
        costs["heap"] = heapInUse()
        return costs
    }

    /// The bytes malloc has handed out and not had back.
    private static func heapInUse() -> Int {
        var heap = malloc_statistics_t()
        malloc_zone_statistics(nil, &heap)
        return Int(heap.size_in_use)
    }

    /// When the process started, in seconds since 1970, from the kernel's record of it.
    private static let processStart: TimeInterval? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000
    }()

    /// Milliseconds since the process started.
    private static func sinceExec() -> Double? {
        processStart.map { ((Date().timeIntervalSince1970 - $0) * 10_000).rounded() / 10 }
    }
}

/// Stands between a terminal's Metal view and SwiftTerm's renderer, to be told as each frame is drawn,
/// with the terminal as the frame shows it: the frame-presented notification comes a frame or more later,
/// when more output may have changed the screen.
@MainActor
private final class DrawWatch: NSObject, MTKViewDelegate {
    private weak var metalView: MTKView?
    private weak var renderer: (any MTKViewDelegate)?
    private let drawing: () -> Void

    /// Nil while the terminal draws without Metal, off screen: it draws no frames then.
    init?(_ view: TerminalView, drawing: @escaping () -> Void) {
        guard let metalView = view.subviews.lazy.compactMap({ $0 as? MTKView }).first,
              let renderer = metalView.delegate
        else { return nil }
        self.metalView = metalView
        self.renderer = renderer
        self.drawing = drawing
        super.init()
        metalView.delegate = self
    }

    func end() {
        guard let metalView, metalView.delegate === self else { return }
        metalView.delegate = renderer
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        renderer?.mtkView(view, drawableSizeWillChange: size)
    }

    func draw(in view: MTKView) {
        drawing()
        renderer?.draw(in: view)
    }
}

/// One attach's output, reaching the terminal late from one of its bytes on, as over a link that stalls
/// partway: the bytes before `at` go on at once, and from there on everything waits `seconds`, then goes on
/// in order. tools/echo.sh drops a connection only seconds after its stall has ended.
@MainActor
final class OutputStall {
    private enum Phase {
        case before(passed: Int)
        case stalled(late: [UInt8])
        case over
    }

    private let at: Int
    private let seconds: Double
    private var phase = Phase.before(passed: 0)

    init(at: Int, seconds: Double) {
        self.at = at
        self.seconds = seconds
    }

    /// Hands output on to `deliver`, now or once the stall ends.
    func pass(_ bytes: [UInt8], to deliver: @escaping @MainActor @Sendable ([UInt8]) -> Void) {
        switch phase {
        case .over:
            deliver(bytes)
        case .stalled(let late):
            phase = .stalled(late: late + bytes)
        case .before(let passed):
            let now = min(bytes.count, at - passed)
            guard now < bytes.count else {
                phase = .before(passed: passed + now)
                return deliver(bytes)
            }
            if now > 0 { deliver(Array(bytes[..<now])) }
            phase = .stalled(late: Array(bytes[now...]))
            let end = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.end(deliver) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: end)
        }
    }

    /// The late output goes on, and output from here on goes straight through.
    private func end(_ deliver: @MainActor ([UInt8]) -> Void) {
        guard case .stalled(let late) = phase else { return }
        phase = .over
        deliver(late)
    }
}

extension View {
    /// While the probe runs, tells it where this view sits in the window, under `name`.
    func probeFrame(_ name: String) -> some View {
        modifier(ProbeFrame(name: name))
    }
}

private struct ProbeFrame: ViewModifier {
    let name: String
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        if let probe = model.probe {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.chrome[name] = $0 }
                .onDisappear { probe.chrome[name] = nil }
        } else {
            content
        }
    }
}
