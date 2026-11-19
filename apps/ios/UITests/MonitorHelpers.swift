import XCTest

/// The Monitor, as people reach it: Server List Actions → Monitor.
extension NGTestCase {
    /// From the server list to the Monitor screen.
    func openMonitor(file: StaticString = #filePath, line: UInt = #line) {
        let actions = app.buttons["Server List Actions"]
        waitFor(actions, "Server List Actions", file: file, line: line)
        actions.tap()
        let item = app.buttons.matching(NSPredicate(format: "label == 'Monitor'")).allElementsBoundByIndex.last { $0.isHittable }
        XCTAssertNotNil(item, "Monitor in Server List Actions", file: file, line: line)
        item?.tap()
        waitFor(app.navigationBars["Monitor"], "the Monitor screen", file: file, line: line)
    }

    /// From the Monitor screen back to the server list.
    func leaveMonitor() {
        app.navigationBars["Monitor"].buttons.element(boundBy: 0).tap()
        waitFor(app.buttons["Server List Actions"], "back on the server list")
    }

    /// A row starting with `prefix` on the screen in front (the server list
    /// underneath has rows of the same name).
    func visibleRow(_ what: String, prefix: String = "127.0.0.1", timeout: TimeInterval = 15,
                    file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let rows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            for i in 0..<rows.count where rows.element(boundBy: i).isHittable { return rows.element(boundBy: i) }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTFail("never: \(what)", file: file, line: line)
        return rows.firstMatch
    }

    /// On the Monitor screen: Monitor a server → the local server → its
    /// settings (`nickname` typed in when given) → Monitor; back on the
    /// Monitor screen with it listed.
    func addToMonitor(nickname: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        button("Monitor a server").tap()
        waitFor(app.navigationBars["Monitor a server"], "the servers to choose from", file: file, line: line)
        visibleRow("the saved server to monitor", file: file, line: line).tap()
        let nick = app.textFields["Nickname"]
        waitFor(nick, "its settings before it starts", file: file, line: line)
        if let nickname {
            replace(nick, with: nickname)
            nick.typeText("\n")  // Return: the keyboard goes
        }
        startMonitoring(file: file, line: line)
        _ = visibleRow("it on the Monitor screen", timeout: 20, file: file, line: line)
    }

    /// The add screen's Monitor button (not the Monitor screen's title).
    func startMonitoring(file: StaticString = #filePath, line: UInt = #line) {
        // Above the keyboard (scrolling also puts it away).
        let any = app.buttons.matching(NSPredicate(format: "label == 'Monitor'"))
        for _ in 0..<4 where !any.allElementsBoundByIndex.contains(where: { $0.isHittable && $0.frame.minY > 150 }) { app.swipeUp() }
        let start = any.allElementsBoundByIndex.last { $0.isHittable }
        XCTAssertNotNil(start, "the Monitor button", file: file, line: line)
        start?.tap()
        waitFor(app.navigationBars["Monitor"], "back on the Monitor screen", timeout: 30, file: file, line: line)
    }
}
