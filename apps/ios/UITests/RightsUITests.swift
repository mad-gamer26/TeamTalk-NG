import XCTest

/// Someone who isn't an admin (Alice: an ordinary account, as the desktop's
/// slotUpdateUI treats it): their own account read-only, the server's
/// settings read-only, no admin-only items, Op with the channel's
/// operator password, a temporary channel's form.
final class RightsUITests: NGTestCase {
    func moreItems() -> [String] {
        app.buttons["More"].tap()
        Thread.sleep(forTimeInterval: 1)
        let items = app.buttons.allElementsBoundByIndex.map(\.label)
        closeMenu()
        return items
    }

    func testAnOrdinaryUsersServerItems() {
        connect()
        let items = moreItems()
        for absent in ["Bans", "Server statistics", "Save server configuration", "Broadcast message", "Move users"] {
            XCTAssertFalse(items.contains(absent), "\(absent) isn't offered without the right")
        }
        for present in ["User accounts", "Server settings", "Online users", "Create Channel"] {
            XCTAssertTrue(items.contains(present), "\(present) is offered (as the desktop)")
        }
        // My own account, read-only.
        more("User accounts")
        waitFor(app.navigationBars["Your account"], "my own account")
        XCTAssertTrue(any("alice").exists, "my username")
        XCTAssertTrue(any("Default user").exists, "my account's type")
        XCTAssertFalse(app.textFields.firstMatch.exists, "nothing to edit")
        button("Done").tap()
        // The server's settings, read-only.
        more("Server settings")
        waitFor(app.navigationBars["Server settings"], "the server's settings")
        waitFor(any("TTNG Test"), "its name")
        XCTAssertFalse(app.buttons["Save"].exists, "no Save without the right")
        XCTAssertFalse(app.textFields.firstMatch.exists, "nothing to edit")
        button("Done").tap()
    }

    func testOpAsksForTheOperatorPasswordAndChannelItemsAreOffered() {
        connect()
        let bob = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Bob'")).firstMatch
        waitFor(bob, "Bob in the tree")
        bob.press(forDuration: 1.2)
        waitFor(button("Make Channel Operator"), "Op offered")
        XCTAssertFalse(button("Kick From Server").exists, "no kick from the server without the right")
        XCTAssertTrue(button("Kick user").exists, "kick from the channel offered (as the desktop)")
        button("Make Channel Operator").tap()
        waitFor(app.secureTextFields["Operator password"], "the operator password asked for")
        button("Cancel").tap()

        let lobby = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Lobby'")).firstMatch
        lobby.press(forDuration: 1.2)
        waitFor(button("Edit properties"), "Edit properties offered (as the desktop)")
        XCTAssertTrue(button("Delete Channel").exists)
        XCTAssertTrue(button("Channel Bans").exists)
        XCTAssertFalse(button("Create Channel").exists, "inside another channel only with the right")
        closeMenu()
    }

    func testATemporaryChannelsForm() {
        connect()
        more("Create Channel")
        waitFor(app.textFields["Name"], "the form")
        // As the desktop without the right to modify channels.
        XCTAssertFalse(app.switches["Join it once it's made"].exists, "joined as it's made")
        XCTAssertFalse(app.switches["Keep it when everyone leaves"].exists)
        XCTAssertFalse(app.textFields["Most people allowed in (leave empty to keep it)"].exists)
        XCTAssertTrue(app.secureTextFields["Operator password (empty for none)"].exists, "its operator password, as the desktop")
        let goes = any("It goes away when the last person leaves.")
        for _ in 0..<8 where !goes.exists { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(goes.exists, "said: a temporary channel")
        button("Cancel").tap()
    }
}
