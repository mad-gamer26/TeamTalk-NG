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
        // Fully disconnected, and not back.
        Thread.sleep(forTimeInterval: 3)
        XCTAssertNil(Host.user("alice"), "not logged in again")
        // The row says only what the server is: no state, no error.
        XCTAssertEqual(serverRow.label, "127.0.0.1:\(Host.ttPort)", "only host:port: \(serverRow.label)")
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


/// Settings → Backup and Restore: a .ttng backup of servers, passwords,
/// settings, sound packs and chat history; opened as from Files, its parts
/// chosen and restored (replacing what's there), the app restarting itself.
final class BackupUITests: NGTestCase {
    @MainActor
    func testABackupFileRestoresServersAndSoundPacks() {
        // A server, and a sound pack of my own.
        app.buttons["Add server"].tap()
        button("Type its details").tap()
        let name = app.textFields["Name"]
        waitFor(name, "the editor")
        name.tap(); name.typeText("Backed up")
        let address = app.textFields["Address"]
        address.tap(); address.typeText("127.0.0.1")
        button("Save").tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Backed up'")).firstMatch
        waitFor(row, "the server in the list")
        app.buttons["Settings"].tap()
        // A sound pack of my own.
        let sounds = app.buttons["Sounds"]
        if !sounds.waitForExistence(timeout: 3) { app.swipeUp() }
        sounds.tap()
        app.buttons["Sound packs"].tap()
        button("New sound pack").tap()
        let packName = app.alerts.firstMatch.textFields.firstMatch
        waitFor(packName, "the new pack's name")
        packName.tap(); packName.typeText("Backed pack")
        app.alerts.firstMatch.buttons["Make"].tap()
        waitFor(app.navigationBars["Backed pack"], "the pack's screen")
        app.navigationBars["Backed pack"].buttons.element(boundBy: 0).tap()
        app.navigationBars["Sound packs"].buttons.element(boundBy: 0).tap()
        app.navigationBars["Sounds"].buttons.element(boundBy: 0).tap()
        let screen = app.buttons["Backup and Restore"]
        if !screen.waitForExistence(timeout: 3) { app.swipeUp() }
        screen.tap()
        for part in ["Servers", "Server passwords", "Settings", "Sound packs", "Chat history"] {
            XCTAssertTrue(app.switches[part].exists, "the \(part) switch")
        }
        // Making one offers to save or send it.
        button("Make a backup").tap()
        let shared = app.otherElements["ActivityListView"].firstMatch
        XCTAssertTrue(shared.waitForExistence(timeout: 10), "the share sheet")
        let close = shared.buttons.matching(NSPredicate(format: "label == 'Close' OR label == 'Cancel'")).firstMatch
        if close.waitForExistence(timeout: 3) { close.tap() } else { shared.swipeDown() }
        if !shared.waitForNonExistence(timeout: 3) { shared.swipeDown() }
        XCTAssertTrue(shared.waitForNonExistence(timeout: 5), "the share sheet closed")
        let back = app.navigationBars["Backup and Restore"].buttons["Settings"]
        waitFor(back, "the way back to Settings")
        back.tap()
        let done = button("Done")
        waitFor(done, "Settings' Done")
        done.tap()
        run("makeBackup", [:], says: "Backup made")

        // Deleted, then the backup opened as from Files.
        action("Delete", on: row)
        waitFor(any("Delete Backed up?"), "the confirmation", timeout: 5)
        app.buttons.matching(NSPredicate(format: "label == 'Delete'")).allElementsBoundByIndex.last!.tap()
        Host.until("the server gone") { !row.exists }
        // The pack deleted too.
        app.buttons["Settings"].tap()
        if !sounds.waitForExistence(timeout: 3) { app.swipeUp() }
        sounds.tap()
        app.buttons["Sound packs"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Backed pack'")).firstMatch.tap()
        let delete = button("Delete sound pack")
        for _ in 0..<6 where !(delete.exists && delete.isHittable) { app.collectionViews.firstMatch.swipeUp() }
        delete.tap()
        app.buttons.matching(NSPredicate(format: "label == 'Delete'")).allElementsBoundByIndex.last!.tap()
        let pack = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Backed pack'")).firstMatch
        Host.until("the pack gone") { !pack.exists }
        app.navigationBars["Sound packs"].buttons.element(boundBy: 0).tap()
        app.navigationBars["Sounds"].buttons.element(boundBy: 0).tap()
        button("Done").tap()
        run("openBackup", [:], says: "Backup opened")
        waitFor(app.navigationBars["Restore a backup"], "the restore screen")
        waitFor(app.switches["Servers (1 server)"], "what it holds")
        XCTAssertTrue(app.switches["Settings"].exists)
        app.navigationBars.buttons["Restore"].tap()
        app.buttons.matching(NSPredicate(format: "label == 'Restore'")).allElementsBoundByIndex.last!.tap()
        waitFor(row, "the server back after the restore", timeout: 20)
        app.buttons["Settings"].tap()
        if !sounds.waitForExistence(timeout: 3) { app.swipeUp() }
        sounds.tap()
        app.buttons["Sound packs"].tap()
        waitFor(pack, "the sound pack back after the restore")
    }
}

/// The server list: searched, and reordered by Move up / Move down and by
/// dragging.
final class ServerListOrderUITests: NGTestCase {
    @MainActor
    func add(_ name: String) {
        app.buttons["Add server"].tap()
        button("Type its details").tap()
        let n = app.textFields["Name"]
        waitFor(n, "the editor")
        n.tap(); n.typeText(name)
        let a = app.textFields["Address"]
        a.tap(); a.typeText("127.0.0.1")
        button("Save").tap()
        waitFor(row(name), "\(name) in the list")
    }

