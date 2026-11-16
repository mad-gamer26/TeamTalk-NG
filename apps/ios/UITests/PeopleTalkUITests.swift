import XCTest

/// What can be done to people (the people menu and More), and talking.
final class PeopleTalkUITests: NGTestCase {
    func person(_ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }

    /// One of a person's menu items (touch and hold, as the desktop's Users menu).
    func menu(_ item: String, on name: String) {
        let p = person(name)
        waitFor(p, "\(name) in the tree")
        action(item, on: p)
    }

    func testRelayingSaysStopStraightAway() {
        connect()
        menu("Relay Their Voice to My Channel", on: "Bob")
        // At once: the next look says Stop, and the More menu has Stop relaying.
        person("Bob").press(forDuration: 1.2)
        waitFor(button("Stop Relaying Their Voice"), "Stop Relaying next", timeout: 5)
        button("Stop Relaying Their Voice").tap()
        person("Bob").press(forDuration: 1.2)
        waitFor(button("Relay Their Voice to My Channel"), "Relay again", timeout: 5)
        button("Relay Their Media Files to My Channel").tap()
        app.buttons["More"].tap()
        waitFor(button("Stop relaying"), "Stop relaying in More", timeout: 5)
        button("Stop relaying").tap()
        person("Bob").press(forDuration: 1.2)
        waitFor(button("Relay Their Media Files to My Channel"), "relaying stopped from More", timeout: 5)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    }

    func testMutingSaysUnmuteStraightAway() {
        connect()
        menu("Mute Their Voice for Me", on: "Bob")
        // At once: the next look says Unmute (no muting twice).
        person("Bob").press(forDuration: 1.2)
        waitFor(button("Unmute Their Voice for Me"), "Unmute Voice next", timeout: 5)
        button("Unmute Their Voice for Me").tap()
        person("Bob").press(forDuration: 1.2)
        waitFor(button("Mute Their Voice for Me"), "Mute Voice again", timeout: 5)
        button("Mute Their Media Files for Me").tap()
        person("Bob").press(forDuration: 1.2)
        waitFor(button("Unmute Their Media Files for Me"), "Unmute Media File next", timeout: 5)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    }

    func testMuteEveryoneTogglesStraightAway() {
        connect()
        // The desktop's keyboard shortcut (Command-M) first.
        shortcut("m", .command)
        app.buttons["More"].tap()
        waitFor(button("Unmute Everyone for Me"), "muted by Command-M", timeout: 5)
        button("Unmute Everyone for Me").tap()
        app.buttons["More"].tap()
        waitFor(button("Mute Everyone for Me"), "Mute everyone next", timeout: 5)
        button("Mute Everyone for Me").tap()
        app.buttons["More"].tap()
        waitFor(button("Unmute Everyone for Me"), "Unmute everyone next", timeout: 5)
        closeMenu()
        // The keys still work after the menu (Command-M unmutes); and the
        // app's own Control-2 opens the chat.
        shortcut("m", .command)
        app.buttons["More"].tap()
        waitFor(button("Mute Everyone for Me"), "unmuted by Command-M after using the menu", timeout: 5)
        closeMenu()
        shortcut("2", .control)
        waitFor(app.textFields["Message the channel"], "the chat, by Control-2", timeout: 5)
    }

    func testShortcutsStillWorkAfterTypingAMessage() {
        connect()
        app.buttons["Chat"].tap()
        let field = app.textFields["Message the channel"]
        waitFor(field, "the chat")
        field.tap(); field.typeText("Shortcut check")
        button("Send").tap()
        Host.until("Bob getting it") { Host.messages().contains { $0["text"] as? String == "Shortcut check" } }
        // Still in the box (for the next message): the keys work there too.
        shortcut("1", .control, until: any("Lobby"), "the channels, by Control-1 after typing")
    }

