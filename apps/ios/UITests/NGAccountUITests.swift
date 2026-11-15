import XCTest

/// NG Account through the app itself, as a person uses it (VoiceOver's
/// labels): sign in, the account's server arrives, a server added here
/// goes to the account, sign out. scripts/test-ng-account-ui.sh runs it
/// against a private copy of the service with an account and a server.
@MainActor
final class NGAccountUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testSignInSyncAndSignOut() throws {
        let email = try XCTUnwrap(env["NG_EMAIL"], "run through scripts/test-ng-account-ui.sh")
        let password = try XCTUnwrap(env["NG_PASSWORD"])
        let app = XCUIApplication()
        app.launch()

        // A fresh install: the welcome sheet first.
        if app.navigationBars["Welcome to TeamTalk NG"].waitForExistence(timeout: 5) {
            app.buttons["Done"].tap()
        }

        // Settings → NG Account → sign in.
        app.buttons["Settings"].tap()
        let account = app.buttons["NG Account"]
        if !account.waitForExistence(timeout: 3) { app.swipeUp() }
        account.tap()
        let emailField = app.textFields["Email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 5))
        emailField.tap()
        emailField.typeText(email)
        let passwordField = app.secureTextFields["Password"]
        passwordField.tap()
        passwordField.typeText(password)
        // The form's button (the picker above has a "Sign in" segment too).
        let signIns = app.buttons.matching(NSPredicate(format: "label == 'Sign in'")).allElementsBoundByIndex
        let segment = app.segmentedControls.buttons["Sign in"]
        (signIns.first { $0.frame != segment.frame } ?? signIns[0]).tap()
        if !app.staticTexts["Signed in as"].waitForExistence(timeout: 20) {
            let fields = app.textFields.allElementsBoundByIndex.map { "\($0.label)=\(String(describing: $0.value))" }
            let buttons = app.buttons.allElementsBoundByIndex.map { "\($0.label)(\($0.isEnabled ? "on" : "off"))" }
            XCTFail("not signed in; texts: " + app.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: " | ")
                    + " fields: \(fields) buttons: \(buttons)")
        }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", email)).firstMatch.exists
                      || app.descendants(matching: .any).matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", email, email)).firstMatch.exists,
                      "shows the account")

        // Back to the servers: the account's server has arrived.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Seeded Server"].waitForExistence(timeout: 20), "the account's server is in the list")

        // A server added here goes to the account.
        app.buttons["Add server"].tap()
        app.buttons["Type its details"].tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Typed Server")
        let address = app.textFields["Address"]
        address.tap()
        address.typeText("typed.example.com")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Typed Server"].waitForExistence(timeout: 5))
        // Synced (the script checks the account has it).
        app.buttons["Settings"].tap()
        app.buttons["NG Account"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Synced'")).firstMatch.waitForExistence(timeout: 20),
                      "a sync after adding it")

        // Sign out: back to the sign-in form; the servers stay.
        app.buttons["Sign out"].firstMatch.tap()
        // The confirmation's own button (the form's is covered by it).
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Sign out'"))
        XCTAssertTrue(confirm.element(boundBy: 1).waitForExistence(timeout: 5), "asked to confirm")
        let hittable = confirm.allElementsBoundByIndex.first { $0.isHittable }
        try XCTUnwrap(hittable, "the confirmation's button").tap()
        XCTAssertTrue(app.textFields["Email"].waitForExistence(timeout: 10), "signed out")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Typed Server"].exists && app.staticTexts["Seeded Server"].exists, "the servers stay on the iPhone")
    }
}
