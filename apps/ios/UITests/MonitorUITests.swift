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
        monitorFromSettings()
        closeSettings(from: "Monitor")
        Host.until("the Monitor logged in (Bob seeing a second admin)", timeout: 30) {
            ((Host.state()["users"] as? [[String: Any]]) ?? []).filter { $0["username"] as? String == "admin" }.count >= 2
        }
        app.buttons["Monitor"].tap()
        let watched = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '127.0.0.1'")).firstMatch
        waitFor(watched, "it on the Monitor's list", timeout: 20)
        XCTAssertFalse(app.buttons["Add a server"].exists, "adding is in Settings now")
        watched.tap()
        // As if connected: the channels and people.
        waitFor(any("Lobby"), "the channels, through the Monitor", timeout: 30)
        waitFor(any("Bob"), "Bob, through the Monitor")
        // No audio at all (a text-only client).
        XCTAssertFalse(app.buttons["Talk"].exists, "no Talk button")
        app.buttons["More"].tap()
        XCTAssertFalse(button("Mute Everyone for Me").exists, "no Mute everyone")
        XCTAssertFalse(button("Record conversations").exists, "no recording")
        // Admin through the Monitor: its accounts.
        button("User accounts").tap()
        waitFor(any("carol"), "the server's accounts, through the Monitor", timeout: 20)
        button("Done").tap()
        // Disconnect: as a live one, back to the list; opening it again connects.
        more("Disconnect")
        waitFor(app.navigationBars["Monitor"], "back on the Monitor's list")
        watched.tap()
        waitFor(any("Lobby"), "back, through the Monitor", timeout: 30)
    }

    /// Settings → Monitor → Monitor a server, back to the servers list.
    private func monitorFromSettings() {
        app.buttons["Settings"].tap()
        let link = app.buttons["settings-monitor"]
        if !link.waitForExistence(timeout: 3) { app.swipeUp() }
        link.tap()
        XCTAssertTrue(app.buttons["Notification sound"].waitForExistence(timeout: 5) || app.staticTexts["Notification sound"].exists, "the notification sound")
        button("Monitor a server").tap()
        waitFor(app.navigationBars["Monitor a server"], "the servers to choose from")
        visibleServerRow("the saved server to monitor").tap()
        waitFor(app.navigationBars["Monitor"], "back in Settings → Monitor")
        _ = visibleServerRow("it in Settings → Monitor", timeout: 20)
    }

    /// The local server's row on the screen in front (the servers list
    /// stays underneath Settings with a row of the same name).
    private func visibleServerRow(_ what: String, timeout: TimeInterval = 15) -> XCUIElement {
        let rows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '127.0.0.1'"))
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            for i in 0..<rows.count where rows.element(boundBy: i).isHittable { return rows.element(boundBy: i) }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTFail("never: \(what)")
        return rows.firstMatch
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

    private func closeSettings(from screen: String) {
        app.navigationBars[screen].buttons.element(boundBy: 0).tap()
        let done = button("Done")
        if !done.waitForExistence(timeout: 3) { app.swipeDown() }
        done.tap()
    }

    func testItsNicknameStatusAndGenderAreSetInSettings() {
        connect("admin")
        more("Disconnect")
        monitorFromSettings()
        Host.until("the Monitor logged in", timeout: 30) {
            ((Host.state()["users"] as? [[String: Any]]) ?? []).filter { $0["username"] as? String == "admin" }.count >= 2
        }
        visibleServerRow("it in Settings → Monitor").tap()
        XCTAssertTrue(app.switches["Monitoring"].waitForExistence(timeout: 10), "the Monitoring switch")
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
        visibleServerRow("it in Settings → Monitor").tap()
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

    /// Private messages that came while a monitored server's screen was
    /// open are said there, once: going back to the Monitor's list doesn't
    /// say them again.
    func testLeavingAServerScreenDoesntRepeatItsMessages() {
        connect("admin")
        more("Disconnect")
        monitorFromSettings()
        visibleServerRow("it in Settings → Monitor").tap()
        let nick = app.textFields["Nickname"]
        waitFor(nick, "its nickname")
        replace(nick, with: "Repeater")
        button("Save").tap()
        Host.until("the Monitor logged in as Repeater", timeout: 30) { Host.user("Repeater") != nil }
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        closeSettings(from: "Monitor")
        app.buttons["Monitor"].tap()
        let watched = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '127.0.0.1'")).firstMatch
        waitFor(watched, "it on the Monitor's list", timeout: 20)
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
        // Back to the Monitor's list (the Back button, not the server
        // screen's own "Monitor" button), and a while there.
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        edge.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        waitFor(app.navigationBars["Monitor"], "the Monitor's list")
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
        action("Send Private Message", on: app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Bob'")).firstMatch)
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
        monitorFromSettings()
        visibleServerRow("it in Settings → Monitor").tap()
        let nick = app.textFields["Nickname"]
        waitFor(nick, "its nickname")
        replace(nick, with: "Quiet typer")
        button("Save").tap()
        Host.until("the Monitor logged in as Quiet typer", timeout: 30) { Host.user("Quiet typer") != nil }
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        closeSettings(from: "Monitor")
        app.buttons["Monitor"].tap()
        let watched = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '127.0.0.1'")).firstMatch
        waitFor(watched, "it on the Monitor's list", timeout: 20)
        watched.tap()
        waitFor(any("Bob"), "the server, through the Monitor", timeout: 30)
        action("Send Private Message", on: app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Bob'")).firstMatch)
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
        monitorFromSettings()
        closeSettings(from: "Monitor")
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '127.0.0.1'")).firstMatch
        waitFor(row, "the server in the list")
        action("Edit", on: row)
        let n = app.textFields["Name"]
        waitFor(n, "the editor")
        replace(n, with: "Home Base")
        button("Save").tap()
        waitFor(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Home Base'")).firstMatch, "renamed in the list")
        app.buttons["Settings"].tap()
        let link = app.buttons["settings-monitor"]
        if !link.waitForExistence(timeout: 3) { app.swipeUp() }
        link.tap()
        waitFor(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Home Base'")).firstMatch, "the Monitor's name for it, renamed", timeout: 20)
    }

    /// Private messages the Monitor received while the app wasn't watching
    /// are there when the server is opened through it.
    func testPrivateMessagesKeptByTheMonitorShowWhenItsServerOpens() {
        // As admin (not alice: the Monitor stays logged in for the rest of
        // the run, and other tests talk to Alice), with a name of its own.
        connect("admin")
        more("Disconnect")
        monitorFromSettings()
        visibleServerRow("it in Settings → Monitor").tap()
        let nick = app.textFields["Nickname"]
        waitFor(nick, "its nickname")
        replace(nick, with: "Keeper")
        button("Save").tap()
        Host.until("the Monitor logged in as Keeper", timeout: 30) { Host.user("Keeper") != nil }
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        closeSettings(from: "Monitor")
        Host.call("/pm", ["bot": "bob", "to": "Keeper", "text": "Kept for you"])
        Thread.sleep(forTimeInterval: 2)
        app.buttons["Monitor"].tap()
        let watched = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '127.0.0.1'")).firstMatch
        waitFor(watched, "it on the Monitor's list", timeout: 20)
        watched.tap()
        waitFor(any("Bob"), "Bob, through the Monitor", timeout: 30)
        action("Send Private Message", on: app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Bob'")).firstMatch)
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
        monitorFromSettings()
        closeSettings(from: "Monitor")
        Host.until("the Monitor logged in", timeout: 30) { admins() == before + 1 }
        visibleServerRow("the saved server").tap()
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
        monitorFromSettings()
        closeSettings(from: "Monitor")
        run("tapMonitorNotification", ["event": "channel_message"], says: "Opened")
        waitFor(app.buttons["Chat"], "the server, through the Monitor", timeout: 30)
        XCTAssertTrue(app.buttons["Chat"].isSelected, "on the Chat tab")
        XCTAssertFalse(app.buttons["Talk"].exists, "through the Monitor: no audio")
    }
}
