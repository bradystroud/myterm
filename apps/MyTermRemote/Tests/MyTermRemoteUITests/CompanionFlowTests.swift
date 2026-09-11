import XCTest

/// Drives the companion app against a live host, end to end, the way a person would.
///
/// The host is whatever `MYTERM_REMOTE_HOST`, `MYTERM_REMOTE_PORT` and `MYTERM_REMOTE_TOKEN` name.
/// `RemoteHostDemo` in the package's tests serves one, and `script/ui_test.sh` wires the two
/// together. Screenshots go to `MYTERM_SHOTS_DIR` when it is set, so a run leaves evidence behind.
final class CompanionFlowTests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment

    private var host: String { environment["MYTERM_REMOTE_HOST"] ?? "localhost" }
    private var port: String { environment["MYTERM_REMOTE_PORT"] ?? "" }
    private var token: String { environment["MYTERM_REMOTE_TOKEN"] ?? "demotoken" }
    private var shotsDirectory: String? { environment["MYTERM_SHOTS_DIR"] }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var devicePrefix: String { isPad ? "ipad" : "iphone" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(port.isEmpty, "Set MYTERM_REMOTE_PORT to the port a MyTerm host is listening on.")
    }

    // MARK: - Pairing and the Macs list

    @MainActor
    func testFirstRunShowsAnEmptyMacsList() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["No Macs Yet"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Add a Mac…"].exists)
        snap(app, "10-first-run")
    }

    @MainActor
    func testAddingAMacByHandConnectsAndRemembersIt() {
        let app = launch()
        app.buttons["Add a Mac…"].tap()
        XCTAssertTrue(app.navigationBars["Add a Mac"].waitForExistence(timeout: 5))

        replaceText(in: app.textFields["Host"], with: host)
        // The port is filled in with the default, and the host under test may be on another one.
        replaceText(in: app.textFields["Port"], with: port)
        replaceText(in: app.textFields["Pairing Token"], with: token)
        snap(app, "11-add-mac-form")

        app.buttons["Save and Connect"].tap()
        expectConnected(app)
        snap(app, "12-workspaces")

        disconnect(app)
        // The Mac names itself once it answers, so the row is no longer an address.
        XCTAssertTrue(app.staticTexts["DemoMac"].waitForExistence(timeout: 5))
        snap(app, "13-macs-after-connect")
    }

    @MainActor
    func testAWrongTokenIsReportedInPlainWords() {
        let app = launch(connectingWithToken: "not-the-token")
        let message = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'token'")
        ).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 15), "the failure should mention the token")
        snap(app, "14-wrong-token")
    }

    // MARK: - Tabs

    @MainActor
    func testATerminalTabShowsTheMacsSessionAndTakesInput() throws {
        let app = launch(connecting: true)
        expectConnected(app)
        app.staticTexts["build"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["build"].waitForExistence(timeout: 5))
        snap(app, "20-terminal")

        // Typing lands in the Mac's shell. The shell writes a marker file that this test, which
        // shares the Mac's filesystem, can see. There is no other honest way to read a terminal.
        let marker = try XCTUnwrap(shotsDirectory) + "/typed-\(devicePrefix)-\(UUID().uuidString).marker"
        tapTerminal(in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "tapping the terminal should raise the keyboard")
        snap(app, "21-terminal-keyboard")
        app.typeText("touch \(marker)\n")
        XCTAssertTrue(
            waitForFile(at: marker, timeout: 10),
            "the shell on the Mac should have run what the device typed"
        )
    }

    @MainActor
    func testABrowserTabOffersSafari() {
        let app = launch(connecting: true)
        expectConnected(app)
        app.staticTexts["Preview"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Open in Safari"].waitForExistence(timeout: 5))
        snap(app, "22-browser-tab")
    }

    @MainActor
    func testClosingATabAsksFirst() {
        let app = launch(connecting: true)
        expectConnected(app)
        app.staticTexts["deploy"].firstMatch.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Close Tab"].waitForExistence(timeout: 5))
        snap(app, "23-tab-menu")
        app.buttons["Close Tab"].tap()
        XCTAssertTrue(app.staticTexts["Close “deploy”?"].waitForExistence(timeout: 5))
        snap(app, "24-close-confirmation")
        // A sheet offers Cancel. A popover, which is what an iPad and a large phone show, is
        // dismissed by tapping anywhere else.
        if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap()
        }
        XCTAssertTrue(waitForDisappearance(of: app.buttons["Close Tab"], timeout: 5), "the prompt should go away")
        XCTAssertTrue(app.staticTexts["deploy"].firstMatch.waitForExistence(timeout: 5), "nothing was closed")
    }

    @MainActor
    func testARefusedChangeIsShown() {
        // The demo host refuses every rename. The device must say so rather than stay silent.
        let app = launch(connecting: true)
        expectConnected(app)
        app.staticTexts["deploy"].firstMatch.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Rename…"].waitForExistence(timeout: 5))
        app.buttons["Rename…"].tap()
        XCTAssertTrue(app.alerts["Rename Tab"].waitForExistence(timeout: 5))
        app.alerts["Rename Tab"].textFields.firstMatch.typeText("x")
        app.alerts["Rename Tab"].buttons["Rename"].tap()
        let refusal = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'rename'")
        ).firstMatch
        XCTAssertTrue(refusal.waitForExistence(timeout: 10), "the refusal should be visible")
        snap(app, "25-refused-change")
    }

    @MainActor
    func testDisconnectingReturnsToTheMacsList() {
        let app = launch(connecting: true)
        expectConnected(app)
        disconnect(app)
        XCTAssertTrue(app.navigationBars["Macs"].waitForExistence(timeout: 5))
        snap(app, "30-disconnected")
    }

    // MARK: - Away from home

    @MainActor
    func testAMacOffTheNetworkIsReachedThroughTheRelay() throws {
        let relay = environment["MYTERM_REMOTE_RELAY"] ?? ""
        let rendezvous = environment["MYTERM_REMOTE_RENDEZVOUS"] ?? ""
        try XCTSkipIf(relay.isEmpty || rendezvous.isEmpty, "the host was not registered with a relay")

        // The address is one nothing listens on, so the only way in is the relay.
        let app = launch(connecting: true, host: "127.0.0.1", port: "1", extra: [
            "-remote.relay", relay,
            "-remote.rendezvous", rendezvous,
        ])
        expectConnected(app)
        XCTAssertTrue(app.staticTexts["Through the relay"].waitForExistence(timeout: 5), "the device should say which route it took")
        snap(app, "50-through-the-relay")

        app.staticTexts["build"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["build"].waitForExistence(timeout: 5))
        let marker = try XCTUnwrap(shotsDirectory) + "/relayed-\(devicePrefix)-\(UUID().uuidString).marker"
        tapTerminal(in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("touch \(marker)\n")
        XCTAssertTrue(waitForFile(at: marker, timeout: 15), "typing through the relay should reach the shell")
        snap(app, "51-terminal-through-the-relay")
    }

    // MARK: - Losing the Mac, and the Mac changing its mind

    @MainActor
    func testLosingTheMacKeepsTheScreenAndComesBackOnItsOwn() throws {
        let app = launch(connecting: true)
        expectConnected(app)
        app.staticTexts["build"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["build"].waitForExistence(timeout: 5))

        try tellHost("drop")
        let banner = app.otherElements["connection.lost"]
        XCTAssertTrue(banner.waitForExistence(timeout: 15), "losing the Mac should show the banner")
        XCTAssertTrue(app.navigationBars["build"].exists, "the terminal must stay where it was")
        snap(app, "40-connection-lost")

        // The host is back within a few seconds. The device notices without being asked.
        XCTAssertTrue(waitForDisappearance(of: banner, timeout: 40), "the device should reconnect on its own")
        XCTAssertTrue(app.navigationBars["build"].exists)
        snap(app, "41-reconnected")

        // And the terminal is live again: typing reaches the shell.
        let marker = try XCTUnwrap(shotsDirectory) + "/retyped-\(devicePrefix)-\(UUID().uuidString).marker"
        tapTerminal(in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("touch \(marker)\n")
        XCTAssertTrue(waitForFile(at: marker, timeout: 10), "the re-attached terminal should take input")
    }

    @MainActor
    func testTheMacTurningTypingOffReachesTheDeviceAtOnce() throws {
        let app = launch(connecting: true)
        expectConnected(app)
        app.staticTexts["build"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["build"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["terminal.viewOnly"].exists)

        try tellHost("readonly")
        defer { try? tellHost("writable") }
        XCTAssertTrue(app.staticTexts["terminal.viewOnly"].waitForExistence(timeout: 10), "the terminal should say it is view only")
        XCTAssertFalse(app.buttons["terminal.keyboard"].exists, "no keyboard button when typing is refused")
        snap(app, "42-view-only")

        try tellHost("writable")
        XCTAssertTrue(waitForDisappearance(of: app.staticTexts["terminal.viewOnly"], timeout: 10))
        XCTAssertTrue(app.buttons["terminal.keyboard"].waitForExistence(timeout: 5))
    }

    // MARK: - Helpers

    /// Hands the demo host a command through the file it watches. See `RemoteHostDemo`.
    private func tellHost(_ command: String) throws {
        let path = try XCTUnwrap(environment["MYTERM_REMOTE_CONTROL_FILE"], "the demo host's control file is not set")
        try command.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// The terminal is a UIKit view SwiftTerm owns, and it is not reliably exposed by identifier.
    /// Its screen is the whole window below the bar on both layouts, so the window's centre is it.
    @MainActor
    private func tapTerminal(in app: XCUIApplication) {
        let terminal = app.otherElements.matching(identifier: "terminal").firstMatch
        if terminal.exists {
            terminal.tap()
        } else {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).tap()
        }
    }

    @MainActor
    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: gone, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func launch(
        connecting: Bool = false,
        connectingWithToken: String? = nil,
        host: String? = nil,
        port: String? = nil,
        extra: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MYTERM_REMOTE_RESET_STATE"] = "1"
        if connecting || connectingWithToken != nil {
            app.launchArguments += [
                "-remote.host", host ?? self.host,
                "-remote.port", port ?? self.port,
                "-remote.token", connectingWithToken ?? token,
                "-remote.reconnectsOnLaunch", "YES",
            ] + extra
        }
        app.launch()
        return app
    }

    @MainActor
    private func expectConnected(_ app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Workspaces"].waitForExistence(timeout: 15), "the tree never arrived")
        XCTAssertTrue(app.staticTexts["build"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    private func disconnect(_ app: XCUIApplication) {
        app.buttons["Disconnect"].firstMatch.tap()
    }

    @MainActor
    private func snap(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let shotsDirectory else { return }
        let url = URL(fileURLWithPath: shotsDirectory).appendingPathComponent("\(name)-\(devicePrefix).png")
        try? screenshot.pngRepresentation.write(to: url)
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with text: String) {
        field.tap()
        if let current = field.value as? String, !current.isEmpty, current != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(text)
    }

    private func waitForFile(at path: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }
}

/// Answering an agent from the device, end to end against a live shell.
///
/// Skipped unless `MYTERM_REMOTE_DEMO_AGENT_SESSION` pointed the demo host at a transcript, because
/// without one no tab offers a conversation and there is nothing to answer.
final class AgentAnsweringTests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment
    private var host: String { environment["MYTERM_REMOTE_HOST"] ?? "localhost" }
    private var port: String { environment["MYTERM_REMOTE_PORT"] ?? "" }
    private var token: String { environment["MYTERM_REMOTE_TOKEN"] ?? "demotoken" }
    private var shotsDirectory: String? { environment["MYTERM_SHOTS_DIR"] }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(port.isEmpty, "Set MYTERM_REMOTE_PORT to the port a MyTerm host is listening on.")
        try XCTSkipIf(
            environment["MYTERM_REMOTE_AGENT_TAB"] == nil,
            "Set MYTERM_REMOTE_AGENT_TAB to a tab the host offers a conversation for."
        )
    }

    @MainActor
    func testTypingReachesTheShellAndItsMenuBecomesButtonsTheDeviceCanSafelyPress() throws {
        let app = XCUIApplication()
        app.launchEnvironment["MYTERM_REMOTE_RESET_STATE"] = "1"
        app.launchArguments += [
            "-remote.host", host,
            "-remote.port", port,
            "-remote.token", token,
            "-remote.reconnectsOnLaunch", "YES",
            "-remote.openTab", try XCTUnwrap(environment["MYTERM_REMOTE_AGENT_TAB"]),
        ]
        app.launch()

        let reply = app.textFields["agent.reply"]
        XCTAssertTrue(reply.waitForExistence(timeout: 25), "an agent tab should offer a reply field")

        // Typed on the phone, this becomes keystrokes in the Mac's shell. The shell then draws
        // something shaped exactly like a permission prompt, which is what the host reads back.
        reply.tap()
        reply.typeText("printf 'Do you want to proceed?\\n 1. Yes\\n 2. Yes, and do not ask again\\n 3. No\\n'")
        app.buttons["agent.send"].tap()

        XCTAssertTrue(
            app.otherElements["agent.prompt"].waitForExistence(timeout: 25),
            "a menu on the Mac's screen should become buttons on the device"
        )
        snap("60-permission-buttons")

        XCTAssertTrue(app.buttons["agent.option.1"].exists, "Yes should be offered")
        XCTAssertTrue(app.buttons["agent.option.3"].exists, "No should be offered")
        // The one that turns off every later prompt. A device is never offered it, whatever number
        // it happens to sit on.
        XCTAssertFalse(
            app.buttons["agent.option.2"].exists,
            "\"do not ask again\" must never reach a device"
        )
        XCTAssertTrue(app.buttons["agent.deny"].exists, "cancelling is always offered")
    }

    @MainActor
    private func snap(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let shotsDirectory else { return }
        let url = URL(fileURLWithPath: shotsDirectory).appendingPathComponent("\(name).png")
        try? screenshot.pngRepresentation.write(to: url)
    }
}

/// Switching the agent's model from the device.
///
/// Skipped unless the demo host was pointed at a transcript, as `AgentAnsweringTests` is. The
/// transcript it expects ends on the agent's rate-limit notice after a `/model` run, so the screen
/// has a note to render, a model to name, and a banner to offer.
final class AgentModelSwitchTests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment
    private var host: String { environment["MYTERM_REMOTE_HOST"] ?? "localhost" }
    private var port: String { environment["MYTERM_REMOTE_PORT"] ?? "" }
    private var token: String { environment["MYTERM_REMOTE_TOKEN"] ?? "demotoken" }
    private var shotsDirectory: String? { environment["MYTERM_SHOTS_DIR"] }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(port.isEmpty, "Set MYTERM_REMOTE_PORT to the port a MyTerm host is listening on.")
        try XCTSkipIf(
            environment["MYTERM_REMOTE_AGENT_TAB"] == nil,
            "Set MYTERM_REMOTE_AGENT_TAB to a tab the host offers a conversation for."
        )
    }

    @MainActor
    func testALimitNoticeOffersTheSameModelMenuTheToolbarHolds() throws {
        let app = XCUIApplication()
        app.launchEnvironment["MYTERM_REMOTE_RESET_STATE"] = "1"
        app.launchArguments += [
            "-remote.host", host,
            "-remote.port", port,
            "-remote.token", token,
            "-remote.reconnectsOnLaunch", "YES",
            "-remote.openTab", try XCTUnwrap(environment["MYTERM_REMOTE_AGENT_TAB"]),
        ]
        app.launch()

        XCTAssertTrue(app.textFields["agent.reply"].waitForExistence(timeout: 25), "an agent tab should offer a reply field")

        // The command the person ran is a note, not a bubble of markup.
        let note = app.descendants(matching: .any)["agent.localCommand"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10), "a slash command should be shown as a note")
        XCTAssertTrue(note.label.contains("Ran /model"), "the note names the command: \(note.label)")
        XCTAssertFalse(note.label.contains("<"), "no markup reaches the screen: \(note.label)")

        // The bar names the model that last answered, not the notice's placeholder.
        let model = app.buttons["agent.model"]
        XCTAssertTrue(model.waitForExistence(timeout: 5), "the toolbar should carry the model")
        XCTAssertTrue(model.label.contains("Fable 5.1"), "the model is the last one that answered: \(model.label)")

        XCTAssertTrue(app.otherElements["agent.limitNotice"].waitForExistence(timeout: 5), "the limit notice should be offered a way on")
        snap("70-limit-notice")

        app.buttons["agent.switchModel"].tap()
        let opus = app.buttons["Opus 5"]
        XCTAssertTrue(opus.waitForExistence(timeout: 5), "the banner opens the model list")
        XCTAssertTrue(app.buttons["Opus 5 (1M)"].exists, "the larger window is offered too")
        snap("71-model-menu")

        // Choosing types `/model opus` into the tab through the reply path, and the banner stays
        // until the transcript says the switch happened. This host's tab is a plain shell, so what
        // is checked here is that the choice was sent without a refusal.
        opus.tap()
        XCTAssertFalse(app.staticTexts["refusal.message"].waitForExistence(timeout: 3), "the command should be accepted")
        snap("72-model-chosen")
    }

    @MainActor
    private func snap(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let shotsDirectory else { return }
        let url = URL(fileURLWithPath: shotsDirectory).appendingPathComponent("\(name).png")
        try? screenshot.pngRepresentation.write(to: url)
    }
}
