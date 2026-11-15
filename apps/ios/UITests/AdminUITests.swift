import XCTest

/// Admin and operator things: channels made, changed and deleted; bans;
/// subscriptions; a classroom's Allow All.
final class AdminUITests: NGTestCase {
    func channels(_ bot: String = "admin") -> [String] { Host.state(bot)["channels"] as? [String] ?? [] }
    func row(_ prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    func testAChannelMadeChangedAndDeleted() {
        connect("admin")
        more("New channel")
        let name = app.textFields["Name"]
        waitFor(name, "the new channel's form")
        name.tap(); name.typeText("Testroom")
        button("Make").tap()
        Host.until("the channel on the server") { self.channels().contains("/Testroom/") }
        // "Join channel on exit", on by default as the desktop's: the app is in it.
        Host.until("the app's admin in it") { (Host.user("NoName", seenBy: "admin")?["channel"] as? String) == "/Testroom/" }
        // Deleted (asked first).
        waitFor(row("Testroom"), "the new channel in the tree")
        action("Delete Channel", on: row("Testroom"))
        app.buttons.matching(NSPredicate(format: "label == 'Delete'")).allElementsBoundByIndex.last!.tap()
        Host.until("the channel gone") { !self.channels().contains("/Testroom/") }
    }

    func testABanByUsernameIsListedAndRemoved() {
        connect("admin")
        action("Kick and Ban From Server", on: row("Carol"))
        button("Ban by username").tap()
        Host.until("Carol kicked") { (Host.state("carol")["kicked"] as? Bool) == true }
        more("Bans")
        let ban = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Carol, by account'")).firstMatch
        waitFor(ban, "Carol's ban listed", timeout: 10)
        // A server ban: no channel said.
        XCTAssertFalse(ban.label.contains("channel"), "a server ban, not a channel's: \(ban.label)")
        ban.swipeLeft()
        button("Remove ban").tap()
        Host.until("the ban gone from the list") { !app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Carol, by account'")).firstMatch.exists }
        button("Done").tap()
        // Carol can log in again.
        Host.call("/reset")
        Host.until("Carol back") { (Host.state("carol")["connected"] as? Bool) == true }
    }

    func testUnsubscribingFromSomeonesChannelMessages() {
        connect()
        Host.until("Bob and the admin bot in the root channel with Alice") {
            ["bob", "admin", "alice"].allSatisfy { (Host.user($0, seenBy: "bob")?["channel"] as? String) == "/" }
        }
        action("Subscriptions", on: row("Bob"))
        let sub = app.switches.matching(NSPredicate(format: "label CONTAINS[c] 'channel' AND label CONTAINS[c] 'message' AND NOT (label CONTAINS[c] 'intercept')")).firstMatch
        waitFor(sub, "the channel messages subscription")
        XCTAssertEqual(sub.value as? String, "1", "subscribed by default")
        sub.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        Host.until("unsubscribed") { (sub.value as? String) == "0" }
        button("Done").tap()
        app.buttons["Chat"].tap()
        Host.call("/say", ["bot": "bob", "text": "You shouldn't see this"])
        Host.call("/say", ["bot": "admin", "text": "The others are still heard"])
        waitFor(any("The others are still heard"), "someone else's message")
        XCTAssertFalse(any("You shouldn't see this").exists, "Bob's message not received")
    }

    func testAClassroomAllowsEveryoneToTalk() {
        connect("admin")
        row("Class").tap()
        Host.call("/join", ["bot": "bob", "path": "/Class/"])
        Host.until("Bob in Class") { (Host.user("bob", seenBy: "admin")?["channel"] as? String) == "/Class/" }
        Host.call("/talk", ["bot": "bob", "on": "1"])
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(any("Bob, Speaking").exists, "a classroom stops everyone by default")
        action("Transmit Control", on: row("Bob"))
        let all = app.switches["Allow All Voice Transmission"]
        waitFor(all, "Allow All, in a classroom")
        all.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        button("Done").tap()
        waitFor(any("Bob, Speaking"), "Bob heard once everyone may talk", timeout: 15)
        Host.call("/talk", ["bot": "bob", "on": "0"])
    }
}
