import XCTest

/// Siri's, the Shortcuts app's, Control Center's and Live Activities'
/// actions (run through the debug-only test link: Siri can't be driven by a
/// test), and Settings → Live Activities.
final class ShortcutsLiveUITests: NGTestCase {
    var result: XCUIElement { app.staticTexts["uitest-action-result"] }

    func testNothingConnectedSaysSo() {
        run("muteEveryone", says: "You're not connected to a server.")
        run("disconnect", says: "You're not connected to a server.")
    }

    func testMicrophoneTalksAndStops() {
        connect()
        run("microphone", ["value": "on"], says: "Talking on")
        Host.until("Bob hearing Alice") { (Host.user("alice")?["talking"] as? Bool) == true }
        run("microphone", ["value": "off"], says: "Stopped talking on")
        Host.until("Alice stopped") { (Host.user("alice")?["talking"] as? Bool) == false }
    }

    func testMuteEveryoneForMeAndTalkMode() {
        connect()
        run("muteEveryone", ["value": "on"], says: "Everyone muted for you")
        app.buttons["More"].tap()
        waitFor(button("Unmute Everyone for Me"), "the More menu following")
        closeMenu()
        run("muteEveryone", ["value": "toggle"], says: "Everyone unmuted for you")
        run("talkMode", ["value": "voiceActivation"], says: "Voice activation on.")
        waitFor(any("Voice activation"), "voice activation on the server's screen")
        run("talkMode", ["value": "switchMode"], says: "Push to talk on.")
    }

    func testStatusAndMessages() {
        connect()
        Host.until("Alice in the root channel") { (Host.user("alice")?["channel"] as? String) == "/" }
        run("status", ["value": "away", "message": "On the bus"], says: "Status set to Away")
        Host.until("Bob seeing Away, On the bus") {
            Host.user("alice")?["status"] as? String == "Away" && Host.user("alice")?["status_message"] as? String == "On the bus"
        }
        run("message", ["text": "Hello from Siri"], says: "Sent to the channel.")
        Host.until("Bob receiving it") { Host.messages().contains { $0["text"] as? String == "Hello from Siri" && $0["kind"] as? String == "channel" } }
        run("message", ["text": "Just for you", "to": "bob"], says: "Sent to Bob.")
        Host.until("Bob receiving it privately") { Host.messages().contains { $0["text"] as? String == "Just for you" && $0["kind"] as? String == "private" } }
        run("message", ["text": "Hi", "to": "nobody-here"], says: "Nobody called nobody-here")
    }

    func testRefreshSoundDevicesThenTalking() {
        connect()
        run("refreshSoundDevices", says: "Sound devices refreshed.")
        run("microphone", ["value": "on"], says: "Talking on")
        Host.until("Bob hearing Alice after the refresh") { (Host.user("alice")?["talking"] as? Bool) == true }
        run("microphone", ["value": "off"], says: "Stopped talking on")
    }

    func testDisconnectGoesBackToTheList() {
        connect()
        run("disconnect", says: "Disconnected from")
        waitFor(app.navigationBars["Servers"], "the server list")
        Host.until("Bob seeing Alice go") { Host.user("alice") == nil }
    }

    /// Scrolled well into view (XCUITest calls a row at the very bottom
    /// edge hittable, and its tap lands below it).
    func reveal(_ e: XCUIElement) {
        let bottom = app.windows.firstMatch.frame.maxY - 120
        var swiped = false
        for _ in 0..<6 where !(e.exists && e.isHittable && e.frame.maxY < bottom) { app.swipeUp(); swiped = true }
        // Still scrolling, a tap only stops it.
        if swiped { Thread.sleep(forTimeInterval: 1.5) }
    }

    func openLiveActivitySettings() {
        if app.navigationBars.buttons["Servers"].exists { app.navigationBars.buttons["Servers"].tap() }
        app.buttons["Settings"].tap()
        let link = app.buttons["Live Activities"]
        if !link.waitForExistence(timeout: 3) || !link.isHittable { app.swipeUp() }
        link.tap()
        waitFor(app.switches["Show Live Activities"], "Settings → Live Activities")
    }

    func testALiveActivityShowsWhileConnectedAndCanBeTurnedOff() {
        connect()
        openLiveActivitySettings()
        waitFor(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Showing now: 127.0.0.1'")).firstMatch,
                "this server's Live Activity", timeout: 15)
        let show = app.switches["Show Live Activities"]
        show.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        waitFor(any("None showing now."), "it gone once turned off", timeout: 15)
        show.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        waitFor(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Showing now: 127.0.0.1'")).firstMatch,
                "back once turned on", timeout: 15)
    }

    func testLiveActivityButtonsChosenAndOrdered() {
        openLiveActivitySettings()
        // The first part shown can be turned off.
        let lastMessage = app.switches["Last channel message"]
        reveal(lastMessage)
        XCTAssertEqual(lastMessage.value as? String, "1")
        lastMessage.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        Host.until("off") { (lastMessage.value as? String) == "0" }
        // Buttons: the defaults, one added, one moved up, one removed.
        let disconnect = app.buttons["Disconnect"]
        reveal(disconnect)
        XCTAssertEqual(disconnect.value as? String, "3 of 3")
        let add = app.buttons["Add Switch talk mode"]
        reveal(add)
        add.tap()
        waitFor(app.buttons["Switch talk mode"], "the added button")
        XCTAssertEqual(app.buttons["Switch talk mode"].value as? String, "4 of 4")
        app.buttons["Switch talk mode"].tap()
        button("Move Up").tap()
        Host.until("moved up") { (self.app.buttons["Switch talk mode"].value as? String) == "3 of 4" }
        XCTAssertEqual(disconnect.value as? String, "4 of 4")
        disconnect.tap()
        button("Remove").tap()
        Host.until("removed") { !self.app.buttons["Disconnect"].exists }
        // Four at most: with three again, Disconnect can be added back.
        XCTAssertTrue(app.buttons["Add Disconnect"].exists)
    }
}

/// Siri, Shortcuts and Control Center list the saved servers, also after
/// they came another way than an edit here (iCloud at launch, a restore):
/// the shared list is written at every start.
final class ShortcutServersUITests: NGTestCase {
    func testTheSharedServerListIsRefreshedAtLaunch() {
        connect("admin")
        more("Disconnect")
        run("shortcutServers", says: "Shortcut servers: 1 of 1")
        // Emptied behind the app's back (as after the erase), then the app
        // starting from what it has saved.
        run("shortcutServers", ["clear": "1"], says: "Shortcut servers: 0 of 1")
        run("shortcutServers", ["restart": "1"], says: "Shortcut servers: 1 of 1")
    }
}

/// No call audio (or microphone) until a server is connected: the phone
/// switched to call mode as soon as the app opened before.
final class AudioSessionUITests: NGTestCase {
    func testCallAudioOnlyWhileConnected() {
        run("audioSession", says: "Audio session: playback")
        connect("alice")
        run("audioSession", says: "Audio session: call")
        more("Disconnect")
        Thread.sleep(forTimeInterval: 2)
        run("audioSession", says: "Audio session: playback")
    }
}
