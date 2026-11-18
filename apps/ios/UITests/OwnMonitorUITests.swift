import XCTest

/// Your own Monitor (ng-monitor on the Mac, paired through the private NG
/// service's relay): a wrong code said plainly, pairing with the right one,
/// monitoring a server through it (end to end encrypted), and going back to
/// the hosted Monitor. Needs the new NG service and ng-monitor (see
/// scripts/test-ios-ui.sh); skipped otherwise.
final class OwnMonitorUITests: NGTestCase {
    /// Starts unpaired: the test pairs.
    override var pairedWithMonitor: Bool { false }

    func testPairingWithMyOwnMonitorAndMonitoringThroughIt() throws {
        let env = ProcessInfo.processInfo.environment
        guard let codeLink = env["OWN_CODE"].flatMap({ $0.isEmpty ? nil : URL(string: $0) }) else {
            throw XCTSkip("no ng-monitor or new NG service on the Mac (see scripts/test-ios-ui.sh)")
        }
        /// The Monitor's current pairing code (the harness keeps one fresh).
        func freshCode() -> String {
            var code = ""
            Host.until("a pairing code", timeout: 30) {
                code = (try? String(contentsOf: codeLink, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return code.count == 14
            }
            return code
        }
        let name = env["OWN_NAME"] ?? "UI Test PC"
        connect("admin")
        more("Disconnect")
        let admins = { ((Host.state()["users"] as? [[String: Any]]) ?? []).filter { $0["username"] as? String == "admin" }.count }

        app.buttons["Settings"].tap()
        let link = app.buttons["settings-monitor"]
        if !link.waitForExistence(timeout: 3) { app.swipeUp() }
        link.tap()
        XCTAssertFalse(app.buttons["Monitor a server"].exists, "no servers to add before there's a Monitor")
        app.buttons["monitor-use-own"].tap()
        waitFor(app.navigationBars["Set up your Monitor"], "the pairing screen")
        XCTAssertTrue(any("irm https://ttmonitor.mad-gamer.com/install.ps1 | iex").exists, "the Windows command")
        XCTAssertTrue(any("curl -fsSL https://ttmonitor.mad-gamer.com/install.sh | sh").exists, "the Mac and Linux command")

        // A code that isn't one, said plainly.
        let field = app.textFields["own-monitor-code"]
        replace(field, with: "ACDE-1111-2222")
        app.buttons["own-monitor-pair"].tap()
        waitFor(any("That pairing code has expired. Make a new one on your Monitor."), "the expired code said", timeout: 20)

        // The right one.
        replace(field, with: freshCode())
        app.buttons["own-monitor-pair"].tap()
        waitFor(app.navigationBars["Monitor"], "back in Settings → Monitor", timeout: 30)
        waitFor(any(name), "its own Monitor in use")
        XCTAssertTrue(app.buttons["Forget this Monitor"].exists)

        // Monitoring through it: the Mac's Monitor logs in to the server
        // (what earlier tests had it watch cleared first).
        run("clearMonitor", says: "Monitor cleared")
        // Counted once what earlier tests left has logged out.
        Thread.sleep(forTimeInterval: 3)
        let before = admins()
        button("Monitor a server").tap()
        waitFor(app.navigationBars["Monitor a server"], "the servers to choose from")
        let rows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '127.0.0.1'"))
        let end = Date().addingTimeInterval(15)
        var row = rows.firstMatch
        while Date() < end {
            if let hit = (0..<rows.count).map({ rows.element(boundBy: $0) }).first(where: { $0.isHittable }) { row = hit; break }
            Thread.sleep(forTimeInterval: 0.3)
        }
        row.tap()
        waitFor(app.navigationBars["Monitor"], "back in Settings → Monitor")
        Host.until("my own Monitor logged in", timeout: 30) { admins() == before + 1 }

        // Forgotten: no Monitor, setting one up offered again.
        button("Forget this Monitor").tap()
        button("Forget it").tap()
        waitFor(app.buttons["monitor-use-own"], "setting up a Monitor offered again")
        XCTAssertFalse(app.buttons["Monitor a server"].exists, "no servers without a Monitor")
    }
}
