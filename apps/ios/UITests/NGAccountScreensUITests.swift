import XCTest

/// NG Account through the app's own screens, on the private service (mail
/// to an outbox the tests read): making an account with its emailed code,
/// a forgotten password reset, the password changed, another device's
/// change arriving, the session ended by the service, Sync sound packs.
/// The test plays the other device through the service's API.
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
        type(app.secureTextFields["New password"], "the second password")
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

    func testAnotherDevicesChangeArrivesAndAnEndedSessionSignsOut() {
        let email = unique("two")
        let ipad = accountMadeElsewhere(email, "two devices password")
        openAccount()
        signIn(email, "two devices password")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        button("Done").tap()

        // The iPad adds a server: it arrives here when the app comes back.
        api("POST", "v1/sync", ["changes": [["kind": "server", "key": "ipad-1", "base_rev": 0, "deleted": false, "data": [
            "name": "From the iPad", "ipaddr": "ipad.example.com", "tcpport": 10333, "udpport": 10333, "encrypted": false,
            "username": "", "nickname": "", "statusmsg": "", "channel": "", "sync_password": true, "password": "", "order": 0]]]], token: ipad)
        backgroundAndBack()
        waitFor(app.staticTexts["From the iPad"], "the iPad's server here", timeout: 20)

        // The iPad ends this iPhone's session: the app says so and stops syncing.
        let sessions = api("GET", "v1/account/sessions", token: ipad)["sessions"] as? [[String: Any]] ?? []
        let mine = sessions.first { $0["install_id"] as? String != "other-device" }
        XCTAssertNotNil(mine, "this iPhone's session: \(sessions)")
        if let id = mine?["id"] { api("DELETE", "v1/account/sessions/\(id)", token: ipad) }
        backgroundAndBack()
        // Settings once the app is back (a tap at once is lost).
        let settings = app.buttons["Settings"]
        waitFor(settings, "the app back")
        let account = app.buttons["NG Account"]
        for _ in 0..<3 where !account.waitForExistence(timeout: 2) { settings.tap() }
        if !account.waitForExistence(timeout: 3) { app.swipeUp() }
        Host.until("signed out here", timeout: 20) { account.label.contains("Not signed in") || (account.value as? String)?.contains("Not signed in") == true }
        // The servers stay.
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["From the iPad"].exists, "its servers stay")
    }

    func testSyncSoundPacksSendsTheChosenPackOnlyWhenOn() {
        let email = unique("packs")
        let ipad = accountMadeElsewhere(email, "packs password")
        func chosenOnTheAccount() -> String {
            let records = api("GET", "v1/sync?since=0", token: ipad)["records"] as? [[String: Any]] ?? []
            let r = records.first { $0["key"] as? String == "ng_selected_sound_pack" }
            return r.map { "\($0["data"] ?? "")" } ?? ""
        }
        openAccount()
        signIn(email, "packs password")
        // On: choosing a pack here reaches the account.
        let sync = app.switches["Sync sound packs"]
        XCTAssertEqual(sync.value as? String, "1", "on at first")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Sounds"].tap()
        app.buttons["Sound packs"].tap()
        button("New sound pack").tap()
        let field = app.alerts.firstMatch.textFields.firstMatch
        waitFor(field, "the new pack's name")
        field.tap(); field.typeText("Mine")
        app.alerts.firstMatch.buttons["Make"].tap()
        button("Use this pack").tap()
        Host.until("the account has it chosen", timeout: 20) { chosenOnTheAccount().contains("local:own-") }

        // Off: choosing another one stays here.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["NG Account"].tap()
        sync.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        Host.until("off") { (sync.value as? String) == "0" }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Sounds"].tap()
        app.buttons["Sound packs"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'TeamTalk (built in)'")).firstMatch.tap()
        button("Use this pack").tap()
        Thread.sleep(forTimeInterval: 4)
        XCTAssertTrue(chosenOnTheAccount().contains("local:own-"), "not sent while off: \(chosenOnTheAccount())")
    }
}
