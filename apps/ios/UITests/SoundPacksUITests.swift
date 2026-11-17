import XCTest

/// Sound packs: made, edited (each sound, name and author), used,
/// duplicated, exported, deleted; the built-in pack edited through a copy;
/// published to the catalog of a private NG service, then withdrawn.
final class SoundPacksUITests: NGTestCase {
    func openPacks() {
        app.buttons["Settings"].tap()
        let sounds = app.buttons["Sounds"]
        if !sounds.waitForExistence(timeout: 3) { app.swipeUp() }
        sounds.tap()
        app.buttons["Sound packs"].tap()
        waitFor(app.navigationBars["Sound packs"], "Sound packs")
    }

    func newPack(_ name: String) {
        button("New sound pack").tap()
        let field = app.alerts.firstMatch.textFields.firstMatch
        waitFor(field, "the new pack's name")
        field.tap(); field.typeText(name)
        app.alerts.firstMatch.buttons["Make"].tap()
        waitFor(app.navigationBars[name], "\(name)'s screen")
    }

    func soundRow(_ prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    func reveal(_ e: XCUIElement) {
        let bottom = app.windows.firstMatch.frame.maxY - 120
        var swiped = false
        // The list itself (a swipe on a text field moves its cursor instead).
        let list = app.collectionViews.firstMatch
        for _ in 0..<12 where !(e.exists && e.isHittable && e.frame.maxY < bottom) { list.swipeUp(); swiped = true }
        if swiped { Thread.sleep(forTimeInterval: 1.5) }
    }

    func testMakeEditUseDuplicateExportAndDelete() {
        openPacks()
        newPack("Test pack")
        // New: every sound is the built-in one.
        waitFor(soundRow("User logged in, the built-in sound"), "the built-in sound at first")
        // A sound chosen for it (as the file picker would).
        run("packSound", ["pack": "Test pack", "event": "logged_on"], says: "Sound set")
        waitFor(soundRow("User logged in, from this pack"), "the pack's own sound")
        // Back to the built-in one (its action), then chosen again.
        action("Use the built-in sound", on: soundRow("User logged in, from this pack"))
        waitFor(soundRow("User logged in, the built-in sound"), "the built-in sound again")
        run("packSound", ["pack": "Test pack", "event": "logged_on"], says: "Sound set")
        waitFor(soundRow("User logged in, from this pack"), "its own sound again")
        // Its author.
        let author = app.textFields["Author"]
        replace(author, with: "Tester")
        // The keyboard's Done puts it away.
        app.toolbars.buttons["Done"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 1) && app.keyboards.firstMatch.isHittable, "the keyboard away")
        // Used.
        button("Use this pack").tap()
        waitFor(any("In use"), "in use")

        // Duplicated: the copy has its sound.
        let duplicate = button("Duplicate")
        reveal(duplicate)
        duplicate.tap()
        waitFor(app.navigationBars["Test pack copy"], "the copy's screen")
        waitFor(soundRow("User logged in, from this pack"), "the copy has the sound")

        // Exported: the share sheet with a zip.
        let export = button("Export and share")
        reveal(export)
        export.tap()
        let shared = app.otherElements["ActivityListView"].firstMatch
        let anyShare = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Test pack copy'")).firstMatch
        XCTAssertTrue(shared.waitForExistence(timeout: 10) || anyShare.waitForExistence(timeout: 5), "the share sheet")
        let close = app.buttons.matching(NSPredicate(format: "label == 'Close' OR label == 'Cancel'")).firstMatch
        if close.waitForExistence(timeout: 3) { close.tap() } else { app.swipeDown() }

        // Deleted (asked first): gone from the list.
        let delete = button("Delete sound pack")
        reveal(delete)
        delete.tap()
        app.buttons.matching(NSPredicate(format: "label == 'Delete'")).allElementsBoundByIndex.last!.tap()
        waitFor(app.navigationBars["Test pack"], "back on the pack it came from")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        Host.until("the copy gone from the list") {
            !self.app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Test pack copy'")).firstMatch.exists
        }
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Test pack, yours, in use'")).firstMatch.exists)
    }

