import XCTest

/// Sound packs: made, edited (each sound, name and author), used,
/// duplicated, exported, deleted; the built-in pack edited through a copy;
/// published to the catalog of a private NG service, then withdrawn.
final class SoundPacksUITests: NGTestCase {
    func openPacks() {
        app.buttons["Settings"].tap()
        let sounds = app.buttons["Sound Events"]
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
        let browse = app.buttons.matching(identifier: "Browse").firstMatch
        waitFor(browse, "the file picker")
        browse.tap()
        if browse.isHittable { browse.tap() }  // a second tap goes to its top
        let onPhone = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'On My iPhone'")).firstMatch
        waitFor(onPhone, "On My iPhone")
        onPhone.tap()
        let folder = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'TeamTalk NG'")).firstMatch
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
        let catalogURL = try XCTUnwrap(env["CATALOG_URL"].flatMap(URL.init(string:)))
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
        let sounds = app.buttons["Sound Events"]
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
            // The static packs.json the app reads (written by the service).
            URLSession.shared.dataTask(with: catalogURL) { d, _, _ in
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

    /// My own published pack, downloaded from the catalog (as after deleting
    /// it here, or on another device signed in): still mine to manage —
    /// withdraw it, or edit it as my pack again (updating the same one);
    /// and NG Account lists it to withdraw without it on the phone.
    func testMyPackDownloadedFromTheCatalogIsStillMine() throws {
        let env = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(env["NG_EMAIL"]), password = try XCTUnwrap(env["NG_PASSWORD"])
        let token = try XCTUnwrap(api("POST", "v1/account/signin", json: ["email": email, "password": password, "install_id": "other-phone", "device_name": "Other phone"])["token"] as? String)
        let name = "Mine again \(UUID().uuidString.prefix(4))"
        let localId = "imported-\(UUID().uuidString.prefix(8).lowercased())"
        let pack = try XCTUnwrap(api("POST", "v1/packs", json: ["local_id": localId, "name": name], token: token)["id"] as? String)
        var wav = Data("RIFF".utf8) + Data([0x24, 0, 0, 0]) + Data("WAVEfmt ".utf8)
        wav.append(Data(count: 2000))
        api("PUT", "v1/packs/\(pack)/files/logged_on.wav", raw: wav, token: token)
        api("PATCH", "v1/packs/\(pack)", json: ["name": name, "author": "Me", "public": true], token: token)

        // This iPhone, signed in to the same account.
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
        // NG Account lists it, though it isn't on this iPhone.
        let listed = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        for _ in 0..<3 where !listed.waitForExistence(timeout: 3) { app.swipeUp() }
        waitFor(listed, "my pack under Your packs in the catalog")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Downloaded from the catalog.
        let sounds = app.buttons["Sound Events"]
        if !sounds.waitForExistence(timeout: 3) { app.swipeDown() }
        sounds.tap()
        button("Get sound packs").tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        for _ in 0..<10 where !row.waitForExistence(timeout: 2) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            button("Get sound packs").tap()
        }
        waitFor(row, "my pack in Get sound packs")
        row.tap()
        Host.until("downloaded", timeout: 30) { row.label.contains("downloaded") }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        button("Sound packs").tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch.tap()
        // Still mine: withdraw it, or edit it as mine.
        let withdraw = button("Withdraw from the catalog")
        reveal(withdraw)
        waitFor(withdraw, "withdrawing offered on the downloaded copy", timeout: 15)
        let edit = button("Edit my pack")
        reveal(edit)
        edit.tap()
        let update = button("Update it in the catalog")
        reveal(update)
        waitFor(update, "edited as my pack: updating the same one", timeout: 15)
        XCTAssertFalse(button("Publish to the catalog").exists, "not a new pack")
        // Withdrawn from here: gone for everyone.
        let withdrawMine = button("Withdraw from the catalog")
        reveal(withdrawMine)
        withdrawMine.tap()
        waitFor(button("Publish to the catalog"), "withdrawn", timeout: 30)
        let left = api("GET", "v1/packs", token: token)["packs"] as? [[String: Any]] ?? []
        XCTAssertFalse(left.contains { $0["id"] as? String == pack }, "gone from the service")
    }

    /// A JSON call to the private service.
    @discardableResult
    private func api(_ method: String, _ path: String, json: [String: Any]? = nil, raw: Data? = nil, token: String? = nil) -> [String: Any] {
        let base = URL(string: Host.env["NG_URL"] ?? "")!
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        } else if let raw {
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.httpBody = raw
        }
        let sem = DispatchSemaphore(value: 0)
        var out: [String: Any] = [:]
        URLSession.shared.dataTask(with: req) { d, _, _ in
            out = d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            sem.signal()
        }.resume()
        sem.wait()
        return out
    }

