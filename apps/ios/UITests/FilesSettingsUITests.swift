import XCTest

/// Channel files, recording, and settings the others see.
final class FilesSettingsUITests: NGTestCase {
    func whereIs(_ user: String, seenBy bot: String = "bob") -> String? { Host.user(user, seenBy: bot)?["channel"] as? String }

    func testChannelFilesListedDownloadedAndDeleted() {
        Host.call("/join", ["bot": "bob", "path": "/Lobby/"])
        Host.until("Bob in Lobby") { (Host.state()["me"] as? String) == "/Lobby/" }
        Host.call("/upload", ["bot": "bob", "name": "notes.txt"])
        Host.until("the file on the server") { (Host.state()["files"] as? [String])?.contains("notes.txt") == true }
        connect("admin")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Lobby'")).firstMatch.tap()
        // The app's admin is NoName (the bots have an admin too).
        Host.until("the app's admin in Lobby") { self.whereIs("NoName") == "/Lobby/" }
        app.buttons["Files"].tap()
        let file = app.buttons.matching(NSPredicate(format: "label == 'notes.txt'")).firstMatch
        waitFor(file, "the channel's file listed")
        // Downloading it: no failure said.
        file.tap()
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(any("Failed to download").exists, "downloaded without a failure")
        // Deleting it (asked first).
        action("Delete", on: file)
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Delete'")).allElementsBoundByIndex.last!
        confirm.tap()
        Host.until("the file gone for Bob") { (Host.state()["files"] as? [String])?.contains("notes.txt") == false }
    }

