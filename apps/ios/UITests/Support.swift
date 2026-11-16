import XCTest

/// The UI tests' world (scripts/test-ios-ui.sh): a throwaway TeamTalk
/// server with people the tests make act (crates/ttng-core/examples/
/// uitest_host.rs), on the Mac's localhost.
enum Host {
    static var env: [String: String] { ProcessInfo.processInfo.environment }
    static var ttPort: String { env["TT_PORT"] ?? "" }
    static var available: Bool { env["CONTROL_PORT"] != nil }

    /// A command to the host; its JSON answer.
    @discardableResult
    static func call(_ path: String, _ query: [String: String] = [:]) -> [String: Any] {
        var c = URLComponents(string: "http://127.0.0.1:\(env["CONTROL_PORT"] ?? "0")\(path)")!
        c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        let done = DispatchSemaphore(value: 0)
        var out: [String: Any] = [:]
        URLSession.shared.dataTask(with: c.url!) { data, _, _ in
            out = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 30)
        return out
    }

    /// What a person (bob, carol, admin) sees.
    static func state(_ bot: String = "bob") -> [String: Any] { call("/state", ["bot": bot]) }

    /// Someone as a person sees them, by nickname or username.
    static func user(_ name: String, seenBy bot: String = "bob") -> [String: Any]? {
        (state(bot)["users"] as? [[String: Any]])?.first {
            $0["nickname"] as? String == name || $0["username"] as? String == name
        }
    }

    static func messages(_ bot: String = "bob") -> [[String: Any]] { state(bot)["messages"] as? [[String: Any]] ?? [] }

    /// Waits up to `timeout` for `ok`.
    static func until(_ what: String, timeout: TimeInterval = 15, _ ok: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if ok() { return }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTFail("never: \(what)")
    }

    /// A tt:// link to the test server as `user` (password: "<user>-pw"
    /// unless given).
    static func link(_ user: String = "alice", password: String? = nil, channel: String? = nil, port: String? = nil) -> URL {
        var c = URLComponents()
        c.scheme = "tt"
        c.host = "127.0.0.1"
        let p = port ?? ttPort
        c.queryItems = [URLQueryItem(name: "tcpport", value: p), URLQueryItem(name: "udpport", value: p),
                        URLQueryItem(name: "username", value: user), URLQueryItem(name: "password", value: password ?? "\(user)-pw")]
            + (channel.map { [URLQueryItem(name: "channel", value: $0)] } ?? [])
        return c.url!
    }
}

@MainActor
class NGTestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        try XCTSkipUnless(Host.available, "run through scripts/test-ios-ui.sh")
        Host.call("/reset")
        // iOS's own permission questions (microphone, notifications): allowed.
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow", "OK", "Allow While Using App"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app = XCUIApplication()
        // A small text size: long menus (an admin's More) fit without
        // scrolling (a swipe in a menu would choose an item).
        app.launchArguments = ["-UITestReset", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXS"]
        app.launch()
    }

    /// Something whose label (or value) contains `text`.
    @MainActor
    func any(_ text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text)).firstMatch
    }

    @MainActor
    func button(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    @MainActor
    func waitFor(_ e: XCUIElement, _ what: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
        if !e.waitForExistence(timeout: timeout) {
            XCTFail("never: \(what). On screen: " + app.staticTexts.allElementsBoundByIndex.prefix(40).map { $0.label }.joined(separator: " | ")
                    + " || buttons: " + app.buttons.allElementsBoundByIndex.prefix(40).map { $0.label }.joined(separator: " | "),
                    file: file, line: line)
        }
    }

    /// Connects as `user` through a tt:// link and opens the server screen.
    @MainActor
    func connect(_ user: String = "alice") {
        app.open(Host.link(user))
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '127.0.0.1'")).firstMatch
        waitFor(row, "the server in the list")
        row.tap()
        waitFor(any("Lobby"), "the channels")
    }

    /// Dismisses a confirmation dialog without choosing (its Cancel, or a
    /// tap outside, as iOS shows it).
    func cancelDialog() {
        let cancel = button("Cancel")
        if cancel.exists { cancel.tap(); return }
        let outside = app.otherElements["PopoverDismissRegion"]
        if outside.exists { outside.tap(); return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
    }

    /// A keyboard shortcut (a hardware keyboard's). XCUITest loses the first
    /// key after its keyboard (re)connects (after launch, after a menu): a
    /// harmless Shift goes first.
    func shortcut(_ key: String, _ modifiers: XCUIElement.KeyModifierFlags) {
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey(key, modifierFlags: modifiers)
    }

    /// A shortcut until it shows (XCUITest's synthetic keys are sometimes
    /// lost, not the app's doing): up to three tries.
    func shortcut(_ key: String, _ modifiers: XCUIElement.KeyModifierFlags, until shown: XCUIElement, _ what: String) {
        for _ in 0..<3 {
            shortcut(key, modifiers)
            if shown.waitForExistence(timeout: 3) { return }
        }
        waitFor(shown, what, timeout: 1)
    }

    /// Replaces a text field's text.
    func replace(_ field: XCUIElement, with text: String) {
        field.tap()
        let old = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count + 2) + text)
    }

    /// Closes the open More menu without choosing: a tap on the screen's
    /// title (harmless) outside it.
    func closeMenu() {
        let title = app.navigationBars.firstMatch.staticTexts.firstMatch
        if title.exists { title.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap() }
        Host.until("the menu closed", timeout: 5) { !self.button("Disconnect").exists }
    }

    /// The server screen's More menu, then one of its items.
    @MainActor
    func more(_ item: String) {
        app.buttons["More"].tap()
        let b = button(item)
        waitFor(b, "\(item) in the More menu", timeout: 5)
        b.tap()
    }

    /// A row's VoiceOver action (its actions list) by name.
    @MainActor
    /// Runs an action as Siri would, and waits for what it says.
    /// A debug-only test action (teamtalkng://uitest-action), through the
    /// system (app.open would start the app afresh).
    func run(_ action: String, _ params: [String: String] = [:], says expected: String, file: StaticString = #filePath, line: UInt = #line) {
        var c = URLComponents()
        c.scheme = "teamtalkng"
        c.host = "uitest-action"
        c.queryItems = [URLQueryItem(name: "do", value: action)] + params.map { URLQueryItem(name: $0.key, value: $0.value) }
        // Through the system (app.open would start the app afresh).
        XCUIDevice.shared.system.open(c.url!)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let openButton = springboard.buttons["Open"]
        if openButton.waitForExistence(timeout: 2) { openButton.tap() }
        let said = app.staticTexts.matching(NSPredicate(format: "identifier == 'uitest-action-result' AND label BEGINSWITH %@", expected)).firstMatch
        waitFor(said, "\(action) saying \(expected)", file: file, line: line)
    }

    func action(_ name: String, on e: XCUIElement) {
        e.press(forDuration: 1.2)
        let b = button(name)
        waitFor(b, "the \(name) action", timeout: 5)
        b.tap()
    }
}