    func testOpKickAndBanAsAdmin() {
        connect("admin")
        Host.until("Carol here") { Host.user("carol", seenBy: "admin") != nil }
        menu("Make Channel Operator", on: "Bob")
        Host.until("Bob an operator") { (Host.user("bob", seenBy: "carol")?["operator"] as? Bool) == true }
        menu("Remove Channel Operator", on: "Bob")
        Host.until("Bob not an operator") { (Host.user("bob", seenBy: "carol")?["operator"] as? Bool) == false }
        menu("Kick From Server", on: "Carol")
        Host.until("Carol kicked") { (Host.state("carol")["kicked"] as? Bool) == true }
    }

    func testMovingPeopleFromTheMoreMenu() {
        connect("admin")
        more("Move users")
        // The switches themselves (a tap on a list toggle's words doesn't flip it).
        let bob = app.switches.matching(NSPredicate(format: "label BEGINSWITH 'Bob'")).firstMatch
        waitFor(bob, "Bob to pick")
        bob.switches.firstMatch.exists ? bob.switches.firstMatch.tap() : bob.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let carol = app.switches.matching(NSPredicate(format: "label BEGINSWITH 'Carol'")).firstMatch
        carol.switches.firstMatch.exists ? carol.switches.firstMatch.tap() : carol.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(bob.value as? String, "1", "Bob picked")
        button("Next").tap()
        waitFor(button("Lobby"), "the channels")
        button("Lobby").tap()
        Host.until("Bob and Carol in Lobby") {
            (Host.user("bob")?["channel"] as? String) == "/Lobby/" && (Host.user("carol")?["channel"] as? String) == "/Lobby/"
        }
    }

    func testTransmitControlInAnOrdinaryChannel() {
        connect("admin")
        // Bob talks; admin stops his voice in the root channel.
        Host.call("/talk", ["bot": "bob", "on": "1"])
        waitFor(any("Bob, Speaking"), "Bob heard talking")
        menu("Transmit Control", on: "Bob")
        let voice = app.switches["Allow Voice Transmission"]
        waitFor(voice, "the Transmit Control switches")
        XCTAssertEqual(voice.value as? String, "1", "allowed to begin with (not listed)")
        XCTAssertFalse(app.switches["Allow All Voice Transmission"].exists, "Allow All only in classrooms")
        voice.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        Host.until("Bob blocked") { (voice.value as? String) == "0" }
        button("Done").tap()
        Host.until("Bob silenced") { !any("Bob, Speaking").exists }
        menu("Transmit Control", on: "Bob")
        let again = app.switches["Allow Voice Transmission"]
        waitFor(again, "the switches again")
        XCTAssertEqual(again.value as? String, "0", "shown blocked")
        again.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        button("Done").tap()
        waitFor(any("Bob, Speaking"), "Bob heard again")
        Host.call("/talk", ["bot": "bob", "on": "0"])
    }

    func testTalkButtonTapTogglesAndHoldTalksWhileHeld() {
        connect()
        let talk = app.buttons["Talk"]
        waitFor(talk, "the Talk button")
        talk.tap()
        Host.until("Bob hearing Alice") { (Host.user("alice")?["talking"] as? Bool) == true }
        XCTAssertEqual(talk.value as? String, "Talking")
        talk.tap()
        Host.until("Alice stopped") { (Host.user("alice")?["talking"] as? Bool) == false }
        // Held: talking while held, stopped when let go.
        var heardWhileHeld = false
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            heardWhileHeld = (Host.user("alice")?["talking"] as? Bool) == true
        }
        talk.press(forDuration: 3.5)
        XCTAssertTrue(heardWhileHeld, "talking while held")
        Host.until("stopped when let go") { (Host.user("alice")?["talking"] as? Bool) == false }
    }

    func testSomeoneTalkingShowsInTheTree() {
        connect()
        Host.call("/talk", ["bot": "bob", "on": "1"])
        waitFor(any("Bob, Speaking"), "Bob speaking in the tree (the desktop's word)", timeout: 15)
        Host.call("/talk", ["bot": "bob", "on": "0"])
    }
}