    /// Joining a channel that already has files doesn't announce them
    /// (as the desktop); a file added after is announced.
    func testFilesAlreadyThereAreNotAnnouncedOnJoining() {
        Host.call("/join", ["bot": "bob", "path": "/Lobby/"])
        Host.until("Bob in Lobby") { (Host.state()["me"] as? String) == "/Lobby/" }
        Host.call("/upload", ["bot": "bob", "name": "old.txt"])
        Host.until("the file on the server") { (Host.state()["files"] as? [String])?.contains("old.txt") == true }
        connect()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Lobby'")).firstMatch.tap()
        Host.until("Alice in Lobby") { self.whereIs("alice") == "/Lobby/" }
        let oldAnnounced = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'File old.txt added'")).firstMatch
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(oldAnnounced.exists, "the file already there isn't announced")
        Host.call("/upload", ["bot": "bob", "name": "new.txt"])
        waitFor(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'File new.txt added'")).firstMatch, "a new file announced")
    }

    func testRecordingMakesARecording() {
        connect()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Lobby'")).firstMatch.tap()
        Host.call("/join", ["bot": "bob", "path": "/Lobby/"])
        Host.until("Alice in Lobby") { self.whereIs("alice") == "/Lobby/" }
        more("Record conversations")
        Host.call("/talk", ["bot": "bob", "on": "1"])
        Thread.sleep(forTimeInterval: 3)
        Host.call("/talk", ["bot": "bob", "on": "0"])
        more("Stop recording")
        // Settings → Recording → Recordings lists it.
        app.navigationBars.buttons["Servers"].tap()
        app.buttons["Settings"].tap()
        let recording = app.buttons["Recording"]
        if !recording.waitForExistence(timeout: 3) { app.swipeUp() }
        recording.tap()
        app.buttons["Recordings"].tap()
        waitFor(app.cells.firstMatch, "a recording listed", timeout: 20)
        // Played: the player opens (it crashed here, its position slider
        // being made before the recording's length was known).
        // (Its row; the server list's stay underneath Settings.)
        let file = app.buttons.matching(NSPredicate(format: "label CONTAINS '.mp3' OR label CONTAINS '.wav'")).firstMatch
        waitFor(file, "the recording's row")
        file.tap()
        waitFor(app.sliders["Position"], "the player's position")
        waitFor(button("Pause"), "playing")
        button("Done").tap()
        XCTAssertEqual(app.state, .runningForeground, "still running")
    }

    func testNicknameStatusAndGenderReachTheOthers() {
        connect()
        more("Change nickname")
        let nick = app.alerts.firstMatch.textFields.firstMatch
        waitFor(nick, "the nickname box")
        replace(nick, with: "Tester")
        app.alerts.firstMatch.buttons["Change"].tap()
        Host.until("Bob seeing the new nickname") { Host.user("Tester") != nil }

        more("Status")
        waitFor(app.navigationBars.firstMatch, "the status sheet")
        app.buttons["Status, Available"].tap()
        button("Away").tap()
        let msg = app.textFields["Status message"]
        replace(msg, with: "Back soon")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Gender'")).firstMatch.tap()
        button("Female").tap()
        button("Set").tap()
        Host.until("Bob seeing Away, the message and Female") {
            let u = Host.user("Tester")
            return u?["status"] as? String == "Away" && u?["status_message"] as? String == "Back soon" && u?["gender"] as? String == "Female"
        }
        more("Question mode")
        Host.until("Bob seeing a question") { Host.user("Tester")?["status"] as? String == "Question" }
        more("Leave question mode")
        Host.until("Bob seeing it gone") { Host.user("Tester")?["status"] as? String == "Available" }
    }

    func testThisServersOwnVolume() {
        connect()
        more("Volume for this server")
        let master = app.sliders["Master volume"]
        waitFor(master, "the server's volumes")
        XCTAssertTrue((master.value as? String)?.contains("as in Settings") == true, "following Settings at first")
        master.adjust(toNormalizedSliderPosition: 0.8)
        waitFor(button("Use Settings' master volume"), "its own volume now")
        button("Use Settings' master volume").tap()
        Host.until("following Settings again") { (master.value as? String)?.contains("as in Settings") == true }
    }

    func testVoiceActivationModeFromSettings() {
        // Connected first (opening a tt:// link starts the app again, as fresh).
        connect()
        app.navigationBars.buttons["Servers"].tap()
        app.buttons["Settings"].tap()
        app.buttons["General"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Talk mode'")).firstMatch.tap()
        button("Voice activation").tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        button("Done").tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '127.0.0.1'")).firstMatch.tap()
        waitFor(any("Voice activation"), "voice activation on the server screen")
        waitFor(button("Mute"), "its mute button")
        button("Mute").tap()
        waitFor(any("Microphone muted"), "muted")
    }

    func testResetAllSettings() {
        app.buttons["Settings"].tap()
        app.buttons["General"].tap()
        let nick = app.textFields["Nickname"]
        waitFor(nick, "the nickname")
        replace(nick, with: "Someone")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.swipeUp()
        app.buttons["Transfer or Reset"].tap()
        app.buttons["Reset All Settings"].tap()
        app.buttons.matching(NSPredicate(format: "label == 'Reset All Settings'")).allElementsBoundByIndex.last { $0.isHittable }!.tap()
        // Settings again from the top (it's longer than one screen; General
        // is otherwise under the navigation bar, and a swipe down closes it).
        app.navigationBars["Transfer or Reset"].buttons.element(boundBy: 0).tap()
        button("Done").tap()
        app.buttons["Settings"].tap()
        app.buttons["General"].tap()
        Host.until("the nickname gone") { (app.textFields["Nickname"].value as? String) ?? "" == "Nickname" || (app.textFields["Nickname"].value as? String) == "" }
    }

    /// Settings → Transfer or Reset → Erase All Data & Settings: asked
    /// twice, then the app starts again as a fresh install (the welcome,
    /// no servers, settings as at first).
    func testEraseAllDataAndSettings() {
        app.buttons["Settings"].tap()
        app.buttons["General"].tap()
        let nick = app.textFields["Nickname"]
        waitFor(nick, "the nickname")
        replace(nick, with: "Someone")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.swipeUp()
        app.buttons["Transfer or Reset"].tap()
        // The three, as the iPhone's own Settings.
        for b in ["Backup and Restore", "Reset All Settings", "Erase All Data & Settings"] {
            XCTAssertTrue(app.buttons[b].exists, "\(b) offered")
        }
        app.buttons["Erase All Data & Settings"].tap()
        let cont = app.buttons.matching(NSPredicate(format: "label == 'Continue'")).allElementsBoundByIndex.last { $0.isHittable }
        XCTAssertNotNil(cont, "asked first")
        cont?.tap()
        let erase = app.buttons.matching(NSPredicate(format: "label == 'Erase All Data & Settings'")).allElementsBoundByIndex.last { $0.isHittable }
        XCTAssertNotNil(erase, "asked again")
        erase?.tap()
        // A fresh start: the welcome sheet, no saved servers.
        waitFor(app.navigationBars["Welcome to TeamTalk NG"], "the app as a new install", timeout: 20)
        button("Done").tap()
        waitFor(any("No servers yet. Add one with the Add server button."), "no servers left")
        app.buttons["Settings"].tap()
        app.buttons["General"].tap()
        Host.until("the nickname gone") { (app.textFields["Nickname"].value as? String) ?? "" == "Nickname" || (app.textFields["Nickname"].value as? String) == "" }
    }
}

/// iCloud Keychain and this iPhone's keychain, when iCloud sync is turned
/// on or off: where a password is in both, the copy the app was using
/// wins. Turning sync on: this iPhone's newer one goes to iCloud (one
/// copy, there). Turning it off: iCloud's current one is copied here, and
/// iCloud's stays for the other devices.
final class KeychainMergeUITests: NGTestCase {
    func testTheCopyInUseWinsWhenSyncChanges() {
        run("keychainMerge", says: "Keychain merge: on [cloud=new here] off [cloud=current in iCloud,phone=current in iCloud]")
    }
}
