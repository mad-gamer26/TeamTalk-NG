import XCTest

/// Not part of the suite: signs a Simulator in to a test Apple Account
/// through its Settings app (Apple has no command for it). Runs only with
/// ICLOUD_LOGIN pointing at a private JSON file {"email", "password"} on
/// the Mac; it writes what's on screen to ICLOUD_SCREEN and, when Apple
/// asks for a verification code, waits for one in ICLOUD_CODE.
@MainActor
final class ICloudSignInUITests: XCTestCase {
    func testSignInToTheTestAppleAccount() throws {
        let env = ProcessInfo.processInfo.environment
        guard let loginPath = env["ICLOUD_LOGIN"], !loginPath.isEmpty else { throw XCTSkip("not asked to sign in") }
        let login = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: loginPath))) as? [String: String])
        let email = try XCTUnwrap(login["email"]), password = try XCTUnwrap(login["password"])
        let screenFile = URL(fileURLWithPath: env["ICLOUD_SCREEN"] ?? "/tmp/icloud-screen.txt")
        let codeFile = URL(fileURLWithPath: env["ICLOUD_CODE"] ?? "/tmp/icloud-code.txt")
        let s = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        s.launch()
        var log = ""
        func note(_ step: String) {
            // Labels only (never the password): what's on screen at this step.
            // One snapshot of the screen (asking item by item was far too
            // slow), without the keyboard's keys.
            let labels = screenLabels().prefix(60)
            log += "== \(step)\n" + labels.joined(separator: " | ") + "\n"
            try? log.write(to: screenFile, atomically: true, encoding: .utf8)
        }
        func screenLabels() -> [String] {
            guard let snap = try? s.snapshot() else { return [] }
            var out: [String] = []
            func walk(_ e: XCUIElementSnapshot) {
                if e.elementType == .keyboard || e.elementType == .key { return }
                if !e.label.isEmpty { out.append("\(e.elementType.rawValue):\(e.label)") }
                for c in e.children { walk(c) }
            }
            walk(snap)
            return out
        }
        func tapFirst(_ labels: [String], timeout: TimeInterval = 8) -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                for l in labels {
                    for q in [s.buttons, s.cells, s.staticTexts, s.links] {
                        let e = q.matching(NSPredicate(format: "label CONTAINS[c] %@", l)).firstMatch
                        if e.exists && e.isHittable { e.tap(); return true }
                    }
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
            return false
        }
        note("Settings")
        XCTAssertTrue(tapFirst(["Sign in to your", "Apple Account", "Sign In"]), "the sign-in cell")
        Thread.sleep(forTimeInterval: 3)
        note("after the sign-in cell")
        _ = tapFirst(["Sign in Manually", "Use Another", "Other Options"], timeout: 4)
        let emailField = s.textFields.firstMatch
        XCTAssertTrue(emailField.waitForExistence(timeout: 15), "the email field")
        emailField.tap()
        emailField.typeText(email)
        note("email typed")
        // The keyboard's Continue (Return) submits the email.
        emailField.typeText("\n")
        var pw = s.secureTextFields.firstMatch
        for i in 0..<12 where !pw.exists {
            Thread.sleep(forTimeInterval: 2)
            note("after the email, \(i * 2)s")
            if !s.secureTextFields.firstMatch.exists {
                let byLabel = s.textFields.matching(NSPredicate(format: "label CONTAINS[c] 'password' OR placeholderValue CONTAINS[c] 'password'")).firstMatch
                if byLabel.exists { pw = byLabel; break }
            }
            pw = s.secureTextFields.firstMatch
        }
        XCTAssertTrue(pw.exists, "the password field")
        pw.tap()
        pw.typeText(password)
        note("password typed")
        pw.typeText("\n")
        // Then whatever Apple asks: a verification code (from the owner),
        // terms, merging; written down as it goes.
        let end = Date().addingTimeInterval(600)
        var codeTyped = false
        while Date() < end {
            Thread.sleep(forTimeInterval: 3)
            note("waiting")
            let all = screenLabels().joined(separator: " ")
            if !codeTyped, all.localizedCaseInsensitiveContains("verification code") || all.localizedCaseInsensitiveContains("Enter code") {
                if let code = (try? String(contentsOf: codeFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines), code.count == 6 {
                    s.typeText(code)
                    codeTyped = true
                    note("code typed")
                    try? FileManager.default.removeItem(at: codeFile)
                }
                continue
            }
            if tapFirst(["Agree", "Don't Merge", "Not Now", "Skip"], timeout: 1) { note("answered a question"); continue }
            if all.contains(email) || all.localizedCaseInsensitiveContains("Sign Out") { note("signed in"); return }
        }
        XCTFail("not signed in after ten minutes; see \(screenFile.path)")
    }
}
