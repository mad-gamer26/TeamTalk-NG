import XCTest

/// The Monitor: a server explored through it, as if connected.
final class MonitorUITests: NGTestCase {
    func testAMonitoredServerLooksConnectedWithoutAudio() {
        // A saved server (as admin), the app itself not connected to it.
        connect("admin")
        more("Disconnect")
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
}