    /// "Choose a sound file" through the real file picker: the file chosen
    /// becomes the pack's sound for that event.
    func testChooseASoundFileThroughThePicker() {
        run("placeSoundFile", [:], says: "Sound file placed")
        openPacks()
        newPack("Picked pack")
        let row = soundRow("User logged in, the built-in sound")
        waitFor(row, "the sound")
        row.press(forDuration: 1.2)
        button("Choose a sound file").tap()
        // The picker: Browse, On My iPhone, the app's folder, the file.
        let browse = app.buttons["Browse"]
        waitFor(browse, "the file picker")
        browse.tap()
        if browse.isHittable { browse.tap() }  // a second tap goes to its top
        let onPhone = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'On My iPhone'")).firstMatch
        waitFor(onPhone, "On My iPhone")
        onPhone.tap()
        let folder = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'TTNG Dev'")).firstMatch
        waitFor(folder, "the app's folder")
        folder.tap()
        let file = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Picked sound'")).firstMatch
        waitFor(file, "the sound file")
        file.tap()
        waitFor(soundRow("User logged in, from this pack"), "the chosen file as the pack's sound")
    }

    func testTheBuiltInPackIsEditedThroughACopy() {
        openPacks()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'TeamTalk (built in)'")).firstMatch.tap()
        waitFor(soundRow("User logged in, built in"), "the built-in pack's sounds")
        // No editing on it: only playing.
        soundRow("User logged in, built in").press(forDuration: 1.2)
        waitFor(button("Play"), "its Play")
        XCTAssertFalse(button("Choose a sound file").exists, "the built-in pack isn't edited")
        app.navigationBars.firstMatch.tap()
        let copy = button("Make an editable copy")
        reveal(copy)
        copy.tap()
        waitFor(app.navigationBars["TeamTalk (built in) (my copy)"], "the copy")
        soundRow("User logged in, the built-in sound").press(forDuration: 1.2)
        waitFor(button("Choose a sound file"), "the copy is edited")
    }

    func testPublishedToTheCatalogAndWithdrawn() throws {
        let env = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(env["NG_EMAIL"]), password = try XCTUnwrap(env["NG_PASSWORD"])
        let service = try XCTUnwrap(env["NG_URL"].flatMap(URL.init(string:)))
        // Signed in to NG Account (the private service).
        app.buttons["Settings"].tap()
        let account = app.buttons["NG Account"]
        if !account.waitForExistence(timeout: 3) { app.swipeUp() }
        account.tap()
        let emailField = app.textFields["Email"]
        waitFor(emailField, "the sign-in form")
        emailField.tap(); emailField.typeText(email)
        let pw = app.secureTextFields["Password"]
        pw.tap(); pw.typeText(password)
        let segment = app.segmentedControls.buttons["Sign in"]
        (app.buttons.matching(NSPredicate(format: "label == 'Sign in'")).allElementsBoundByIndex.first { $0.frame != segment.frame })?.tap()
        waitFor(app.staticTexts["Signed in as"], "signed in", timeout: 20)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let sounds = app.buttons["Sounds"]
        if !sounds.waitForExistence(timeout: 3) { app.swipeDown() }
        sounds.tap()
        app.buttons["Sound packs"].tap()

        newPack("Shared pack")
        run("packSound", ["pack": "Shared pack", "event": "logged_on"], says: "Sound set")
        let publish = button("Publish to the catalog")
        reveal(publish)
        publish.tap()
        replace(app.textFields["Author"], with: "Tester")
        button("Publish").tap()
        let withdraw = button("Withdraw from the catalog")
        waitFor(withdraw, "published", timeout: 30)

        func inCatalog() -> Bool {
            let sem = DispatchSemaphore(value: 0)
            var found = false
            URLSession.shared.dataTask(with: service.appendingPathComponent("v1/catalog")) { d, _, _ in
                if let d, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   let packs = o["packs"] as? [[String: Any]] {
                    found = packs.contains { $0["name"] as? String == "Shared pack" && $0["author"] as? String == "Tester" }
                }
                sem.signal()
            }.resume()
            sem.wait()
            return found
        }
        Host.until("in the catalog with its name and author", timeout: 15) { inCatalog() }

        reveal(withdraw)
        withdraw.tap()
        waitFor(button("Publish to the catalog"), "withdrawn", timeout: 30)
        Host.until("out of the catalog", timeout: 15) { !inCatalog() }
    }
}
