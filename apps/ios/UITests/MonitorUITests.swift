import XCTest

/// The Monitor: a server explored through it, as if connected.
final class MonitorUITests: NGTestCase {
    /// The run's own Monitor is shared: each test starts with it watching nothing.
    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { run("clearMonitor", says: "Monitor cleared") }
    }

    func testAMonitoredServerLooksConnectedWithoutAudio() {
        // A saved server (as admin), the app itself not connected to it.
        connect("admin")
        more("Disconnect")
        // Monitor isn't in Settings any more; it's in Server List Actions.
        app.buttons["Settings"].tap()
        XCTAssertFalse(app.buttons["Monitor"].waitForExistence(timeout: 2), "no Monitor in Settings")
        button("Done").tap()
        openMonitor()
        addToMonitor()
        Host.until("the Monitor logged in (Bob seeing a second admin)", timeout: 30) {
            ((Host.state()["users"] as? [[String: Any]]) ?? []).filter { $0["username"] as? String == "admin" }.count >= 2
        }
        let watched = visibleRow("it on the Monitor screen", timeout: 20)
        watched.tap()
        // As if connected: the channels and people.
        waitFor(any("Lobby"), "the channels, through the Monitor", timeout: 30)
        waitFor(any("Bob"), "Bob, through the Monitor")
        // A person's information: their client with its version (it showed
        // only the client's name through the Monitor).
        action("View User Information", on: app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Bob'")).firstMatch)
        let client = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Client'")).firstMatch
        waitFor(client, "Bob's information")
        let value = client.value as? String ?? ""
        XCTAssertTrue(value.contains("version ") && !value.hasSuffix("version "), "the client's version: \(value)")
        button("Done").tap()
        // No audio at all (a text-only client).
        XCTAssertFalse(app.buttons["talk"].exists, "no Mute/Unmute button")
        moreButton.tap()
        XCTAssertFalse(button("Mute Everyone for Me").exists, "no Mute everyone")
        XCTAssertFalse(button("Record conversations").exists, "no recording")
        closeMenu()
        // Admin through the Monitor: its accounts (Manage Server → Accounts).
        more("User accounts")
        waitFor(any("carol"), "the server's accounts, through the Monitor", timeout: 20)
        button("Done").tap()
        // Disconnect: as a live one, back to the Monitor screen; opening it again connects.
        more("Disconnect")
        waitFor(app.navigationBars["Monitor"], "back on the Monitor screen")
        watched.tap()
        waitFor(any("Lobby"), "back, through the Monitor", timeout: 30)
    }

    /// A SwiftUI switch: its knob, not the row's middle (the label).
    private func flip(_ s: XCUIElement, to value: String) {
        let inner = s.switches.firstMatch
        (inner.exists ? inner : s).tap()
        if s.value as? String != value {
            s.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        XCTAssertEqual(s.value as? String, value, "Monitoring switched")
    }

    /// A monitored server's settings: its "Monitor settings" action.
    private func openItsSettings() {
        action("Monitor settings", on: visibleRow("it on the Monitor screen", timeout: 20))
        waitFor(app.switches["Monitoring"], "its Monitor settings", timeout: 10)
    }

    func testItsNicknameStatusAndGenderAreSetInItsMonitorSettings() {
        connect("admin")
        more("Disconnect")
        openMonitor()
        addToMonitor()
        Host.until("the Monitor logged in", timeout: 30) {
            ((Host.state()["users"] as? [[String: Any]]) ?? []).filter { $0["username"] as? String == "admin" }.count >= 2
        }
        openItsSettings()
        let nick = app.textFields["Nickname"]
        waitFor(nick, "its nickname")
        replace(nick, with: "Watcher")
        replace(app.textFields["Status message"], with: "Watching")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Gender'")).firstMatch.tap()
        button("Female").tap()
        button("Save").tap()
        Host.until("Bob seeing the Monitor as Watcher, Watching, female", timeout: 30) {
            guard let u = Host.user("Watcher") else { return false }
            return u["status_message"] as? String == "Watching" && u["gender"] as? String == "Female"
        }
        // Read back as saved.
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        openItsSettings()
        waitFor(app.textFields["Nickname"], "its settings again")
        XCTAssertEqual(app.textFields["Nickname"].value as? String, "Watcher")
        XCTAssertEqual(app.textFields["Status message"].value as? String, "Watching")
        // Off and on again, keeping them.
        flip(app.switches["Monitoring"], to: "0")
        Host.until("the Monitor gone", timeout: 30) { Host.user("Watcher") == nil }
        flip(app.switches["Monitoring"], to: "1")
        Host.until("the Monitor back as Watcher, Watching", timeout: 30) {
            Host.user("Watcher")?["status_message"] as? String == "Watching"
        }
    }

    /// Adding a server asks for its settings first (nothing logs in until
    /// Monitor): the nickname is the server's own, else the Monitor's
    /// default, else General's; status and gender the default, else
    /// General's (a default gender of None is General's).
    func testAddingAServerAsksForItsSettingsFilledInInOrder() {
        // (Connecting starts the app afresh: General's set after.)
        connect("admin")
        more("Disconnect")
        // General: a nickname and status of its own.
        app.buttons["Settings"].tap()
        app.buttons["General"].tap()
        replace(app.textFields["Nickname"], with: "General Nick")
        replace(app.textFields["Status message"], with: "General status")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        button("Done").tap()
        Thread.sleep(forTimeInterval: 2)
        let admins = { ((Host.state()["users"] as? [[String: Any]]) ?? []).filter { $0["username"] as? String == "admin" }.count }
        let before = admins()
        openMonitor()
        // No defaults yet: General's.
        func addScreen() {
            button("Monitor a server").tap()
            waitFor(app.navigationBars["Monitor a server"], "the servers to choose from")
            visibleRow("the saved server").tap()
            waitFor(app.textFields["Nickname"], "its settings")
        }
        func cancelAdd() {
            app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
            button("Cancel").tap()
            waitFor(app.navigationBars["Monitor"], "back on the Monitor screen")
        }
        addScreen()
        XCTAssertEqual(app.textFields["Nickname"].value as? String, "General Nick")
        XCTAssertEqual(app.textFields["Status message"].value as? String, "General status")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(admins(), before, "nothing logged in yet")
        cancelAdd()
        // Monitor defaults: they win over General's; gender None is General's.
        button("Default settings").tap()
        replace(app.textFields["Nickname"], with: "Default Nick")
        replace(app.textFields["Status message"], with: "Default status")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        addScreen()
        XCTAssertEqual(app.textFields["Nickname"].value as? String, "Default Nick")
        XCTAssertEqual(app.textFields["Status message"].value as? String, "Default status")
        cancelAdd()
        // The server's own nickname wins over both.
        leaveMonitor()
        action("Edit", on: visibleRow("the server in the list"))
        replace(app.textFields["Nickname (optional)"], with: "Server Nick")
        button("Save").tap()
        openMonitor()
        addScreen()
        XCTAssertEqual(app.textFields["Nickname"].value as? String, "Server Nick")
        XCTAssertEqual(app.textFields["Status message"].value as? String, "Default status")
        // Changed here, then started: the Monitor logs in with that.
        replace(app.textFields["Nickname"], with: "Chosen Nick")
        app.textFields["Nickname"].typeText("\n")
        startMonitoring()
        Host.until("the Monitor logged in as Chosen Nick, Default status", timeout: 30) {
            Host.user("Chosen Nick")?["status_message"] as? String == "Default status"
        }
    }

    /// Monitor → Notifications: the Monitor's own settings, saved there.
    func testNotificationSettingsAreSavedOnTheMonitor() {
        openMonitor()
        button("Notifications").tap()
        let logins = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Logins'")).firstMatch
        waitFor(logins, "the notification settings", timeout: 20)
        logins.tap()
        button("Nobody").tap()
        Thread.sleep(forTimeInterval: 2)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        waitFor(app.navigationBars["Monitor"], "back on the Monitor screen")
        button("Notifications").tap()
        let again = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Logins'")).firstMatch
        waitFor(again, "the notification settings again", timeout: 20)
        XCTAssertTrue(again.label.contains("Nobody") || (again.value as? String) == "Nobody", "read back from the Monitor: \(again.label)")
        // Back to everyone, for the other tests.
        again.tap()
        button("Everyone").tap()
        Thread.sleep(forTimeInterval: 2)
    }

    /// Private messages that came while a monitored server's screen was
    /// open are said there, once: going back to the Monitor screen doesn't
    /// say them again.
    func testLeavingAServerScreenDoesntRepeatItsMessages() {
        connect("admin")
        more("Disconnect")
        openMonitor()
        addToMonitor(nickname: "Repeater")
        Host.until("the Monitor logged in as Repeater", timeout: 30) { Host.user("Repeater") != nil }
        let watched = visibleRow("it on the Monitor screen", timeout: 20)
        watched.tap()
        waitFor(any("Bob"), "the server, through the Monitor", timeout: 30)
        run("announced", says: "Announced")
        Host.call("/pm", ["bot": "bob", "to": "Repeater", "text": "First note"])
        Thread.sleep(forTimeInterval: 3)
        Host.call("/pm", ["bot": "bob", "to": "Repeater", "text": "Second note"])
        Thread.sleep(forTimeInterval: 4)
        // Both arrived on the server's screen (the conversation opened, as
        // the desktop's popup): closed.
        waitFor(any("Second note"), "the messages on the server's screen")
        if button("Done").exists { button("Done").tap() }
        run("announced", says: "Announced")
        // Back to the Monitor screen (the Back button, not the server
        // screen's own "Monitor" button), and a while there.
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        edge.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        waitFor(app.navigationBars["Monitor"], "the Monitor screen")
        Thread.sleep(forTimeInterval: 10)
        run("announced", says: "Announced")
        let said = app.staticTexts.matching(identifier: "uitest-action-result").firstMatch.label
        // Nothing said again on the list (what came before was cleared by
        // the ask on the server's screen).
        XCTAssertFalse(said.contains("First note") || said.contains("Second note"), "said again on the list: \(said)")
    }

    /// Writing to someone through the Monitor doesn't tell them "typing"
    /// (a live connection does: checked first, as Alice).
    func testTypingThroughTheMonitorIsNotSent() {
        // Live: Bob is told Alice is typing.
        connect("alice")
        Host.until("Bob seeing Alice") { Host.user("alice") != nil }
        action("Send private message", on: app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Bob'")).firstMatch)
        let live = app.textFields["Message Bob"]
        waitFor(live, "the conversation with Bob")
        live.tap(); live.typeText("Hello th")
        Host.until("Bob told Alice is typing", timeout: 15) {
            ((Host.state()["typing"] as? [String]) ?? []).contains { !$0.isEmpty }
        }
        button("Done").tap()
        more("Disconnect")
        Host.call("/reset")

        // Through the Monitor (as admin, "Quiet typer"): nothing.
        connect("admin")
        more("Disconnect")
        openMonitor()
        addToMonitor(nickname: "Quiet typer")
        Host.until("the Monitor logged in as Quiet typer", timeout: 30) { Host.user("Quiet typer") != nil }
        visibleRow("it on the Monitor screen", timeout: 20).tap()
        waitFor(any("Bob"), "the server, through the Monitor", timeout: 30)
        action("Send private message", on: app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Bob'")).firstMatch)
        let field = app.textFields["Message Bob"]
        waitFor(field, "the conversation with Bob")
        run("announced", says: "Announced")
        field.tap(); field.typeText("Hello there")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 11))
        field.typeText("Hi")
        Thread.sleep(forTimeInterval: 5)
        // Nothing said about typing (it was: "Couldn't say you're typing:
        // the Monitor can't do that", every time it started or stopped).
        run("announced", says: "Announced")
        let said = app.staticTexts.matching(identifier: "uitest-action-result").firstMatch.label
        XCTAssertFalse(said.lowercased().contains("typing"), "said: \(said)")
        let told = (Host.state()["typing"] as? [String]) ?? []
        XCTAssertFalse(told.contains("Quiet typer"), "Bob wasn't told the Monitor is typing: \(told)")
        XCTAssertFalse(any("Couldn't say you're typing").exists, "no typing error either")
    }

    /// The Monitor titles its notifications with the server's name in the
    /// list: renamed there, renamed on the Monitor too.
    func testRenamingAServerRenamesItOnTheMonitor() {
        connect("admin")
        more("Disconnect")
        openMonitor()
        addToMonitor()
        leaveMonitor()
        let row = visibleRow("the server in the list")
        action("Edit", on: row)
        let n = app.textFields["Name"]
        waitFor(n, "the editor")
        replace(n, with: "Home Base")
        button("Save").tap()
        waitFor(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Home Base'")).firstMatch, "renamed in the list")
        openMonitor()
        _ = visibleRow("the Monitor's name for it, renamed", prefix: "Home Base", timeout: 20)
    }

    /// Private messages the Monitor received while the app wasn't watching
    /// are there when the server is opened through it.
    func testPrivateMessagesKeptByTheMonitorShowWhenItsServerOpens() {
        // As admin (not alice: the Monitor stays logged in for the rest of
        // the run, and other tests talk to Alice), with a name of its own.
        connect("admin")
        more("Disconnect")
        openMonitor()
        addToMonitor(nickname: "Keeper")
        Host.until("the Monitor logged in as Keeper", timeout: 30) { Host.user("Keeper") != nil }
        leaveMonitor()
        Host.call("/pm", ["bot": "bob", "to": "Keeper", "text": "Kept for you"])
        Thread.sleep(forTimeInterval: 2)
        openMonitor()
        visibleRow("it on the Monitor screen", timeout: 20).tap()
        waitFor(any("Bob"), "Bob, through the Monitor", timeout: 30)
        action("Send private message", on: app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Bob'")).firstMatch)
        waitFor(any("Kept for you"), "Bob's message, kept by the Monitor", timeout: 20)
    }

    /// Connecting to a monitored server here doesn't log the monitor out:
    /// it stays (only this iPhone's notifications about it pause).
    func testConnectingHereKeepsTheMonitorLoggedIn() {
        connect("admin")
        more("Disconnect")
        let admins = { ((Host.state()["users"] as? [[String: Any]]) ?? []).filter { $0["username"] as? String == "admin" }.count }
        // The host's own admin, and monitors earlier tests left in this
        // run's Monitor service.
        Thread.sleep(forTimeInterval: 2)
        let before = admins()
        openMonitor()
        addToMonitor()
        leaveMonitor()
        Host.until("the Monitor logged in", timeout: 30) { admins() == before + 1 }
        visibleRow("the saved server").tap()
        waitFor(any("Lobby"), "connected here too")
        Host.until("the app and the Monitor both there", timeout: 15) { admins() == before + 2 }
        Thread.sleep(forTimeInterval: 5)
        XCTAssertEqual(admins(), before + 2, "the Monitor stayed logged in while the app is connected")
        more("Disconnect")
        Host.until("the Monitor still there after disconnecting", timeout: 15) { admins() == before + 1 }
    }

    /// A tapped Monitor notification opens its server through the Monitor:
    /// a channel message on the Chat tab.
    func testATappedMonitorNotificationOpensItsServer() {
        connect("admin")
        more("Disconnect")
        openMonitor()
        addToMonitor()
        leaveMonitor()
        run("tapMonitorNotification", ["event": "channel_message"], says: "Opened")
        waitFor(app.buttons["Chat"], "the server, through the Monitor", timeout: 30)
        XCTAssertTrue(app.buttons["Chat"].isSelected, "on the Chat tab")
        XCTAssertFalse(app.buttons["talk"].exists, "through the Monitor: no audio")
    }
}
