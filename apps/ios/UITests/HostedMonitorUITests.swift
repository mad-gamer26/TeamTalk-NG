import XCTest

/// TeamTalk NG's hosted Monitor (for people without a computer): chosen
/// with what it means said first, a server monitored through it, then the
/// move to your own Monitor (recommended): the server moves across and the
/// hosted Monitor lets go of it; then back to the hosted one the same way.
final class HostedMonitorUITests: NGTestCase {
    override var pairedWithMonitor: Bool { false }

    func testTheHostedMonitorThenMovingToMyOwn() throws {
        let env = ProcessInfo.processInfo.environment
        let codeLink = env["OWN_CODE"].flatMap { $0.isEmpty ? nil : URL(string: $0) }
        connect("admin")
        more("Disconnect")
        let admins = { ((Host.state()["users"] as? [[String: Any]]) ?? []).filter { $0["username"] as? String == "admin" }.count }

        openMonitor()
        // Both offered (under Which Monitor, at the bottom), your own first and recommended.
        bottom(app.buttons["monitor-use-own"])
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
        addToMonitor()
        Host.until("the hosted Monitor logged in", timeout: 30) { admins() == before + 1 }
        // Bob writes to it privately: kept by the hosted Monitor, and moved
        // with the server.
        let monitorNick = try XCTUnwrap(((Host.state()["users"] as? [[String: Any]]) ?? [])
            .filter { $0["username"] as? String == "admin" }.compactMap { $0["nickname"] as? String }.first { $0 != "Admin" },
            "the Monitor's nickname on the server")
        let sent = Host.call("/pm", ["bot": "bob", "to": monitorNick, "text": "Before moving home"])
        XCTAssertNil(sent["error"], "\(sent)")
        Thread.sleep(forTimeInterval: 3)

        // Moving to your own Monitor: the server goes with it.
        guard let codeLink else { throw XCTSkip("no ng-monitor on the Mac (see scripts/test-ios-ui.sh)") }
        bottom(app.buttons["monitor-use-own"])
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
        waitFor(app.navigationBars["Monitor"], "back on the Monitor screen", timeout: 30)
        bottom(app.buttons["Forget this Monitor"])
        waitFor(app.buttons["Forget this Monitor"], "your own Monitor in use")
        XCTAssertFalse(app.buttons["monitor-use-hosted"].exists)
        // The same server, watched by your own Monitor now (the hosted one
        // logged out of it: still one monitor there).
        waitFor(app.buttons.matching(NSPredicate(format: "label BEGINSWITH '127.0.0.1'")).firstMatch, "the server moved to your own Monitor", timeout: 30)
        Thread.sleep(forTimeInterval: 5)
        Host.until("one monitor there: your own", timeout: 30) { admins() == before + 1 }
        // Bob's message came with it, and the server's own settings.
        seesKept("Before moving home")
        let sent2 = Host.call("/pm", ["bot": "bob", "to": monitorNick, "text": "Before moving back"])
        XCTAssertNil(sent2["error"], "\(sent2)")
        Thread.sleep(forTimeInterval: 3)

        // And back: the server moves to the hosted Monitor again, your own
        // stops watching it (still one monitor there).
        bottom(app.buttons["monitor-move-to-hosted"])
        app.buttons["monitor-move-to-hosted"].tap()
        app.buttons.matching(NSPredicate(format: "label == %@", "Move to TeamTalk NG's Monitor")).allElementsBoundByIndex.last { $0.isHittable }?.tap()
        Host.until("the hosted Monitor in use again", timeout: 30) { self.app.buttons["monitor-use-own"].exists }
        waitFor(app.buttons.matching(NSPredicate(format: "label BEGINSWITH '127.0.0.1'")).firstMatch, "the server moved to the hosted Monitor", timeout: 30)
        Thread.sleep(forTimeInterval: 5)
        Host.until("one monitor there: the hosted one", timeout: 30) { admins() == before + 1 }
        seesKept("Before moving home")
        seesKept("Before moving back")
    }

    /// Scrolled down to `e` (Which Monitor is at the bottom).
    private func bottom(_ e: XCUIElement) {
        for _ in 0..<5 where !(e.exists && e.isHittable) { app.swipeUp() }
    }

    /// From the Monitor screen: the watched server's screen, Bob's private
    /// conversation shows `text` (kept by the Monitor in use); then back.
    private func seesKept(_ text: String) {
        for _ in 0..<5 where !app.buttons.matching(NSPredicate(format: "label BEGINSWITH '127.0.0.1'")).firstMatch.isHittable { app.swipeDown() }
        visibleRow("the server on the Monitor screen", timeout: 30).tap()
        waitFor(any("Bob"), "Bob, through the Monitor", timeout: 30)
        action("Send Private Message", on: app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Bob'")).firstMatch)
        waitFor(any(text), "\(text): kept, and moved with the server", timeout: 20)
        // Back to the Monitor screen.
        for _ in 0..<4 where !app.navigationBars["Monitor"].exists || app.buttons["Bob"].exists {
            if button("Done").exists { button("Done").tap(); continue }
            app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
        waitFor(app.navigationBars["Monitor"], "the Monitor screen again")
    }
}

/// A move to TeamTalk NG's Monitor that fails changes nothing: your own
/// Monitor's notification key stays (its notifications still open), and
/// the hosted registration made for the move goes again.
final class FailedMoveUITests: NGTestCase {
    func testAFailedMoveKeepsMyMonitorsKey() {
        run("failedMove", says: "Failed move:")
        let done = app.staticTexts.matching(NSPredicate(format: "identifier == 'uitest-action-result' AND label BEGINSWITH 'Failed move: refused'")).firstMatch
        waitFor(done, "the test's result", timeout: 60)
        XCTAssertEqual(done.label, "Failed move: refused true, key kept true, hosted registration left false")
    }
}
