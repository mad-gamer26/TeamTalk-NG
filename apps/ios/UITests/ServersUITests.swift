import XCTest

/// Saved servers, connecting, and what goes wrong while connecting.
final class ServersUITests: NGTestCase {
    @MainActor
    func testTypedServerIsValidatedEditedAndDeleted() {
        app.buttons["Add server"].tap()
        button("Type its details").tap()
        let save = button("Save")
        waitFor(save, "the editor")
        XCTAssertFalse(save.isEnabled, "no address, no saving")
        let name = app.textFields["Name"]
        name.tap(); name.typeText("Typed")
        let address = app.textFields["Address"]
        address.tap(); address.typeText("127.0.0.1")
        let tcp = app.textFields["TCP port"]
        tcp.tap(); tcp.press(forDuration: 1); if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        tcp.typeText(Host.ttPort)
        let udp = app.textFields["UDP port"]
        udp.tap(); udp.press(forDuration: 1); if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        udp.typeText(Host.ttPort)
        XCTAssertTrue(save.isEnabled)
        save.tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Typed'")).firstMatch
        waitFor(row, "the typed server in the list")

        // Edit: renamed.
        action("Edit", on: row)
        let n = app.textFields["Name"]
        waitFor(n, "the editor again")
        n.tap(); n.press(forDuration: 1); if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        n.typeText("Renamed")
        button("Save").tap()
        let renamed = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Renamed'")).firstMatch
        waitFor(renamed, "the renamed server")

        // It connects with what was typed: no username, a guest (refused: the server has no guest account).
        renamed.tap()
        waitFor(any("Incorrect username or password"), "the server refusing a login without an account")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Delete.
        action("Delete", on: app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Renamed'")).firstMatch)
        Host.until("the server gone") { !app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Renamed'")).firstMatch.exists }
    }

    @MainActor
    func testLinkConnectsAndShowsChannelsAndPeople() {
        connect()
        waitFor(any("Bob"), "Bob in the tree")
        waitFor(any("Carol"), "Carol in the tree")
        XCTAssertTrue(any("Secret").exists, "the password channel is listed")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Hidden'")).firstMatch.exists, "the hidden channel isn't")
        // The keyboard shortcuts' buttons are for keys only: nothing VoiceOver can land on.
        XCTAssertFalse(app.buttons["Record Conversations to Disk"].exists, "no shortcut buttons in the accessibility tree")
        XCTAssertFalse(app.staticTexts["Mute All"].exists)
        // The others see Alice.
        Host.until("Bob seeing Alice") { Host.user("alice") != nil }
    }

    @MainActor
    func testWrongPasswordAsksAgainAndThenConnects() {
        app.open(Host.link("alice", password: "wrong"))
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '127.0.0.1'")).firstMatch
        waitFor(row, "the server")
        row.tap()
        let alert = app.alerts.firstMatch
        waitFor(alert, "the Login error dialog")
        XCTAssertTrue(alert.label.contains("Login") || alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Login'")).count > 0)
        let pw = alert.secureTextFields.firstMatch
        pw.tap()
        // It holds the wrong password: cleared first.
        pw.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12) + "alice-pw")
        alert.buttons["Login"].tap()
        waitFor(any("Lobby"), "connected after correcting the password")
        Host.until("Bob seeing Alice") { Host.user("alice") != nil }
    }

    @MainActor
    func testNothingListeningSaysItFailed() {
        app.open(Host.link("alice", port: "9"))
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '127.0.0.1'")).firstMatch
        waitFor(row, "the server")
        row.tap()
        waitFor(any("Failed to connect to 127.0.0.1 TCP port 9 UDP port 9"), "the desktop's words for it", timeout: 30)
        waitFor(button("Connect"), "a Connect button to try again")
    }

    @MainActor
    func testDisconnectAndConnectAgain() {
        connect()
        more("Disconnect")
        waitFor(button("Connect"), "disconnected, with Connect")
        Host.until("Bob seeing Alice go") { Host.user("alice") == nil }
        button("Connect").tap()
        waitFor(any("Lobby"), "connected again")
        Host.until("Bob seeing Alice back") { Host.user("alice") != nil }
    }

    @MainActor
    func testServerGoingDownAndComingBackReconnects() {
        connect()
        Host.call("/server", ["do": "stop"])
        waitFor(any("Connection lost"), "the lost connection said", timeout: 30)
        Host.call("/server", ["do": "start"])
        waitFor(any("Lobby"), "back, with the channels", timeout: 60)
        Host.until("Bob seeing Alice after the restart", timeout: 30) { Host.user("alice") != nil }
    }
}

