import XCTest

/// TeamTalk NG's hosted Monitor (for people without a computer): chosen
/// with what it means said first, a server monitored through it, then the
/// move to your own Monitor (recommended): the server moves across and the
/// hosted Monitor lets go of it.
final class HostedMonitorUITests: NGTestCase {
    override var pairedWithMonitor: Bool { false }

    func testTheHostedMonitorThenMovingToMyOwn() throws {
        let env = ProcessInfo.processInfo.environment
        let codeLink = env["OWN_CODE"].flatMap { $0.isEmpty ? nil : URL(string: $0) }
        connect("admin")
        more("Disconnect")
        let admins = { ((Host.state()["users"] as? [[String: Any]]) ?? []).filter { $0["username"] as? String == "admin" }.count }

        app.buttons["Settings"].tap()
        let link = app.buttons["settings-monitor"]
        if !link.waitForExistence(timeout: 3) { app.swipeUp() }
        link.tap()
        // Both offered, your own first and recommended.
        waitFor(app.buttons["monitor-use-own"], "setting up your own offered")
        XCTAssertTrue(app.buttons["monitor-use-own"].label.contains("recommended"), app.buttons["monitor-use-own"].label)
        app.buttons["monitor-use-hosted"].tap()
        // What it means, before it's chosen.
        waitFor(any("keeps their accounts' passwords there, encrypted"), "the hosted Monitor explained")
        app.buttons.matching(NSPredicate(format: "label == %@", "Use TeamTalk NG's Monitor")).allElementsBoundByIndex.last { $0.isHittable }?.tap()
        waitFor(any("TeamTalk NG's Monitor"), "the hosted Monitor in use")

        // Monitoring through it (the Monitor clears what earlier tests left).
        run("clearMonitor", says: "Monitor cleared")
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
        Host.until("the hosted Monitor logged in", timeout: 30) { admins() == before + 1 }

        // Moving to your own Monitor: the server goes with it.
        guard let codeLink else { throw XCTSkip("no ng-monitor on the Mac (see scripts/test-ios-ui.sh)") }
        app.buttons["monitor-use-own"].tap()
        waitFor(app.navigationBars["Set up your Monitor"], "the pairing screen")
        let note = any("Pairing moves the servers TeamTalk NG's Monitor watches to your own")
        for _ in 0..<3 where !note.exists { app.swipeUp() }
        XCTAssertTrue(note.exists, "the move said first")
        var code = ""
        Host.until("a pairing code", timeout: 30) {
            code = (try? String(contentsOf: codeLink, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return code.count == 14
        }
        replace(app.textFields["own-monitor-code"], with: code)
        app.buttons["own-monitor-pair"].tap()
        waitFor(app.navigationBars["Monitor"], "back in Settings → Monitor", timeout: 30)
        waitFor(app.buttons["Forget this Monitor"], "your own Monitor in use")
        XCTAssertFalse(app.buttons["monitor-use-hosted"].exists)
        // The same server, watched by your own Monitor now (the hosted one
        // logged out of it: still one monitor there).
        waitFor(app.buttons.matching(NSPredicate(format: "label BEGINSWITH '127.0.0.1'")).firstMatch, "the server moved to your own Monitor", timeout: 30)
        Thread.sleep(forTimeInterval: 5)
        Host.until("one monitor there: your own", timeout: 30) { admins() == before + 1 }
    }
}
