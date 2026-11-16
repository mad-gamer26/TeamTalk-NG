import XCTest

/// AudioNet (a private server; this Mac is the test device with its real
/// sound): an account signed in; a device's sound into the channel as a
/// login of its own that follows me; my microphone to the Mac; volumes
/// shown only while streaming; stopping; disconnecting stops everything.
final class AudioNetUITests: NGTestCase {
    func signIn() throws {
        let env = ProcessInfo.processInfo.environment
        let url = try XCTUnwrap(env["AN_URL"].flatMap { $0.isEmpty ? nil : $0 }, "AudioNet isn't built on the Mac (see scripts/test-ios-ui.sh)")
        more("AudioNet")
        XCTAssertFalse(app.sliders.firstMatch.exists, "no volume before anything streams")
        button("Add an AudioNet account").tap()
        let server = app.textFields["Server address"]
        waitFor(server, "the sign-in form")
        replace(server, with: url)
        replace(app.textFields["Account name"], with: env["AN_USER"] ?? "tester")
        let pw = app.secureTextFields["Password"]
        pw.tap(); pw.typeText(env["AN_PASSWORD"] ?? "")
        button("Sign in").tap()
    }

    var macDevice: XCUIElement { app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Mac test device'")).firstMatch }

    /// The test host's people, as Bob sees them, whose nickname starts so.
    func companions(_ prefix: String = "NoName - ") -> [[String: Any]] {
        ((Host.state()["users"] as? [[String: Any]]) ?? []).filter { ($0["nickname"] as? String)?.hasPrefix(prefix) == true }
    }

    /// Another device's sound settings: the Mac's real outputs and
    /// microphones with their volumes and mute (only read: the Mac's own
    /// volume isn't changed by the test).
    func testAnotherDevicesSoundSettings() throws {
        connect()
        try signIn()
        waitFor(macDevice, "the Mac test device listed", timeout: 40)
        macDevice.tap()
        let settings = app.buttons["Sound settings of Mac test device"]
        if !settings.waitForExistence(timeout: 5) { app.swipeUp() }
        settings.tap()
        waitFor(app.navigationBars["Sound settings of Mac test device"], "its screen")
        waitFor(app.staticTexts["Outputs"], "its outputs")
        XCTAssertTrue(app.staticTexts["Microphones"].exists, "its microphones")
        let volume = app.sliders.matching(NSPredicate(format: "label BEGINSWITH 'Volume of '")).firstMatch
        waitFor(volume, "a volume slider")
        XCTAssertTrue((volume.value as? String)?.hasSuffix("percent") == true, "its value in words: \(volume.value ?? "")")
        XCTAssertTrue(app.switches.matching(NSPredicate(format: "label BEGINSWITH 'Mute '")).firstMatch.exists, "a mute switch")
    }

    func testIntoTheChannelAsALoginThatFollowsMeAndToTheMac() throws {
        connect()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Lobby'")).firstMatch.tap()
        Host.call("/join", ["bot": "bob", "path": "/Lobby/"])
        Host.until("Alice in Lobby") { (Host.user("alice")?["channel"] as? String) == "/Lobby/" }
        try signIn()
        waitFor(macDevice, "the Mac test device listed", timeout: 40)
        macDevice.tap()
        let into = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Send ' AND label ENDSWITH ' into this channel'")).firstMatch
        waitFor(into, "the Mac's sounds offered")
        into.tap()
        // A login of its own, named "NoName - <sound>", in Lobby with me.
        Host.until("the stream's login in Lobby", timeout: 30) {
            self.companions().contains { $0["channel"] as? String == "/Lobby/" }
        }
        XCTAssertEqual((Host.user("alice")?["channel"] as? String), "/Lobby/", "my own login is untouched")
        // Its volume, now that it streams.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let volume = app.sliders.matching(NSPredicate(format: "label BEGINSWITH 'Volume of '")).firstMatch
        waitFor(volume, "the stream's volume while it streams")
        volume.adjust(toNormalizedSliderPosition: 0.5)
        let mute = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Mute '")).firstMatch
        mute.tap()
        waitFor(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Unmute '")).firstMatch, "muted")

        // My microphone to the Mac's first output too: two streams at once.
        macDevice.tap()
        let toMac = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Send my microphone to '")).firstMatch
        waitFor(toMac, "the Mac's outputs offered")
        toMac.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        waitFor(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'My microphone to '")).firstMatch, "the second stream listed")
        Host.until("two volumes", timeout: 10) {
            self.app.sliders.matching(NSPredicate(format: "label BEGINSWITH 'Volume of '")).count == 2
        }

        // Following me: to the root channel.
        button("Done").tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'TTNG Test'")).firstMatch.tap()
        Host.until("Alice in the root channel") { (Host.user("alice")?["channel"] as? String) == "/" }
        Host.until("the stream's login followed", timeout: 15) {
            self.companions().contains { $0["channel"] as? String == "/" }
        }

        // Stopping the channel stream: its login goes.
        more("AudioNet (2 streaming)")
        let stop = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Stop ' AND label CONTAINS ' into '")).firstMatch
        waitFor(stop, "its Stop")
        stop.tap()
        Host.until("the stream's login gone", timeout: 15) { self.companions().isEmpty }
        XCTAssertEqual(app.sliders.matching(NSPredicate(format: "label BEGINSWITH 'Volume of '")).count, 1, "one stream left")
        button("Done").tap()

        // Disconnecting stops the rest.
        more("Disconnect")
        waitFor(app.navigationBars["Servers"], "the server list")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '127.0.0.1'")).firstMatch.tap()
        waitFor(any("Lobby"), "connected again")
        more("AudioNet")
        XCTAssertFalse(app.sliders.firstMatch.waitForExistence(timeout: 2), "nothing streaming after disconnecting")
        // The account stays signed in.
        waitFor(macDevice, "the account still signed in", timeout: 40)
    }
}
