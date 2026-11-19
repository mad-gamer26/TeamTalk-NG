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

        openMonitor()
        let setUp = app.buttons["monitor-use-own"]
        for _ in 0..<4 where !setUp.isHittable { app.swipeUp() }
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
        waitFor(app.navigationBars["Monitor"], "back on the Monitor screen", timeout: 30)
        waitFor(any(name), "its own Monitor in use")
        XCTAssertTrue(app.buttons["Forget this Monitor"].exists)

        // Monitoring through it: the Mac's Monitor logs in to the server
        // (what earlier tests had it watch cleared first).
        run("clearMonitor", says: "Monitor cleared")
        // Counted once what earlier tests left has logged out.
        Thread.sleep(forTimeInterval: 3)
        let before = admins()
        addToMonitor()
        Host.until("my own Monitor logged in", timeout: 30) { admins() == before + 1 }

        // Forgotten: no Monitor, setting one up offered again.
        let forget = button("Forget this Monitor")
        for _ in 0..<4 where !forget.isHittable { app.swipeUp() }
        forget.tap()
        button("Forget it").tap()
        waitFor(app.buttons["monitor-use-own"], "setting up a Monitor offered again")
        XCTAssertFalse(app.buttons["Monitor a server"].exists, "no servers without a Monitor")
    }
}
