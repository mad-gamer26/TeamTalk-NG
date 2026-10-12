/*
 * The NG Account screens: signing up and in, the account (what syncs,
 * devices, password, export, signing out, deleting), and publishing a
 * sound pack.
 */

import UIKit

/// The NG Account screen, in Settings.
final class NGAccountViewController: UITableViewController {
    private enum Row {
        case signIn, createAccount
        case email, changePassword
        case sync(NGAccountCenter.Category)
        case devices, export, signOut, delete
    }

    private var sections: [(title: String?, footer: String?, rows: [Row])] = []

    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        CompactUI.apply(to: self, title: NSLocalizedString("NG Account", comment: "ng account"))
        CompactUI.apply(to: tableView)
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: .ngAccountChanged, object: nil)
        rebuild()
    }

    @objc private func changed() {
        rebuild()
    }

    private func rebuild() {
        let center = NGAccountCenter.shared
        if center.isSignedIn {
            sections = [
                (nil, nil, [.email, .changePassword]),
                (NSLocalizedString("Sync", comment: "ng account"),
                 NSLocalizedString("What your NG Account keeps in step on every iPhone you sign in on. Your monitors always belong to your account.", comment: "ng account"),
                 NGAccountCenter.Category.allCases.map { .sync($0) }),
                (nil, nil, [.devices, .export]),
                (nil, NSLocalizedString("Deleting your account removes your monitors, synced servers and settings, and backed-up sound packs. Packs you published stay in the catalog.", comment: "ng account"),
                 [.signOut, .delete]),
            ]
        } else {
            var footer = NSLocalizedString("An NG Account keeps your servers, settings, sound packs and monitors, so a new iPhone or reinstalling TeamTalk NG only needs signing in.", comment: "ng account")
            if center.hasMonitorsWithoutAccount {
                footer += "\n\n" + NSLocalizedString("Your monitors are waiting: sign in or create an account to see them again. They move into your account.", comment: "ng account")
            }
            sections = [(nil, footer, [.signIn, .createAccount])]
        }
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sections[section].footer
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.detailTextLabel?.textColor = CompactUI.secondaryTextColor
        switch sections[indexPath.section].rows[indexPath.row] {
        case .signIn:
            cell.textLabel?.text = NSLocalizedString("Sign In", comment: "ng account")
            cell.accessoryType = .disclosureIndicator
        case .createAccount:
            cell.textLabel?.text = NSLocalizedString("Create Account", comment: "ng account")
            cell.accessoryType = .disclosureIndicator
        case .email:
            cell.textLabel?.text = NSLocalizedString("Email", comment: "ng account")
            cell.detailTextLabel?.text = NGAccountCenter.shared.email
            cell.selectionStyle = .none
        case .changePassword:
            cell.textLabel?.text = NSLocalizedString("Change Password", comment: "ng account")
            cell.accessoryType = .disclosureIndicator
        case .sync(let c):
            cell.textLabel?.text = c.title
            let toggle = UISwitch()
            toggle.isOn = NGAccountCenter.shared.isSyncing(c)
            toggle.accessibilityLabel = c.title
            toggle.addAction(UIAction { _ in NGAccountCenter.shared.setSyncing(c, toggle.isOn) }, for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none
        case .devices:
            cell.textLabel?.text = NSLocalizedString("Devices", comment: "ng account")
            cell.accessoryType = .disclosureIndicator
        case .export:
            cell.textLabel?.text = NSLocalizedString("Export My Data", comment: "ng account")
        case .signOut:
            cell.textLabel?.text = NSLocalizedString("Sign Out", comment: "ng account")
            cell.textLabel?.textColor = .systemRed
        case .delete:
            cell.textLabel?.text = NSLocalizedString("Delete Account", comment: "ng account")
            cell.textLabel?.textColor = .systemRed
        }
        if cell.selectionStyle != .none && cell.accessoryType == .none && cell.accessoryView == nil {
            cell.accessibilityTraits.insert(.button)
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let cell = tableView.cellForRow(at: indexPath)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .signIn: navigationController?.pushViewController(NGFormViewController(.signIn), animated: true)
        case .createAccount: navigationController?.pushViewController(NGFormViewController(.signUp), animated: true)
        case .changePassword: navigationController?.pushViewController(NGFormViewController(.changePassword), animated: true)
        case .devices: navigationController?.pushViewController(NGDevicesViewController(), animated: true)
        case .export: export(from: cell)
        case .signOut: confirmSignOut(from: cell)
        case .delete: navigationController?.pushViewController(NGFormViewController(.deleteAccount), animated: true)
        case .email, .sync: break
        }
    }

    private func export(from cell: UITableViewCell?) {
        Task { @MainActor in
            do {
                let data = try await NGAccountCenter.shared.signed { try await $0.export() }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(NSLocalizedString("NG Account", comment: "ng account export file name") + ".json")
                try data.write(to: url, options: .atomic)
                let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                share.popoverPresentationController?.sourceView = cell ?? view
                present(share, animated: true)
            } catch {
                ngShowError(error)
            }
        }
    }

    private func confirmSignOut(from cell: UITableViewCell?) {
        let sheet = UIAlertController(title: NSLocalizedString("Sign Out of NG Account?", comment: "ng account"),
                                      message: NSLocalizedString("Your monitors keep running; sign in again to see them.\n\nRemoving takes your synced servers, your backed-up sound packs and the packs you downloaded from the catalog off this iPhone. They're still in your account, and signing in again brings them back. Your settings stay as they are, and sound packs that haven't finished backing up stay too.", comment: "ng account"),
                                      preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Sign Out and Keep a Copy", comment: "ng account"), style: .default) { _ in
            Task { await NGAccountCenter.shared.signOut(removeLocalCopy: false) }
        })
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Sign Out and Remove from This iPhone", comment: "ng account"), style: .destructive) { _ in
            Task { await NGAccountCenter.shared.signOut(removeLocalCopy: true) }
        })
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "ng account"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = cell ?? view
        present(sheet, animated: true)
    }
}

