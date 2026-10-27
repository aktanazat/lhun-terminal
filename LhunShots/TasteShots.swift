import UIKit
import XCTest

/// Every surface of Lhûn outside the terminal's own grid, photographed in light and then in dark, for a look
/// at its design on the device in hand: the device key sheet, the empty screen, a session, two cards, the key
/// row, the host's menu and a session's, renaming and killing a session, the palette as it opens, finds
/// sessions, offers a new one and lists its settings and fonts, the theme picker, renaming a window, the port
/// to preview, the inbox and a catch-up, the three path pickers, the pulled-down pictures and, on an iPad, the
/// sidebar. Run it through tools/taste.sh, which makes the sessions it shows on the Mac: <TASTE_PREFIX>-shell,
/// a shell in a small project with a second window, <TASTE_PREFIX>-job, running sleep so it reads as working,
/// and <TASTE_PREFIX>-done, which printed a test run and reported it done. Each picture,
/// <order>-<surface>-<light|dark>.png, waits until its scene holds still. An iPad is held sideways and an
/// iPhone upright, and both go back to the way they were held, and to their appearance, when it ends, pass or
/// fail. Nothing is renamed, killed, made or chosen: every question is answered no. Theme…, Rename Window…
/// and Preview Port… open only from the palette, which keeps them among its recent commands.
final class TasteShots: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testEverySurfaceInLightAndDark() throws {
        let tour = try Tour(self)
        let appearance = XCUIDevice.shared.appearance
        addTeardownBlock { @MainActor in XCUIDevice.shared.appearance = appearance == .light ? .light : .dark }
        let held: [UIDeviceOrientation] = tour.pad ? [.landscapeLeft, .landscapeRight] : [.portrait]
        let original = XCUIDevice.shared.orientation
        if !held.contains(original) {
            XCUIDevice.shared.orientation = held[0]
            // A device lying flat stays as the tour held it.
            if [.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight].contains(original) {
                addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = original }
            }
        }
        XCUIDevice.shared.appearance = .light
        try tour.deviceKey()
        try tour.empty()
        try tour.session()
        try tour.split()
        try tour.keyRow()
        try tour.hostMenu()
        try tour.sessionActions()
        try tour.palette()
        try tour.themes()
        try tour.renameWindow()
        try tour.previewPort()
        try tour.inbox()
        try tour.pathPickers()
        try tour.peek()
        if tour.pad { try tour.sidebar() }
    }
}

/// The tour's scenes, in the order they are photographed, and the steps they share.
@MainActor
private final class Tour {
    let test: XCTestCase
    let app = XCUIApplication()
    let shell: String
    let job: String
    let done: String
    /// The last word of the three sessions' names, which finds all of them in the palette and the inbox.
    let word: String
    /// An iPad, held sideways, which has the sidebar; else an iPhone, held upright.
    let pad: Bool
    private let probe: XCUIElement

    /// Launch arguments read like saved choices, so each launch starts from Mies and each host's usual look,
    /// whatever the device keeps, on the Mac, with the probe on for the keys typeCommand checks.
    private static let usual = [
        "-host", "mac", "-probe", "YES",
        "-themeLight", "mies", "-themeDark", "mies", "-appearance", "match",
        "-hostTheme.mac.light", "lhun", "-hostTheme.mac.dark", "lhun",
        "-hostTheme.server.light", "tinted", "-hostTheme.server.dark", "tinted",
    ]

    init(_ test: XCTestCase) throws {
        let prefix = try XCTUnwrap(ProcessInfo.processInfo.environment["TASTE_PREFIX"], "run this test through tools/taste.sh")
        shell = "\(prefix)-shell"
        job = "\(prefix)-job"
        done = "\(prefix)-done"
        word = prefix.split(separator: "-").last.map(String.init) ?? prefix
        pad = UIDevice.current.userInterfaceIdiom == .pad
        self.test = test
        probe = app.descendants(matching: .any)["probe"].firstMatch
    }

    // MARK: Scenes

