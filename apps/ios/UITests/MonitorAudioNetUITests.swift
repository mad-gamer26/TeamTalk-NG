import XCTest

/// The Monitor (a server explored through it, as if connected) and AudioNet
/// (signing in, sending a device's sound to the channel, stopping).
final class MonitorAudioNetUITests: NGTestCase {
    func testAMonitoredServerLooksConnectedWithoutAudio() {
        // A saved server (as admin), the app itself not connected to it.
        connect("admin")
        more("Disconnect")
        app.navigationBars.buttons["Servers"].tap()
        app.buttons["Monitor"].tap()
        app.buttons["Add a server"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '127.0.0.1'")).firstMatch
        waitFor(row, "the saved server to monitor")
        row.tap()
        let watched = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '127.0.0.1'")).firstMatch
        waitFor(watched, "it monitored", timeout: 20)
        Host.until("the Monitor logged in (Bob seeing a second admin)", timeout: 30) {
            ((Host.state()["users"] as? [[String: Any]]) ?? []).filter { $0["username"] as? String == "admin" }.count >= 2
        }
        watched.tap()
        // As if connected: the channels and people.
        waitFor(any("Lobby"), "the channels, through the Monitor", timeout: 30)
        waitFor(any("Bob"), "Bob, through the Monitor")
        // No audio at all (a text-only client).
        XCTAssertFalse(app.buttons["Talk"].exists, "no Talk button")
        app.buttons["More"].tap()
        XCTAssertFalse(button("Mute Everyone for Me").exists, "no Mute everyone")
        XCTAssertFalse(button("Record conversations").exists, "no recording")
        XCTAssertFalse(button("AudioNet").exists, "no AudioNet")
        // Admin through the Monitor: its accounts.
        button("User accounts").tap()
        waitFor(any("carol"), "the server's accounts, through the Monitor", timeout: 20)
        button("Done").tap()
        // Disconnect: as a live one.
        more("Disconnect")
        waitFor(button("Connect"), "disconnected, with Connect")
        button("Connect").tap()
        waitFor(any("Lobby"), "back, through the Monitor", timeout: 30)
    }

    func testAudioNetSendsADevicesSoundAndStopsCompletely() throws {
        let env = ProcessInfo.processInfo.environment
        let url = try XCTUnwrap(env["AN_URL"].flatMap { $0.isEmpty ? nil : $0 }, "AudioNet isn't built on the Mac (see scripts/test-ios-ui.sh)")
        connect()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Lobby'")).firstMatch.tap()
        Host.call("/join", ["bot": "bob", "path": "/Lobby/"])
        more("AudioNet")
        button("Sign in to AudioNet").tap()
        let server = app.textFields["Server address"]
        waitFor(server, "the sign-in form")
        replace(server, with: url)
        let user = app.textFields["Account name"]
        replace(user, with: env["AN_USER"] ?? "tester")
        let pw = app.secureTextFields["Password"]
        pw.tap(); pw.typeText(env["AN_PASSWORD"] ?? "")
        button("Sign in").tap()
        let device = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Mac test device'")).firstMatch
        waitFor(device, "the Mac test device listed", timeout: 40)
        device.tap()
        // Its first sound.
        let sound = app.sheets.buttons.firstMatch.exists ? app.sheets.buttons.firstMatch
            : app.buttons.matching(NSPredicate(format: "NOT (label IN %@)", ["Cancel", "Done", "Sign out of AudioNet", "Stop sending"])).element(boundBy: 0)
        waitFor(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Send from'")).firstMatch, "the device's sounds offered")
        let sounds = app.buttons.allElementsBoundByIndex.filter { b in
            let l = b.label
            return !["Cancel", "Done", "Sign out of AudioNet", "Stop sending"].contains(l) && !l.hasPrefix("Mac test device") && b.isHittable
        }
        _ = sound
        try XCTUnwrap(sounds.first, "a sound to choose").tap()
        // Sending: Bob sees Alice streaming (the media file stream).
        Host.until("Bob seeing Alice stream", timeout: 30) { Host.user("alice")?["streaming"] as? Bool == true }
        waitFor(any("sending"), "sending, on the AudioNet screen", timeout: 20)
        button("Stop sending").tap()
        Host.until("the stream stopped for Bob", timeout: 20) { Host.user("alice")?["streaming"] as? Bool == false }
        // Choosing again works (the session closed, the connection opened again for the screen).
        waitFor(device, "the device listed again", timeout: 40)
        device.tap()
        waitFor(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Send from'")).firstMatch, "its sounds again")
        let again = app.buttons.allElementsBoundByIndex.filter { b in
            !["Cancel", "Done", "Sign out of AudioNet", "Stop sending"].contains(b.label) && !b.label.hasPrefix("Mac test device") && b.isHittable
        }
        try XCTUnwrap(again.first).tap()
        Host.until("streaming again", timeout: 30) { Host.user("alice")?["streaming"] as? Bool == true }
        button("Stop sending").tap()
        Host.until("stopped again", timeout: 20) { Host.user("alice")?["streaming"] as? Bool == false }
    }
}
