import XCTest

/// Passwords as the old app showed them: a Show password switch on every
/// password field, the passwords in links and in the accounts list, and
/// the accounts' Copy Link, Export TT File and renaming.
final class PasswordsUITests: NGTestCase {
    func row(_ prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    func testAPasswordFieldShowsItsPasswordWithItsSwitch() {
        button("Server List Actions").tap()
        button("Type its details").tap()
        let hidden = app.secureTextFields["Password"]
        waitFor(hidden, "the password, hidden")
        hidden.tap(); hidden.typeText("hunter2")
        let show = app.switches["Show password"]
        if !show.isHittable { app.swipeUp() }
        (show.switches.firstMatch.exists ? show.switches.firstMatch : show).tap()
        let shown = app.textFields["Password"]
        waitFor(shown, "the password shown")
        XCTAssertEqual(shown.value as? String, "hunter2")
        XCTAssertFalse(app.secureTextFields["Password"].exists, "not hidden any more")
    }

    func testChannelLinksCarryTheirPasswords() {
        connect("admin")
                action("Copy a Link to This Channel", on: row("Secret"))
        Host.until("the link copied") { Host.pasteboard().hasPrefix("tt://") }
        let link = Host.pasteboard()
        for part in ["username=admin", "password=admin-pw", "chanpasswd=sesame"] {
            XCTAssertTrue(link.contains(part), "\(part) in \(link)")
        }
    }

    func testAccountsCopyLinkExportAndRename() {
        connect("admin")
        more("User accounts")
        waitFor(row("carol"), "the accounts")
        XCTAssertTrue(any("password carol-pw").exists, "the password in the list")
        // Copy Link: the server, logging in with the account.
                action("Copy Link", on: row("carol"))
        Host.until("the link copied") { Host.pasteboard().hasPrefix("tt://") }
        let link = Host.pasteboard()
        XCTAssertTrue(link.contains("username=carol") && link.contains("password=carol-pw"), link)
        // Export TT File: named, then shared.
        action("Export TT File", on: row("carol"))
        let alert = app.alerts["Export TT File"]
        waitFor(alert, "the file's name")
        XCTAssertEqual(alert.textFields["File name"].value as? String, "carol")
        alert.buttons["Export"].tap()
        let shared = app.otherElements["ActivityListView"].firstMatch
        XCTAssertTrue(shared.waitForExistence(timeout: 10), "the share sheet")
        let close = shared.buttons.matching(NSPredicate(format: "label == 'Close' OR label == 'Cancel'")).firstMatch
        if close.waitForExistence(timeout: 3) { close.tap() } else { shared.swipeDown() }
        XCTAssertTrue(shared.waitForNonExistence(timeout: 5), "the share sheet closed")
        // A new account, then renamed.
        app.buttons["Add account"].tap()
        let name = app.textFields["Username"]
        waitFor(name, "the new account")
        name.tap(); name.typeText("dave")
        let pw = app.secureTextFields["Password"]
        pw.tap(); pw.typeText("dave-pw")
        button("Save").tap()
        waitFor(row("dave"), "dave listed")
        row("dave").tap()
        let username = app.textFields["Username"]
        waitFor(username, "dave's username, to change")
        replace(username, with: "david")
        button("Save").tap()
        waitFor(row("david"), "renamed to david", timeout: 20)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'dave'")).firstMatch.exists, "dave is gone")
        XCTAssertTrue(any("password dave-pw").exists, "with its password")
    }
}