    /// The pairing sheet over the empty screen, as Lhûn's first launch shows it; -keySeen NO shows it again.
    /// Closing it saves the key as seen, as it already was.
    func deviceKey() throws {
        launch(["-keySeen", "NO", "-selection", "", "-workspaces", "", "-panes", "", "-layout", "tabs"])
        let close = app.buttons["Close"].firstMatch
        try photograph("01-device-key") {
            XCTAssertTrue(close.waitForExistence(timeout: 30), "a launch with -keySeen NO showed no device key")
            return close
        }
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 10), "Close left the device key up")
        XCTAssertTrue(probe.waitForExistence(timeout: 15), "the probe never started")
    }

    /// The empty screen with the three sessions in the strip, the job working and the done one finished.
    func empty() throws {
        _ = test.onStrip(app, done)
        try waitUntil(30, "\(job) never read as working") { mark(job).hasPrefix("working") }
        try waitUntil(30, "\(done) never read as finished") { mark(done).hasPrefix("finished") }
        let hint = app.staticTexts["Pick a session above, or press ⌘K."]
        try photograph("02-empty") {
            XCTAssertTrue(hint.waitForExistence(timeout: 10), "the empty screen showed no hint")
            return hint
        }
    }

    /// The shell open on its card.
    func session() throws {
        test.onStrip(app, shell).tap()
        attached()
        let terminal = app.textViews["terminal"].firstMatch
        try photograph("03-session") {
            keyboardDown()
            return terminal
        }
    }

    /// The job's pill dropped on the shell's card: two cards side by side, or on an iPhone one above the
    /// other. Closing the job's card afterwards leaves the shell alone again.
    func split() throws {
        // The keyboard goes down, so the card shows whole under the pill (LhunSplit). An iPhone's keyboard stays,
        // so there the pill goes to the lower part of the card above it.
        keyboardDown()
        let frame = element("card.mac.\(shell)").frame
        let keyboard = app.keyboards.firstMatch
        let bottom = keyboard.exists ? min(frame.maxY, keyboard.frame.minY) : frame.maxY
        let window = app.windows.firstMatch
        let sideways = window.frame.width > window.frame.height
        // A share of the window, as LhunSplit drops: on an iPad held sideways a share of the card, or an offset
        // from the app's corner, lands near the card's top and stacks the cards.
        let target = window.coordinate(
            withNormalizedOffset: sideways
                ? CGVector(dx: 0.75, dy: 0.55)
                : CGVector(dx: 0.5, dy: (frame.minY + (bottom - frame.minY) * 0.85) / window.frame.height)
        )
        // Sideways the job opens to the right of the shell, as the pictures before the taste work show; upright
        // either half makes the split.
        let card = element("card.mac.\(job)")
        func placed() -> Bool {
            !sideways || card.frame.minX >= element("card.mac.\(shell)").frame.maxX
        }
        // A press of half a second lifts the pill; a longer one would open its menu. On an iPhone simulator about
        // one drag in two never lifts it, so the drag is made again, and a card opened in the wrong half is
        // closed first.
        for _ in 0..<3 where !(card.exists && placed()) {
            if card.exists {
                card.buttons["card.close"].firstMatch.tap()
                _ = card.waitForNonExistence(timeout: 10)
            }
            test.onStrip(app, job).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
                forDuration: 0.5, thenDragTo: target, withVelocity: .default, thenHoldForDuration: 1
            )
            _ = card.waitForExistence(timeout: 10)
        }
        XCTAssertTrue(card.exists, "\(job) dropped on the card three times opened no second card")
        XCTAssertTrue(element("card.mac.\(shell)").exists, "\(job) dropped on the card took the shell's place")
        XCTAssertTrue(placed(), "\(job) opened somewhere other than right of the shell in all three drags")
        attached()
        try photograph("04-split") {
            keyboardDown()
            return card
        }
        // The dropped session has the focus, so only its card's header shows Close.
        card.buttons["card.close"].firstMatch.tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 10), "Close left \(job)'s card")
    }

    /// The key row Lhûn shows over the on-screen keyboard. Beside a hardware keyboard, and on a simulator,
    /// there is none, and the tour goes on without it.
    func keyRow() throws {
        let terminal = app.textViews["terminal"].firstMatch
        let dictate = app.buttons["key.dictate"].firstMatch
        terminal.tap()
        guard dictate.waitForExistence(timeout: 5) else {
            XCTContext.runActivity(named: "no key row to photograph: a hardware keyboard, or a simulator") { _ in }
            keyboardDown()
            return
        }
        try photograph("05-key-row") {
            if !dictate.exists { terminal.tap() }
            XCTAssertTrue(dictate.waitForExistence(timeout: 5), "the key row went away")
            return dictate
        }
        keyboardDown()
    }

    /// The host chip's menu, which switches between the Mac and the server.
    func hostMenu() throws {
        try photograph("06-host-menu") {
            if let item = shown("Server") { return item }
            keyboardDown()
            element("host").tap()
            return try XCTUnwrap(showing("Server"), "the host chip showed no menu")
        }
        dismissMenu(showing: "Server")
    }

    /// The shell's menu from a long press on its pill, then its Rename… and its Kill Session, each answered no.
    func sessionActions() throws {
        try photograph("07-session-menu") { try openSessionMenu() }
        let renaming = app.alerts["Rename Session"]
        try photograph("08-rename-session") {
            if !renaming.exists {
                try openSessionMenu().tap()
                XCTAssertTrue(renaming.waitForExistence(timeout: 5), "Rename… asked for no name")
            }
            return renaming
        }
        cancel(renaming)
        let question = app.staticTexts["Kill \(shell)?"]
        try photograph("09-kill-session") {
            if !question.exists {
                try openSessionMenu()
                // The menu's own item, taken while the menu is up: the question has a Kill Session button too.
                try XCTUnwrap(shown("Kill Session"), "\(shell)'s menu has no Kill Session").tap()
                XCTAssertTrue(question.waitForExistence(timeout: 5), "Kill Session asked nothing")
            }
            return question
        }
        decline(question)
    }

    /// The palette as ⌘K opens it, then finding the sessions, offering to make one and listing its settings,
    /// then the fonts its Font… lists. Nothing goes into it after the query, so Return never makes the
    /// session it offers.
    func palette() throws {
        let field = app.textFields["palette.query"]
        let card = element("palette.query.card")
        let states: [(name: String, query: String, row: String?)] = [
            ("10-palette", "", nil),
            ("11-palette-sessions", word, "open.mac.\(job)"),
            ("12-palette-new-session", "zephyr", "create"),
            ("13-palette-settings", "settings", "sounds"),
        ]
        for state in states {
            try photograph(state.name) {
                if !field.exists {
                    try openPalette()
                    if !state.query.isEmpty { field.typeText(state.query) }
                }
                if let row = state.row {
                    XCTAssertTrue(
                        app.buttons["palette.\(row)"].waitForExistence(timeout: 10),
                        "the palette offered no \(row) for \(state.query.debugDescription)"
                    )
                }
                keyboardDown()
                return card
            }
            try closePalette()
        }
        let fonts = app.textFields.matching(
            NSPredicate(format: "identifier == %@ AND placeholderValue == %@", "palette.query", "Choose a font")
        ).firstMatch
        try photograph("14-fonts") {
            if !fonts.exists {
                if field.exists { try closePalette() }
                try openPalette()
                field.typeText("font")
                let row = app.buttons["palette.font"]
                XCTAssertTrue(row.waitForExistence(timeout: 10), "the palette offered no Font…")
                row.tap()
                XCTAssertTrue(fonts.waitForExistence(timeout: 5), "Font… listed no fonts")
            }
            keyboardDown()
            return card
        }
        try closePalette()
    }

    /// The theme picker for the appearance on screen. A change of look closes it, so the dark picture opens it
    /// again. The palette opening over it closes it without a choice, putting back what its highlight tried.
    func themes() throws {
        let field = app.textFields["themes.query"]
        try photograph("15-themes") {
            if !field.exists {
                try run("theme", typing: "theme")
                XCTAssertTrue(field.waitForExistence(timeout: 10), "Theme… opened no theme picker")
            }
            keyboardDown()
            return element("themes.query.card")
        }
        try openPalette()
        XCTAssertTrue(field.waitForNonExistence(timeout: 10), "the palette left the theme picker open")
        try closePalette()
    }

    /// Renaming the shell's active window, answered Cancel.
    func renameWindow() throws {
        let alert = app.alerts["Rename Window"]
        try photograph("16-rename-window") {
            if !alert.exists {
                try run("rename-window", typing: "rename window")
                XCTAssertTrue(alert.waitForExistence(timeout: 5), "Rename Window… asked for no name")
            }
            return alert
        }
        cancel(alert)
    }

    /// The port to preview, answered Cancel.
    func previewPort() throws {
        let alert = app.alerts["Preview Port"]
        try photograph("17-preview-port") {
            if !alert.exists {
                try run("preview", typing: "preview port")
                XCTAssertTrue(alert.waitForExistence(timeout: 5), "Preview Port… asked for no port")
            }
            return alert
        }
        cancel(alert)
    }

    /// The inbox as ⇧⌘I opens it, its screens read, then the done session found by name with the summary its
    /// Catch Up writes on the device.
    func inbox() throws {
        let field = app.textFields["inbox.query"]
        let card = element("inbox.query.card")
        let reading = app.staticTexts["Reading its screen…"]
        try photograph("18-inbox") {
            try openInbox()
            try waitUntil(15, "the inbox never finished reading the screens") { !reading.exists }
            keyboardDown()
            return card
        }
        let summary = element("inbox.summary.mac.\(done)")
        try photograph("19-catch-up") {
            if !summary.exists {
                try openInbox()
                field.tap()
                field.typeText(word)
                let catchUp = element("inbox.catchup.mac.\(done)")
                XCTAssertTrue(catchUp.waitForExistence(timeout: 10), "the inbox found no \(done) for \(word)")
                catchUp.tap()
                XCTAssertTrue(summary.waitForExistence(timeout: 5), "Catch Up showed nothing for \(done)")
            }
            try waitUntil(120, "the summary of \(done) never came; it reads \(summary.label.debugDescription)") {
                !["Reading its last 200 lines…", "Writing a summary…"].contains(summary.label)
            }
            keyboardDown()
            return card
        }
        XCTContext.runActivity(named: "summary of \(done): \(summary.label)") { _ in }
        try test.typeCommand("i", [.command, .shift], in: app, probe: probe)
        XCTAssertTrue(field.waitForNonExistence(timeout: 10), "⇧⌘I left the inbox open")
    }

    /// The three path pickers over the shell's folder: Insert Path, Go to Folder and Get File, each opened by
    /// its keys over the one before, which gives way to it.
    func pathPickers() throws {
        let card = element("paths.query.card")
        let pickers: [(name: String, key: String, flags: XCUIElement.KeyModifierFlags, prompt: String, row: String)] = [
            ("20-insert-path", "p", .command, "Find a file or folder", "notes.md"),
            ("21-go-to-folder", "g", [.command, .shift], "Filter folders, / to step in", "src/"),
            ("22-get-file", "o", [.command, .shift], "Find a file to get", "notes.md"),
        ]
        for picker in pickers {
            let field = app.textFields.matching(
                NSPredicate(format: "identifier == %@ AND placeholderValue == %@", "paths.query", picker.prompt)
            ).firstMatch
            try photograph(picker.name) {
                if !field.exists {
                    try test.typeCommand(picker.key, picker.flags, in: app, probe: probe)
                    XCTAssertTrue(field.waitForExistence(timeout: 10), "no picker asked \(picker.prompt.debugDescription)")
                }
                XCTAssertTrue(element("paths.\(picker.row)").waitForExistence(timeout: 10), "\(picker.name) never listed \(picker.row)")
                keyboardDown()
                return card
            }
        }
        try openPalette()
        XCTAssertTrue(card.waitForNonExistence(timeout: 10), "the palette left the path picker open")
        try closePalette()
    }

    /// The pictures of the sessions a pull down from the strip shows: a row of them after a short pull, the
    /// grid after a long one. ⇧⌘\ puts the grid away.
    func peek() throws {
        let row = element("peek.row")
        let grid = element("peek.grid")
        try photograph("23-peek-row") {
            if !row.exists {
                keyboardDown()
                pullStrip(170)
                XCTAssertTrue(row.waitForExistence(timeout: 5), "a short pull from the strip showed no pictures")
            }
            // The pictures have come in.
            sleep(3)
            return row
        }
        try photograph("24-peek-grid") {
            if !grid.exists {
                pullStrip(320)
                XCTAssertTrue(grid.waitForExistence(timeout: 5), "a long pull from the strip showed no grid")
            }
            sleep(3)
            return grid
        }
        try test.typeCommand("\\", [.command, .shift], in: app, probe: probe)
        XCTAssertTrue(grid.waitForNonExistence(timeout: 10), "⇧⌘\\ left the grid up")
    }

    /// The sidebar layout, an iPad's held sideways, with the shell open.
    func sidebar() throws {
        launch(["-keySeen", "YES", "-selection", "mac\t\(shell)", "-workspaces", "", "-panes", "", "-layout", "sidebar", "-sidebar", "YES", "-sidebarFolded", "()"])
        let sidebar = element("sidebar")
        XCTAssertTrue(sidebar.waitForExistence(timeout: 30), "the sidebar layout held sideways showed no sidebar")
        attached()
        try photograph("25-sidebar") {
            keyboardDown()
            return sidebar
        }
    }

    // MARK: Steps

    /// Launches Lhûn with the usual arguments and `arguments`. The probe is looked for once nothing covers it.
    func launch(_ arguments: [String]) {
        app.launchArguments = Self.usual + arguments
        app.launch()
    }

    func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// A pill's mark, as VoiceOver reads it: "working", "finished", "needs you", or none.
    func mark(_ session: String) -> String {
        let pill = element("session.mac.\(session)")
        return pill.exists ? pill.value as? String ?? "" : ""
    }

    /// Waits for the open session's terminal, and for its session to be attached.
    func attached() {
        XCTAssertTrue(app.textViews["terminal"].firstMatch.waitForExistence(timeout: 10), "no terminal opened")
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "the session never attached")
    }

    /// Opens the palette with ⌘K, once the keyboard swap the key sets off on a simulator is over, so what is
    /// typed next all lands.
    func openPalette() throws {
        try test.typeSettled("k", .command, in: app, probe: probe)
        XCTAssertTrue(app.textFields["palette.query"].waitForExistence(timeout: 10), "⌘K opened no palette")
    }

    func closePalette() throws {
        try test.typeCommand("k", .command, in: app, probe: probe)
        XCTAssertTrue(app.textFields["palette.query"].waitForNonExistence(timeout: 10), "⌘K left the palette open")
    }

    /// Runs the palette's `row`, found by typing `query`.
    func run(_ row: String, typing query: String) throws {
        let field = app.textFields["palette.query"]
        try openPalette()
        field.typeText(query)
        let button = app.buttons["palette.\(row)"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the palette offered no \(row) for \(query.debugDescription)")
        // Only the rows in sight are drawn, and the on-screen keyboard can cover the lowest (LhunProbe).
        for _ in 0..<8 where !button.isHittable { element("palette.query.card").swipeUp(velocity: .slow) }
        button.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 10), "\(row) left the palette open")
    }

    func openInbox() throws {
        let field = app.textFields["inbox.query"]
        guard !field.exists else { return }
        try test.typeSettled("i", [.command, .shift], in: app, probe: probe)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "⇧⌘I opened no inbox")
    }

    /// The shell's menu, from a long press on its pill unless it shows already; returns its Rename….
    @discardableResult
    func openSessionMenu() throws -> XCUIElement {
        if let rename = shown("Rename…") { return rename }
        keyboardDown()
        test.onStrip(app, shell).press(forDuration: 1)
        return try XCTUnwrap(showing("Rename…"), "a long press on \(shell)'s pill showed no menu")
    }

    /// The item labeled `label` in the menu on screen, or nil while there is none. A menu's items are not
    /// always buttons, and the app's own menus, out of sight, hold some of the same names (LhunHistory).
    func shown(_ label: String) -> XCUIElement? {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label))
            .allElementsBoundByIndex.first { $0.isHittable }
    }

    /// The item labeled `label` in the menu on screen, once one shows within five seconds.
    func showing(_ label: String) -> XCUIElement? {
        var item: XCUIElement?
        _ = within(5) {
            item = shown(label)
            return item != nil
        }
        return item
    }

    /// Closes the menu on screen with a tap below it, and waits until its `item` has gone. The tap lands above
    /// where an iPhone's keyboard starts, which would take it without closing the menu.
    func dismissMenu(showing item: String) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        XCTAssertTrue(within(5) { shown(item) == nil }, "a tap away left the menu with \(item) up")
    }

    /// Answers `alert` Cancel once its button holds still: XCUITest types through a hardware keyboard it plugs
    /// in, so the on-screen keyboard leaves and comes back, and the alert moves with it (LhunChecks).
    func cancel(_ alert: XCUIElement) {
        let button = alert.buttons["Cancel"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "\(alert.label) has no Cancel")
        still(button)
        button.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 10), "Cancel left \(alert.label) up")
    }

    /// Answers the question to kill the shell no: its Cancel where it has one, else a tap on the far side of
    /// the screen from it, above an iPhone's keyboard, which a popover takes as no. A tap in the middle of the
    /// screen could land on Kill Session, and one on the keyboard would only type.
    func decline(_ question: XCUIElement) {
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists, cancel.isHittable {
            still(cancel)
            cancel.tap()
        } else {
            let window = app.windows.firstMatch.frame
            let keyboard = app.keyboards.firstMatch
            let floor = keyboard.exists ? min(window.maxY, keyboard.frame.minY) : window.maxY
            let y = question.frame.midY > (window.minY + floor) / 2 ? window.minY + window.height * 0.2 : floor - 40
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: window.midX, dy: y)).tap()
        }
        XCTAssertTrue(question.waitForNonExistence(timeout: 10), "the question to kill \(shell) stayed up")
    }

    /// Puts the on-screen keyboard down if it is up, or comes up within three seconds, so a picture shows the
    /// whole scene. Lhûn's key row has a Hide Keyboard button over a terminal; over a field, or beside a
    /// hardware keyboard as on a simulator, the keyboard's own key hides it, and a keyboard put down stays in
    /// the hierarchy below the screen, so only a key that can be tapped shows it is up. An iPhone's keyboard
    /// has no such key and stays.
    func keyboardDown() {
        let hide = app.buttons.matching(NSPredicate(format: "label ==[c] 'Hide keyboard'")).firstMatch
        let shows = { hide.exists && hide.isHittable }
        guard within(3, shows) else { return }
        hide.tap()
        XCTAssertTrue(within(10) { !shows() }, "the keyboard stayed up")
    }

    /// Pulls down by `distance` points from just left of the strip's glyphs, the inbox's when it shows, and
    /// lets go (LhunWalk).
    func pullStrip(_ distance: CGFloat) {
        let inbox = element("inbox")
        let palette = element("palette")
        let left = inbox.exists ? min(inbox.frame.minX, palette.frame.minX) : palette.frame.minX
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: left - 4, dy: palette.frame.midY))
        start.press(
            forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)),
            withVelocity: XCUIGestureVelocity(distance < 300 ? 300 : 600), thenHoldForDuration: 0.5
        )
    }

    /// Photographs a scene in light, then in dark, as `<name>-light.png` and `<name>-dark.png`. `pose` sets the
    /// scene each time and returns what shows it, which the picture waits on to hold still. A change of look
    /// closes some scenes, the theme picker always and a menu at times, so `pose` opens a scene that has gone
    /// and leaves one that shows as it is.
    func photograph(_ name: String, pose: () throws -> XCUIElement) throws {
        for (appearance, look) in [(XCUIDevice.Appearance.light, "light"), (.dark, "dark")] {
            if XCUIDevice.shared.appearance != appearance {
                XCUIDevice.shared.appearance = appearance
                // The look has finished changing, and whatever it closed has gone.
                sleep(1)
            }
            let subject = try pose()
            still(subject)
            keep("\(name)-\(look)")
        }
    }

    /// Waits until `element` shows and has held still for a second and a half (LhunChecks).
    func still(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "the scene never showed")
        var frame = element.frame
        var since = Date.now
        let deadline = Date.now.addingTimeInterval(10)
        while Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            guard element.exists else {
                XCTFail("the scene went away before its picture")
                return
            }
            let now = element.frame
            if now != frame {
                frame = now
                since = Date.now
            } else if Date.now.timeIntervalSince(since) >= 1.5 {
                return
            }
        }
        XCTFail("the scene was still moving after 10 seconds")
    }

    /// Has tools/taste.sh photograph the screen as `name`.png, and holds still until it has: the test asks with
    /// an empty file, take-taste-<name>, in its runner's Documents, and the script answers with
    /// taken-taste-<name> (dest_photographer in tools/dest.zsh).
    func keep(_ name: String) {
        let documents = URL.documentsDirectory
        let taken = documents.appending(path: "taken-taste-\(name)").path(percentEncoded: false)
        XCTAssertTrue(
            FileManager.default.createFile(atPath: documents.appending(path: "take-taste-\(name)").path(percentEncoded: false), contents: nil),
            "could not ask for the picture \(name)"
        )
        XCTAssertTrue(within(30) { FileManager.default.fileExists(atPath: taken) }, "tools/taste.sh never photographed \(name)")
    }

    /// Whether `condition` holds within `seconds`.
    func within(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date.now.addingTimeInterval(seconds)
        while !condition() {
            guard Date.now < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return true
    }

    func waitUntil(_ timeout: TimeInterval, _ failure: @autoclosure () -> String, _ done: () -> Bool) throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !done() {
            guard Date.now < deadline else { throw Timeout(errorDescription: failure()) }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }
}

private struct Timeout: LocalizedError {
    let errorDescription: String?
}