    @MainActor
    func row(_ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name + ",")).firstMatch
    }

    /// The servers' names, top to bottom.
    @MainActor
    func order() -> [String] {
        ["Alpha", "Bravo", "Charlie"].sorted { row($0).frame.minY < row($1).frame.minY }
    }

    @MainActor
    func testSearchedAndReordered() {
        add("Alpha"); add("Bravo"); add("Charlie")
        XCTAssertEqual(order(), ["Alpha", "Bravo", "Charlie"])
        // A row says its name and host:port, nothing else.
        XCTAssertEqual(row("Alpha").label, "Alpha, 127.0.0.1:10333")

        // Move down / Move up (the menu's items, VoiceOver's actions too).
        action("Move down", on: row("Alpha"))
        Host.until("Alpha second") { self.order() == ["Bravo", "Alpha", "Charlie"] }
        action("Move up", on: row("Charlie"))
        Host.until("Charlie second") { self.order() == ["Bravo", "Charlie", "Alpha"] }
        // The first has no Move up.
        row("Bravo").press(forDuration: 1.2)
        waitFor(button("Move down"), "the menu")
        XCTAssertFalse(button("Move up").exists, "no Move up at the top")
        app.tap()

        // Dragged: Alpha onto Bravo's place, at the top.
        row("Alpha").press(forDuration: 0.6, thenDragTo: row("Bravo"), withVelocity: .slow, thenHoldForDuration: 0.8)
        Host.until("Alpha first after the drag") { self.order().first == "Alpha" }

        // Kept after a restart.
        let kept = order()
        app.terminate()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXS"]
        app.launch()
        waitFor(row("Alpha"), "the list again")
        XCTAssertEqual(order(), kept)

        // Searched: only the ones that match; no moving meanwhile.
        let field = app.searchFields["Search servers"]
        if !field.waitForExistence(timeout: 3) { app.swipeDown() }
        field.tap(); field.typeText("char")
        Host.until("only Charlie") { self.row("Charlie").exists && !self.row("Alpha").exists && !self.row("Bravo").exists }
        row("Charlie").press(forDuration: 1.2)
        waitFor(button("Edit"), "its menu")
        XCTAssertFalse(button("Move up").exists || button("Move down").exists, "no moving while searching")
        app.tap()
        field.buttons["Clear text"].tap()
        field.typeText("nothing like it")
        waitFor(any("No servers match"), "nothing found, said")
    }
}
