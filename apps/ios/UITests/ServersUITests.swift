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
        replace(app.textFields["TCP port"], with: Host.ttPort)
        replace(app.textFields["UDP port"], with: Host.ttPort)
        XCTAssertTrue(save.isEnabled)
        save.tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Typed'")).firstMatch
        waitFor(row, "the typed server in the list")

        // Edit: renamed.
        action("Edit", on: row)
        let n = app.textFields["Name"]
        waitFor(n, "the editor again")
        replace(n, with: "Renamed")
        button("Save").tap()
        let renamed = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Renamed'")).firstMatch
        waitFor(renamed, "the renamed server")

        // It connects with what was typed: no username, a guest (refused: the server has no guest account).
        renamed.tap()
        waitFor(any("Incorrect username or password"), "the server refusing a login without an account")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Delete: asked first; Cancel keeps it.
        action("Delete", on: app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Renamed'")).firstMatch)
        waitFor(any("Delete Renamed?"), "the confirmation", timeout: 5)
        cancelDialog()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Renamed'")).firstMatch.exists, "still there")
        action("Delete", on: app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Renamed'")).firstMatch)
        waitFor(any("Delete Renamed?"), "the confirmation", timeout: 5)
        app.buttons.matching(NSPredicate(format: "label == 'Delete'")).allElementsBoundByIndex.last!.tap()
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
        XCTAssertFalse(app.buttons["Record Conversations"].exists, "no shortcut buttons in the accessibility tree")
        XCTAssertFalse(app.staticTexts["Mute Everyone for Me"].exists)
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
    func testNothingListeningSaysItFailedAndKeepsTrying() {
        app.open(Host.link("alice", port: "9"))
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '127.0.0.1'")).firstMatch
        waitFor(row, "the server")
        row.tap()
        waitFor(any("Failed to connect to 127.0.0.1 TCP port 9 UDP port 9"), "the desktop's words for it", timeout: 30)
        // As the desktop: tried again every 5 seconds, until stopped.
        waitFor(any("Trying again (attempt 2)"), "a second try", timeout: 20)
        button("Stop trying").tap()
        waitFor(button("Connect"), "stopped, with Connect")
    }

    @MainActor
    func testAServerThatComesUpLaterIsConnectedByARetry() {
        Host.call("/server", ["do": "stop"])
        app.open(Host.link("alice"))
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '127.0.0.1'")).firstMatch
        waitFor(row, "the server")
        row.tap()
        waitFor(any("Trying again"), "trying again", timeout: 30)
        Host.call("/server", ["do": "start"])
        waitFor(any("Lobby"), "connected by a retry", timeout: 30)
        // Its setup happened too: in the root channel (Settings: join the root channel).
        Host.until("Bob seeing Alice in the root channel", timeout: 20) { (Host.user("alice")?["channel"] as? String) == "/" }
    }

    var onTheServerList: XCUIElement { app.navigationBars["Servers"] }
    var serverRow: XCUIElement { app.buttons.matching(NSPredicate(format: "label BEGINSWITH '127.0.0.1'")).firstMatch }

    /// Settings → Display → "Tell me in a dialog when I'm kicked", then back
    /// on the server's screen (set after connecting: a tt:// link starts afresh).
    func turnOnTheKickDialog() {
        app.navigationBars.buttons["Servers"].tap()
        app.buttons["Settings"].tap()
        app.buttons["Display"].tap()
        let sw = app.switches["Tell me in a dialog when I'm kicked"]
        if !sw.waitForExistence(timeout: 3) || !sw.isHittable { app.swipeUp() }
        waitFor(sw, "the kick dialog setting")
        sw.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        Host.until("it on") { (sw.value as? String) == "1" }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        button("Done").tap()
        serverRow.tap()
        waitFor(any("Lobby"), "back on the server's screen")
    }

    @MainActor
    func testDisconnectGoesBackToTheServerList() {
        connect()
        more("Disconnect")
        waitFor(onTheServerList, "the server list, as the desktop")
        Host.until("Bob seeing Alice go") { Host.user("alice") == nil }
        // Opening it again connects.
        serverRow.tap()
        waitFor(any("Lobby"), "connected again")
        Host.until("Bob seeing Alice back") { Host.user("alice") != nil }
    }

    @MainActor
    func testKickedFromTheServerGoesStraightToTheList() {
        // The dialog setting is off by default (as the desktop's).
        connect()
        Host.call("/kick", ["who": "alice"])
        waitFor(onTheServerList, "the server list at once")
        XCTAssertFalse(app.alerts.firstMatch.exists, "no dialog with the setting off")
    }

    @MainActor
    func testKickedAndBannedShowsTheDesktopsDialogThenTheList() {
        connect()
        turnOnTheKickDialog()
        Host.call("/kick", ["who": "alice", "ban": "1"])
        let alert = app.alerts["Kicked from server"]
        waitFor(alert, "the desktop's dialog")
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'You have been kicked from server by'")).firstMatch.exists)
        XCTAssertFalse(onTheServerList.exists, "still on the server's screen until it's dismissed")
        alert.buttons["OK"].tap()
        waitFor(onTheServerList, "the server list once dismissed")
    }

    @MainActor
    func testKickedFromAChannelShowsItsDialogAndStays() {
        connect()
        turnOnTheKickDialog()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Lobby'")).firstMatch.tap()
        Host.until("Alice in Lobby") { (Host.user("alice")?["channel"] as? String) == "/Lobby/" }
        Host.call("/kick", ["who": "alice", "channel": "1"])
        let alert = app.alerts["Kicked from channel"]
        waitFor(alert, "the channel's dialog")
        alert.buttons["OK"].tap()
        XCTAssertFalse(onTheServerList.exists, "still connected, on the server's screen")
        XCTAssertTrue(app.buttons["More"].exists)
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