/// One form: signing in, making an account, its code, resetting or
/// changing the password, or deleting the account.
final class NGFormViewController: UITableViewController, UITextFieldDelegate {
    enum Kind: Equatable {
        /// `password` is kept (in memory only) to email a new code.
        case signIn, signUp, verify(email: String, password: String), forgot, reset(email: String), changePassword, deleteAccount
    }

    private let kind: Kind
    private var fields: [(label: String, field: UITextField)] = []
    private var busy = false

    init(_ kind: Kind) {
        self.kind = kind
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private var title_: String {
        switch kind {
        case .signIn: return NSLocalizedString("Sign In", comment: "ng account")
        case .signUp: return NSLocalizedString("Create Account", comment: "ng account")
        case .verify: return NSLocalizedString("Check Your Email", comment: "ng account")
        case .forgot: return NSLocalizedString("Reset Password", comment: "ng account")
        case .reset: return NSLocalizedString("New Password", comment: "ng account")
        case .changePassword: return NSLocalizedString("Change Password", comment: "ng account")
        case .deleteAccount: return NSLocalizedString("Delete Account", comment: "ng account")
        }
    }

    private var actionTitle: String {
        switch kind {
        case .signIn: return NSLocalizedString("Sign In", comment: "ng account")
        case .signUp: return NSLocalizedString("Continue", comment: "ng account")
        case .verify: return NSLocalizedString("Finish", comment: "ng account")
        case .forgot: return NSLocalizedString("Email Me a Code", comment: "ng account")
        case .reset, .changePassword: return NSLocalizedString("Save", comment: "ng account")
        case .deleteAccount: return NSLocalizedString("Delete", comment: "ng account")
        }
    }

    private var footer: String? {
        switch kind {
        case .signUp: return NSLocalizedString("We'll email you a code to finish. Choose a password of at least 8 characters.", comment: "ng account")
        case .verify(let email, _): return String(format: NSLocalizedString("We emailed a 6-digit code to %@. It works for 15 minutes.", comment: "ng account"), email)
        case .forgot: return NSLocalizedString("We'll email you a code to choose a new password with.", comment: "ng account")
        case .reset(let email): return String(format: NSLocalizedString("Type the code we emailed to %@, and choose a new password. Your other devices will be signed out.", comment: "ng account"), email)
        case .changePassword: return NSLocalizedString("Your other devices will be signed out.", comment: "ng account")
        case .deleteAccount: return NSLocalizedString("This deletes your NG Account for good: your monitors stop, and your synced servers, settings and backed-up sound packs are removed. Packs you published stay in the catalog. What's on this iPhone stays.", comment: "ng account")
        case .signIn: return nil
        }
    }

    private func makeField(_ label: String, secure: Bool = false, content: UITextContentType? = nil, keyboard: UIKeyboardType = .default) -> UITextField {
        let f = UITextField()
        f.placeholder = label
        f.accessibilityLabel = label
        f.isSecureTextEntry = secure
        f.textContentType = content
        f.keyboardType = keyboard
        f.autocapitalizationType = .none
        f.autocorrectionType = .no
        f.clearButtonMode = .whileEditing
        f.delegate = self
        fields.append((label, f))
        return f
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        CompactUI.apply(to: self, title: title_)
        CompactUI.apply(to: tableView)
        switch kind {
        case .signIn:
            _ = makeField(NSLocalizedString("Email", comment: "ng account"), content: .username, keyboard: .emailAddress)
            _ = makeField(NSLocalizedString("Password", comment: "ng account"), secure: true, content: .password)
        case .signUp:
            _ = makeField(NSLocalizedString("Email", comment: "ng account"), content: .username, keyboard: .emailAddress)
            _ = makeField(NSLocalizedString("Password", comment: "ng account"), secure: true, content: .newPassword)
            _ = makeField(NSLocalizedString("Password Again", comment: "ng account"), secure: true, content: .newPassword)
        case .verify:
            _ = makeField(NSLocalizedString("Code", comment: "ng account"), content: .oneTimeCode, keyboard: .numberPad)
        case .forgot:
            _ = makeField(NSLocalizedString("Email", comment: "ng account"), content: .username, keyboard: .emailAddress)
        case .reset:
            _ = makeField(NSLocalizedString("Code", comment: "ng account"), content: .oneTimeCode, keyboard: .numberPad)
            _ = makeField(NSLocalizedString("New Password", comment: "ng account"), secure: true, content: .newPassword)
            _ = makeField(NSLocalizedString("New Password Again", comment: "ng account"), secure: true, content: .newPassword)
        case .changePassword:
            _ = makeField(NSLocalizedString("Current Password", comment: "ng account"), secure: true, content: .password)
            _ = makeField(NSLocalizedString("New Password", comment: "ng account"), secure: true, content: .newPassword)
            _ = makeField(NSLocalizedString("New Password Again", comment: "ng account"), secure: true, content: .newPassword)
        case .deleteAccount:
            _ = makeField(NSLocalizedString("Password", comment: "ng account"), secure: true, content: .password)
        }
        fields.last?.field.returnKeyType = .go
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !UIAccessibility.isVoiceOverRunning {
            fields.first?.field.becomeFirstResponder()
        }
    }

    // Fields, the action, and extra links (forgot password, a new code).
    private var extraRows: [String] {
        switch kind {
        case .signIn: return [NSLocalizedString("Forgot Password?", comment: "ng account")]
        case .verify, .reset: return [NSLocalizedString("Email Me a New Code", comment: "ng account")]
        default: return []
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        extraRows.isEmpty ? 2 : 3
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return fields.count
        case 1: return 1
        default: return extraRows.count
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? footer : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        switch indexPath.section {
        case 0:
            let f = fields[indexPath.row].field
            f.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(f)
            NSLayoutConstraint.activate([
                f.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                f.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                f.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
                f.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
                f.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
            ])
            cell.selectionStyle = .none
        case 1:
            cell.textLabel?.text = actionTitle
            cell.textLabel?.textColor = kind == .deleteAccount ? .systemRed : CompactUI.accentColor
            cell.textLabel?.font = .preferredFont(forTextStyle: .headline)
            cell.accessibilityTraits = .button
        default:
            cell.textLabel?.text = extraRows[indexPath.row]
            cell.textLabel?.textColor = CompactUI.accentColor
            cell.accessibilityTraits = .button
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch indexPath.section {
        case 1: submit()
        case 2: extra()
        default: fields[indexPath.row].field.becomeFirstResponder()
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if let i = fields.firstIndex(where: { $0.field === textField }), i + 1 < fields.count {
            fields[i + 1].field.becomeFirstResponder()
        } else {
            textField.resignFirstResponder()
            submit()
        }
        return true
    }

    private func value(_ i: Int) -> String {
        fields[i].field.text ?? ""
    }

    private func trimmed(_ i: Int) -> String {
        value(i).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard !busy else { return }
        view.endEditing(true)
        for (label, f) in fields where (f.text ?? "").isEmpty {
            show(String(format: NSLocalizedString("Enter your %@.", comment: "ng account: a field left empty"), label.lowercased()))
            return
        }
        if [.signUp, .changePassword].contains(kind) || { if case .reset = kind { return true }; return false }() {
            let n = fields.count
            guard value(n - 1) == value(n - 2) else {
                show(NSLocalizedString("The two passwords aren't the same.", comment: "ng account"))
                return
            }
        }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                try await perform()
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func perform() async throws {
        let center = NGAccountCenter.shared
        switch kind {
        case .signIn:
            try await center.signIn(email: trimmed(0), password: value(1))
            finish()
        case .signUp:
            try await center.signUp(email: trimmed(0), password: value(1))
            navigationController?.pushViewController(NGFormViewController(.verify(email: trimmed(0), password: value(1))), animated: true)
        case .verify(let email, _):
            try await center.verify(email: email, code: trimmed(0))
            finish()
        case .forgot:
            try await center.forgotPassword(email: trimmed(0))
            navigationController?.pushViewController(NGFormViewController(.reset(email: trimmed(0))), animated: true)
        case .reset(let email):
            try await center.resetPassword(email: email, code: trimmed(0), password: value(1))
            finish()
        case .changePassword:
            try await center.signed { try await $0.changePassword(current: value(0), new: value(1)) }
            UIAccessibility.post(notification: .announcement, argument: NSLocalizedString("Password changed", comment: "ng account"))
            navigationController?.popViewController(animated: true)
        case .deleteAccount:
            confirmDelete()
        }
    }

    private func confirmDelete() {
        let alert = UIAlertController(title: NSLocalizedString("Delete Your NG Account?", comment: "ng account"),
                                      message: NSLocalizedString("This can't be undone.", comment: "ng account"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "ng account"), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("Delete Account", comment: "ng account"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            let password = self.value(0)
            Task { @MainActor in
                do {
                    try await NGAccountCenter.shared.deleteAccount(password: password)
                    UIAccessibility.post(notification: .announcement, argument: NSLocalizedString("NG Account deleted", comment: "ng account"))
                    self.finish()
                } catch {
                    self.show(error.localizedDescription)
                }
            }
        })
        present(alert, animated: true)
    }

    private func extra() {
        switch kind {
        case .signIn:
            navigationController?.pushViewController(NGFormViewController(.forgot), animated: true)
        case .verify(let email, let password):
            Task { @MainActor in
                do {
                    try await NGAccountCenter.shared.signUp(email: email, password: password)
                    UIAccessibility.post(notification: .announcement, argument: NSLocalizedString("New code sent", comment: "ng account"))
                } catch {
                    show(error.localizedDescription)
                }
            }
        case .reset(let email):
            Task { @MainActor in
                do {
                    try await NGAccountCenter.shared.forgotPassword(email: email)
                    UIAccessibility.post(notification: .announcement, argument: NSLocalizedString("New code sent", comment: "ng account"))
                } catch {
                    show(error.localizedDescription)
                }
            }
        default:
            break
        }
    }

    /// Back to the NG Account screen (or wherever signing in started).
    private func finish() {
        guard let nav = navigationController else { return }
        if let account = nav.viewControllers.last(where: { $0 is NGAccountViewController }) {
            nav.popToViewController(account, animated: true)
        } else if let first = nav.viewControllers.firstIndex(where: { $0 is NGFormViewController }), first > 0 {
            nav.popToViewController(nav.viewControllers[first - 1], animated: true)
        } else {
            nav.popViewController(animated: true)
        }
    }

    private func show(_ message: String) {
        let alert = UIAlertController(title: title_, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "ng account"), style: .default))
        present(alert, animated: true)
    }
}

/// The iPhones signed in to the account.
final class NGDevicesViewController: UITableViewController {
    private var sessions: [NGSession] = []

    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        CompactUI.apply(to: self, title: NSLocalizedString("Devices", comment: "ng account"))
        CompactUI.apply(to: tableView)
        load()
    }

    private func load() {
        Task { @MainActor in
            do {
                sessions = try await NGAccountCenter.shared.signed { try await $0.sessions() }
                tableView.reloadData()
            } catch {
                ngShowError(error)
            }
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sessions.count
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        NSLocalizedString("Swipe a device to sign it out.", comment: "ng account")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let s = sessions[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = s.current ? String(format: NSLocalizedString("%@ (This iPhone)", comment: "ng account"), s.name) : s.name
        let seen = Date(timeIntervalSince1970: TimeInterval(s.lastSeen) / 1000)
        cell.detailTextLabel?.text = String(format: NSLocalizedString("Last used %@", comment: "ng account"),
                                            RelativeDateTimeFormatter().localizedString(for: seen, relativeTo: Date()))
        cell.detailTextLabel?.textColor = CompactUI.secondaryTextColor
        cell.selectionStyle = .none
        return cell
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let s = sessions[indexPath.row]
        let action = UIContextualAction(style: .destructive, title: NSLocalizedString("Sign Out", comment: "ng account")) { [weak self] _, _, done in
            Task { @MainActor in
                do {
                    if s.current {
                        await NGAccountCenter.shared.signOut(removeLocalCopy: false)
                        self?.navigationController?.popViewController(animated: true)
                    } else {
                        try await NGAccountCenter.shared.signed { try await $0.endSession(s.id) }
                        self?.sessions.removeAll { $0.id == s.id }
                        self?.tableView.reloadData()
                    }
                    done(true)
                } catch {
                    self?.ngShowError(error)
                    done(false)
                }
            }
        }
        return UISwipeActionsConfiguration(actions: [action])
    }
}

/// Publishing one of this iPhone's sound packs in the catalog.
final class NGPublishPackViewController: UITableViewController, UITextFieldDelegate {
    /// Which pack: one of this iPhone's (by its own ID), or one of the
    /// account's catalog packs (by the account's ID).
    private enum Which {
        case local(String)
        case account(String)
    }

    private let which: Which
    private var pack: NGPack?
    private let publicSwitch = UISwitch()
    private let name = UITextField()
    private let author = UITextField()
    private let about = UITextField()

    init(localID: String) {
        which = .local(localID)
        super.init(style: .insetGrouped)
    }

    /// A catalog pack the account owns (installed from the catalog).
    init(accountPackID: String) {
        which = .account(accountPackID)
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        CompactUI.apply(to: self, title: NSLocalizedString("Publish", comment: "ng account pack"))
        CompactUI.apply(to: tableView)
        for (f, label) in [(name, NSLocalizedString("Pack Name", comment: "ng account pack")),
                           (author, NSLocalizedString("Made By (shown to everyone)", comment: "ng account pack")),
                           (about, NSLocalizedString("Description", comment: "ng account pack"))] {
            f.placeholder = label
            f.accessibilityLabel = label
            f.clearButtonMode = .whileEditing
            f.delegate = self
        }
        publicSwitch.accessibilityLabel = NSLocalizedString("Public", comment: "ng account pack")
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(save))
        navigationItem.rightBarButtonItem?.isEnabled = false
        load()
    }

    private func load() {
        Task { @MainActor in
            // Back the pack up first, so the account has its sounds.
            await NGPackSync.shared.syncNow()
            do {
                let packs = try await NGAccountCenter.shared.signed { try await $0.packs() }.packs
                switch which {
                case .local(let id): pack = packs.first { $0.localId == id }
                case .account(let id): pack = packs.first { $0.id == id }
                }
            } catch {
                ngShowError(error)
            }
            if let pack {
                name.text = pack.name
                author.text = pack.author
                about.text = pack.description
                publicSwitch.isOn = pack.public
                navigationItem.rightBarButtonItem?.isEnabled = true
            }
            tableView.reloadData()
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        pack == nil ? 1 : 2
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if pack == nil { return 1 }
        return section == 1 ? 3 : 1
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let pack else { return nil }
        if section == 0 {
            if pack.hidden {
                return NSLocalizedString("TeamTalk NG took this pack out of the catalog.", comment: "ng account pack")
            }
            return NSLocalizedString("Public packs are in the catalog for everyone to download, under the name and maker you choose here. Turn Public off to take a pack out of the catalog; you can turn it back on any time. Your email is never shown. Only publish sounds you have the right to share.", comment: "ng account pack")
        }
        return nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        guard pack != nil else {
            cell.textLabel?.text = NGAccountCenter.shared.isSignedIn
                ? NSLocalizedString("Backing up the pack to your NG Account...", comment: "ng account pack")
                : NSLocalizedString("Sign in to your NG Account to publish packs.", comment: "ng account pack")
            cell.textLabel?.numberOfLines = 0
            return cell
        }
        if indexPath.section == 0 {
            cell.textLabel?.text = NSLocalizedString("Public", comment: "ng account pack")
            cell.accessoryView = publicSwitch
            return cell
        }
        let f = [name, author, about][indexPath.row]
        f.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(f)
        NSLayoutConstraint.activate([
            f.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            f.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            f.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
            f.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
            f.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])
        return cell
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    @objc private func save() {
        guard let pack else { return }
        view.endEditing(true)
        let change = NGPackChange(name: name.text, author: author.text, description: about.text, public: publicSwitch.isOn)
        Task { @MainActor in
            do {
                self.pack = try await NGAccountCenter.shared.signed { try await $0.changePack(pack.id, change) }
                UIAccessibility.post(notification: .announcement, argument: publicSwitch.isOn
                    ? NSLocalizedString("Published", comment: "ng account pack")
                    : NSLocalizedString("Saved", comment: "ng account pack"))
                navigationController?.popViewController(animated: true)
            } catch {
                ngShowError(error)
            }
        }
    }
}

extension UIViewController {
    func ngShowError(_ error: Error) {
        let alert = UIAlertController(title: nil, message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "alert"), style: .default))
        present(alert, animated: true)
    }
}
