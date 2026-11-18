import XCTest

/// NG Account through the app itself, as a person uses it (VoiceOver's
/// labels): sign in (it's for publishing sound packs; servers sync through
/// iCloud), sign out. scripts/test-ios-ui.sh runs it against a private
/// copy of the service with an account.
@MainActor
final class NGAccountUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testSignInAndSignOut() throws {
        let email = try XCTUnwrap(env["NG_EMAIL"], "run through scripts/test-ios-ui.sh")
        let password = try XCTUnwrap(env["NG_PASSWORD"])
        let app = XCUIApplication()
        app.launchArguments = ["-UITestReset"]
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

        // What it's for now: publishing sound packs, not syncing servers.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'publishing sound packs'")).firstMatch.exists, "says it's for publishing packs")
        XCTAssertFalse(app.buttons["Sync now"].exists, "no server sync")

        // Sign out: back to the sign-in form.
        app.buttons["Sign out"].firstMatch.tap()
        // The confirmation's own button (the form's is covered by it).
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Sign out'"))
        XCTAssertTrue(confirm.element(boundBy: 1).waitForExistence(timeout: 5), "asked to confirm")
        let hittable = confirm.allElementsBoundByIndex.first { $0.isHittable }
        try XCTUnwrap(hittable, "the confirmation's button").tap()
        XCTAssertTrue(app.textFields["Email"].waitForExistence(timeout: 10), "signed out")
    }
}
