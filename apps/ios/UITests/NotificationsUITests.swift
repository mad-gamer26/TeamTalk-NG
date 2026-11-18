import XCTest

/// Background notifications of a server's events, what tapping them opens,
/// and the chat as the desktop keeps it (private messages apart, nothing
/// kept after disconnecting).
final class NotificationsUITests: NGTestCase {
    private func backToList() {
        app.navigationBars.buttons["Servers"].tap()
        waitFor(app.navigationBars["Servers"], "the server list")
    }

    /// The delivered notifications, "title | text" each.
    private func delivered() -> String {
        run("delivered", says: "Delivered:")
        return app.staticTexts.matching(identifier: "uitest-action-result").firstMatch.label
    }

    private func toBackground() {
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
    }

    func testEventsNotifyInTheBackgroundAndOpenTheirScreen() {
        // The desktop's message popup off, so only the tap opens a conversation.
        app.buttons["Settings"].tap()
        app.buttons["Display"].tap()
        let popup = app.switches["Open private messages as they arrive"]
        for _ in 0..<4 where !popup.isHittable { app.swipeUp() }
        waitFor(popup, "the popup setting")
        if popup.value as? String == "1" { popup.switches.firstMatch.exists ? popup.switches.firstMatch.tap() : popup.tap() }
        for _ in 0..<3 where !app.buttons["Notifications"].exists { app.swipeUp() }
        XCTAssertTrue(app.buttons["Notifications"].exists, "Display's Notifications")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        button("Done").tap()

        connect()
        Host.until("Bob seeing Alice") { Host.user("alice") != nil }
        backToList()
        run("clearDelivered", says: "Cleared")
        toBackground()
        Host.call("/say", ["bot": "bob", "text": "Hello all"])
        Host.call("/pm", ["bot": "bob", "to": "alice", "text": "Hi"])
        Host.call("/logout", ["bot": "carol"])
        Thread.sleep(forTimeInterval: 3)
        app.activate()
        let list = delivered()
        for want in ["Channel message from Bob: Hello all", "Private message from Bob: Hi", "Carol logged out"] {
            XCTAssertTrue(list.contains(want), "\(want) in \(list)")
        }
        XCTAssertFalse(list.contains("Bob |"), "titled with the server, not a person: \(list)")

        // A channel message opens the server's Chat tab, without the private one.
        run("tapNotification", ["contains": "Channel message"], says: "Opened")
        waitFor(any("Hello all"), "the Chat tab with the channel message")
        XCTAssertTrue(app.buttons["Chat"].isSelected, "on the Chat tab")
        XCTAssertFalse(app.staticTexts["Hi"].exists, "the private message isn't in the channel chat")
        // A private message opens its conversation.
        backToList()
        run("tapNotification", ["contains": "Private message"], says: "Opened")
        waitFor(app.textFields["Message Bob"], "the conversation with Bob")
        waitFor(any("Hi"), "Bob's message in it")
    }

    func testTheChatStartsOverAfterDisconnecting() {
        connect()
        app.buttons["Chat"].tap()
        Host.call("/say", ["bot": "bob", "text": "Before disconnecting"])
        waitFor(any("Before disconnecting"), "Bob's message in the chat")
        more("Disconnect")
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '127.0.0.1'")).firstMatch
        waitFor(row, "the server list")
        row.tap()
        waitFor(any("Lobby"), "connected again")
        app.buttons["Chat"].tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(any("Before disconnecting").exists, "the old session's chat is gone")
    }
}
