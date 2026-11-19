import XCTest

/// NG Account through the app's own screens, on the private service (mail
/// to an outbox the tests read): making an account with its emailed code,
/// a forgotten password reset, the password changed. (NG Account is only
/// for publishing sound packs now.) The test plays another device through
/// the service's API.
final class NGAccountScreensUITests: NGTestCase {
    var service: URL { URL(string: ProcessInfo.processInfo.environment["NG_URL"] ?? "")! }
    var outbox: String { ProcessInfo.processInfo.environment["NG_OUTBOX"] ?? "" }

    // MARK: The service, as another device

    @discardableResult
    func api(_ method: String, _ path: String, _ body: [String: Any]? = nil, token: String? = nil) -> [String: Any] {
        var req = URLRequest(url: URL(string: service.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + path)!)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { req.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        let sem = DispatchSemaphore(value: 0)
        var out: [String: Any] = [:]
        URLSession.shared.dataTask(with: req) { d, _, _ in
            out = d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            sem.signal()
        }.resume()
        sem.wait()
        return out
    }

    /// The newest code emailed to `email` (after `after`, a count of mails).
    func code(_ email: String, after: Int = 0, file: StaticString = #filePath, line: UInt = #line) -> String {
        for _ in 0..<100 {
            let mails = mailsTo(email)
            if mails.count > after, let c = mails.last?["code"] as? String { return c }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTFail("no code emailed to \(email)", file: file, line: line)
        return ""
    }

    func mailsTo(_ email: String) -> [[String: Any]] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: outbox)) ?? []).sorted()
        return names.compactMap { n in
            (try? Data(contentsOf: URL(fileURLWithPath: outbox).appendingPathComponent(n)))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }.filter { $0["to"] as? String == email }
    }

    /// An account made through the API (another device's), its token.
    func accountMadeElsewhere(_ email: String, _ password: String) -> String {
        api("POST", "v1/account/signup", ["email": email, "password": password])
        let s = api("POST", "v1/account/verify", ["email": email, "code": code(email), "install_id": "other-device", "device_name": "iPad"])
        return s["token"] as? String ?? ""
    }

    // MARK: The app's screens

    func openAccount() {
        app.buttons["Settings"].tap()
        let account = app.buttons["NG Account"]
        if !account.waitForExistence(timeout: 3) { app.swipeUp() }
        account.tap()
        waitFor(app.textFields["Email"], "the NG Account form")
    }

    func type(_ field: XCUIElement, _ text: String) {
        waitFor(field, field.label)
        field.tap()
        field.typeText(text)
    }

    func signIn(_ email: String, _ password: String) {
        type(app.textFields["Email"], email)
        type(app.secureTextFields["Password"], password)
        let segment = app.segmentedControls.buttons["Sign in"]
        (app.buttons.matching(NSPredicate(format: "label == 'Sign in'")).allElementsBoundByIndex.first { $0.frame != segment.frame })?.tap()
        waitFor(app.staticTexts["Signed in as"], "signed in", timeout: 20)
    }

    func unique(_ name: String) -> String { "\(name)-\(UUID().uuidString.prefix(6).lowercased())@example.com" }

    /// To the background and back (the app syncs on coming back).
    func backgroundAndBack() {
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        app.activate()
    }

    // MARK: Tests

    func testMakingAnAccountWithItsEmailedCode() {
        let email = unique("new")
        openAccount()
        app.segmentedControls.buttons["Make an account"].tap()
        type(app.textFields["Email"], email)
        type(app.secureTextFields["Password"], "a new account password")
        button("Make the account").tap()
        waitFor(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'We emailed a code to'")).firstMatch, "asked for the code", timeout: 15)
        // A wrong code is refused (said), and the right one finishes.
        type(app.textFields["Code"], "000000")
        button("Finish").tap()
        waitFor(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'That code is not right'")).firstMatch, "the wrong code refused, said")
        replace(app.textFields["Code"], with: code(email))
        button("Finish").tap()
        waitFor(app.staticTexts["Signed in as"], "signed in to the new account", timeout: 20)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", email, email)).firstMatch.exists)
    }

    func testAForgottenPasswordIsResetThenChanged() {
        let email = unique("forgot")
        _ = accountMadeElsewhere(email, "the first password")
        let mailsBefore = mailsTo(email).count
        openAccount()
        button("Forgot password").tap()
        type(app.textFields["Email"], email)
        button("Email me a code").tap()
        waitFor(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Type the code we emailed'")).firstMatch, "the reset step", timeout: 15)
        type(app.textFields["Code"], code(email, after: mailsBefore))
        // Shown (the Simulator loses keys typed into a hidden new password).
        let show = app.switches["Show password"]
        let knob = show.switches.firstMatch
        (knob.exists ? knob : show).tap()
        type(app.textFields["New password"], "the second password")
        button("Set password and sign in").tap()
        waitFor(app.staticTexts["Signed in as"], "signed in with the new password", timeout: 20)
        XCTAssertNotNil(api("POST", "v1/account/signin", ["email": email, "password": "the second password", "install_id": "check", "device_name": "Check"])["token"],
                        "the new password works")

        // Changed (the current one asked for).
        button("Change password").tap()
        type(app.secureTextFields["Current password"], "the second password")
        type(app.secureTextFields["New password"], "the third password")
        button("Change").tap()
        waitFor(app.staticTexts["Signed in as"], "back on the account", timeout: 15)
        Host.until("the changed password works", timeout: 15) {
            self.api("POST", "v1/account/signin", ["email": email, "password": "the third password", "install_id": "check2", "device_name": "Check"])["token"] != nil
        }
        XCTAssertNil(api("POST", "v1/account/signin", ["email": email, "password": "the second password", "install_id": "check3", "device_name": "Check"])["token"],
                     "the old one doesn't")
    }

    /// Deleting the account in the app (Apple requires it): its password
    /// asked for (a wrong one refused, said), its packs taken out too, and
    /// then the account and its sessions are gone.
    func testDeletingTheAccountAndItsPacks() {
        let email = unique("leaving")
        let token = accountMadeElsewhere(email, "the leaving password")
        let pack = api("POST", "v1/packs", ["local_id": "leaving-pack", "name": "Leaving pack"], token: token)["id"] as? String
        XCTAssertNotNil(pack, "a pack of the account's")
        openAccount()
        signIn(email, "the leaving password")
        let delete = button("Delete NG Account")
        for _ in 0..<3 where !delete.isHittable { app.swipeUp() }
        delete.tap()
        waitFor(app.navigationBars["Delete NG Account"], "asked to confirm")
        XCTAssertTrue(app.switches["Take my packs out of the catalog"].exists, "taking the packs out offered")
        // Shown (the Simulator loses keys typed into a hidden password).
        let show = app.switches["Show password"]
        let knob = show.switches.firstMatch
        (knob.exists ? knob : show).tap()
        type(app.textFields["Password"], "not the password")
        app.navigationBars["Delete NG Account"].buttons["Delete"].tap()
        waitFor(any("That password isn't right"), "a wrong password refused, said", timeout: 15)
        XCTAssertNotNil(api("POST", "v1/account/signin", ["email": email, "password": "the leaving password", "install_id": "check", "device_name": "Check"])["token"],
                        "still there after the wrong password")
        replace(app.textFields["Password"], with: "the leaving password")
        app.navigationBars["Delete NG Account"].buttons["Delete"].tap()
        waitFor(app.textFields["Email"], "signed out: the sign-in form again", timeout: 20)
        let signIn = api("POST", "v1/account/signin", ["email": email, "password": "the leaving password", "install_id": "check2", "device_name": "Check"])
        XCTAssertNil(signIn["token"], "the account is gone: \(signIn)")
        XCTAssertNil(api("GET", "v1/packs", token: token)["packs"], "its other sessions ended too")
    }
}