    /// A pack someone published shows in Get sound packs (the catalog's
    /// packs.json), and downloads from there: its zip, checked, unpacked,
    /// in use.
    func testDownloadingAPackFromTheCatalog() throws {
        let env = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(env["NG_EMAIL"]), password = try XCTUnwrap(env["NG_PASSWORD"])
        let token = try XCTUnwrap(api("POST", "v1/account/signin", json: ["email": email, "password": password, "install_id": "publisher", "device_name": "Publisher"])["token"] as? String)
        let pack = try XCTUnwrap(api("POST", "v1/packs", json: ["local_id": "catalog-test-\(UUID().uuidString.prefix(6))", "name": "Catalog pack"], token: token)["id"] as? String)
        var wav = Data("RIFF".utf8) + Data([0x24, 0, 0, 0]) + Data("WAVEfmt ".utf8)
        wav.append(Data(count: 2000))
        api("PUT", "v1/packs/\(pack)/files/logged_on.wav", raw: wav, token: token)
        api("PATCH", "v1/packs/\(pack)", json: ["name": "Catalog pack", "author": "Someone", "description": "From the catalog", "public": true], token: token)

        app.buttons["Settings"].tap()
        let sounds = app.buttons["Sound Events"]
        if !sounds.waitForExistence(timeout: 3) { app.swipeUp() }
        sounds.tap()
        button("Get sound packs").tap()
        // packs.json is written within seconds: look again until it's there.
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Catalog pack'")).firstMatch
        for _ in 0..<10 where !row.waitForExistence(timeout: 2) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            button("Get sound packs").tap()
        }
        waitFor(row, "the published pack in Get sound packs")
        XCTAssertTrue(row.label.contains("By Someone"), row.label)
        row.tap()
        Host.until("downloaded and in use", timeout: 30) { row.label.contains("downloaded") }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        button("Sound packs").tap()
        waitFor(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Catalog pack'")).firstMatch, "listed among my packs")
    }

    /// Someone else's pack in the catalog: reported (no account needed,
    /// a reason chosen), its publisher blocked (their packs hidden, said),
    /// then unblocked under Blocked publishers. The contact is there too.
    func testReportingAPackAndBlockingItsPublisher() throws {
        let env = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(env["NG_EMAIL"]), password = try XCTUnwrap(env["NG_PASSWORD"])
        let token = try XCTUnwrap(api("POST", "v1/account/signin", json: ["email": email, "password": password, "install_id": "publisher", "device_name": "Publisher"])["token"] as? String)
        let author = "Author \(UUID().uuidString.prefix(4))"
        let name = "Reported pack \(UUID().uuidString.prefix(4))"
        let pack = try XCTUnwrap(api("POST", "v1/packs", json: ["local_id": "report-test-\(UUID().uuidString.prefix(6))", "name": name], token: token)["id"] as? String)
        var wav = Data("RIFF".utf8) + Data([0x24, 0, 0, 0]) + Data("WAVEfmt ".utf8)
        wav.append(Data(count: 2000))
        api("PUT", "v1/packs/\(pack)/files/logged_on.wav", raw: wav, token: token)
        api("PATCH", "v1/packs/\(pack)", json: ["name": name, "author": author, "public": true], token: token)

        app.buttons["Settings"].tap()
        let sounds = app.buttons["Sound Events"]
        if !sounds.waitForExistence(timeout: 3) { app.swipeUp() }
        sounds.tap()
        button("Get sound packs").tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        for _ in 0..<10 where !row.waitForExistence(timeout: 2) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            button("Get sound packs").tap()
        }
        waitFor(row, "the pack in Get sound packs")
        // Who to write to about a pack.
        let contact = app.buttons["Contact TeamTalk NG"]
        for _ in 0..<3 where !contact.exists { app.swipeUp() }
        XCTAssertTrue(contact.exists, "the contact offered")
        XCTAssertTrue(any("mattdovi@icloud.com").exists, "the address said")

        // Reported, with a reason: thanked.
        run("announced", says: "Announced")
        action("Report this pack", on: row)
        let reason = app.buttons["It's offensive or abusive"]
        waitFor(reason, "the reasons to choose from")
        reason.tap()
        Thread.sleep(forTimeInterval: 2)
        run("announced", says: "Announced: \(name) reported. Thank you.")

        // Its publisher blocked: hidden, said; then unblocked.
        action("Block \(author)", on: row)
        let block = app.buttons.matching(NSPredicate(format: "label == 'Block'")).allElementsBoundByIndex.last { $0.isHittable }
        try XCTUnwrap(block, "asked to confirm").tap()
        Host.until("the pack hidden", timeout: 10) { !row.exists }
        XCTAssertTrue(any("Packs by publishers you blocked are hidden.").exists, "said that some are hidden")
        let blocked = app.buttons["Blocked publishers"]
        for _ in 0..<3 where !blocked.isHittable { app.swipeUp() }
        blocked.tap()
        let who = app.buttons[author]
        waitFor(who, "the publisher listed as blocked")
        who.tap()
        Host.until("unblocked", timeout: 10) { !who.exists }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        waitFor(row, "the pack shown again")
        api("DELETE", "v1/packs/\(pack)", token: token)
    }

    /// A pack from a link to its .zip: downloaded and imported.
    func testImportingAPackFromALink() {
        let link = Host.env["PACK_URL"] ?? ""
        guard !link.isEmpty else { return XCTFail("no local web server (run through scripts/test-ios-ui.sh)") }
        openPacks()
        button("Import a sound pack from a link").tap()
        let field = app.alerts.firstMatch.textFields["Link to a .zip"]
        waitFor(field, "the link box again")
        field.tap(); field.typeText(link)
        app.alerts.firstMatch.buttons["Import"].tap()
        waitFor(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Link pack'")).firstMatch, "the downloaded pack listed", timeout: 30)
    }
}
