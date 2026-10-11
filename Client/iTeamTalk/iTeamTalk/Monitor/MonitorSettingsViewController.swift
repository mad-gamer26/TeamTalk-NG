/*
 * Monitor settings: what this phone is notified about, the servers the
 * monitor service watches for it, and stopping it all. Also the form for
 * changing a monitored server.
 */

import UIKit

final class MonitorSettingsViewController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case sound, notifications, people, servers, leave
    }

    private static func title(_ choice: MonitorNotificationSound.Choice) -> String {
        switch choice {
        case .soundPack: return NSLocalizedString("Sound Pack", comment: "monitor notification sound")
        case .system: return NSLocalizedString("iPhone Default Sound", comment: "monitor notification sound")
        case .none: return NSLocalizedString("No Sound", comment: "monitor notification sound")
        }
    }

    private enum Row {
        case choice(title: String, key: WritableKeyPath<MonitorPrefs, String>, options: [(value: String, title: String)])
        case toggle(title: String, key: WritableKeyPath<MonitorPrefs, Bool>)
        case list(title: String, key: WritableKeyPath<MonitorPrefs, [String]>, help: String)
        case muted
    }

    private let connection: MonitorConnection
    private var prefs: MonitorPrefs?
    private var loadError: String?

    private static let presence: [(value: String, title: String)] = [
        ("all", NSLocalizedString("Everyone", comment: "monitor prefs")),
        ("watched", NSLocalizedString("Watched People", comment: "monitor prefs")),
        ("none", NSLocalizedString("Nobody", comment: "monitor prefs")),
    ]

    private let notificationRows: [Row] = [
        .muted,
        .toggle(title: NSLocalizedString("Private Messages", comment: "monitor prefs"), key: \.privateMessages),
        .choice(title: NSLocalizedString("Channel Messages", comment: "monitor prefs"), key: \.channelMessages, options: [
            ("all", NSLocalizedString("All", comment: "monitor prefs")),
            ("mentions", NSLocalizedString("When Mentioned", comment: "monitor prefs")),
            ("none", NSLocalizedString("None", comment: "monitor prefs")),
        ]),
        .choice(title: NSLocalizedString("Logins", comment: "monitor prefs"), key: \.logins, options: presence),
        .choice(title: NSLocalizedString("Logouts", comment: "monitor prefs"), key: \.logouts, options: presence),
        .toggle(title: NSLocalizedString("Broadcasts", comment: "monitor prefs"), key: \.broadcasts),
        .toggle(title: NSLocalizedString("Monitor Lost a Server", comment: "monitor prefs"), key: \.connection),
    ]

    private let peopleRows: [Row] = [
        .list(title: NSLocalizedString("Watched People", comment: "monitor prefs"), key: \.watched,
              help: NSLocalizedString("Usernames or nicknames, separated by commas. With logins set to Watched People, only these people's logins notify you.", comment: "monitor prefs")),
        .list(title: NSLocalizedString("Ignored People", comment: "monitor prefs"), key: \.ignored,
              help: NSLocalizedString("Usernames or nicknames, separated by commas. Nothing these people do notifies you.", comment: "monitor prefs")),
        .list(title: NSLocalizedString("Mention Words", comment: "monitor prefs"), key: \.mentionWords,
              help: NSLocalizedString("Words, separated by commas, that count as mentioning you in a channel, besides the monitor's nickname.", comment: "monitor prefs")),
    ]

    init(connection: MonitorConnection) {
        self.connection = connection
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        CompactUI.apply(to: self, title: NSLocalizedString("Monitor Settings", comment: "monitor"))
        CompactUI.apply(to: tableView)
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: .monitorChanged, object: connection)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task { @MainActor in
            do {
                prefs = try await connection.api.prefs()
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
            await connection.refreshServers()
            tableView.reloadData()
        }
    }

    @objc private func changed() {
        tableView.reloadData()
    }

    private func save(_ change: (inout MonitorPrefs) -> Void) {
        guard var p = prefs else { return }
        change(&p)
        prefs = p
        tableView.reloadData()
        Task { @MainActor in
            do {
                try await connection.api.setPrefs(p)
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    // MARK: Table

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .sound: return 1
        case .notifications: return prefs == nil ? 0 : notificationRows.count
        case .people: return prefs == nil ? 0 : peopleRows.count
        case .servers: return connection.servers.count + 1
        case .leave: return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .sound: return NSLocalizedString("Notification Sound", comment: "monitor prefs")
        case .notifications: return NSLocalizedString("Notify Me About", comment: "monitor prefs")
        case .people: return NSLocalizedString("People", comment: "monitor prefs")
        case .servers: return NSLocalizedString("Monitored Servers", comment: "monitor")
        case .leave: return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .sound: return NSLocalizedString("For this iPhone. Sound Pack plays your sound pack's sounds, and stays quiet for sound events you have turned off.", comment: "monitor prefs")
        case .notifications: return loadError ?? NSLocalizedString("These settings apply on all your iPhones.", comment: "monitor prefs")
        case .servers: return NSLocalizedString("The monitor logs in to these servers and stays logged in.", comment: "monitor")
        case .leave: return NSLocalizedString("Logs the monitor out of every server and deletes your servers, logins and messages from the monitor service.", comment: "monitor")
        default: return nil
        }
    }

    private func row(_ indexPath: IndexPath) -> Row {
        Section(rawValue: indexPath.section) == .notifications ? notificationRows[indexPath.row] : peopleRows[indexPath.row]
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.detailTextLabel?.textColor = CompactUI.secondaryTextColor
        switch Section(rawValue: indexPath.section)! {
        case .sound:
            cell.textLabel?.text = NSLocalizedString("Sound", comment: "monitor prefs")
            cell.detailTextLabel?.text = Self.title(MonitorNotificationSound.choice)
            cell.accessoryType = .disclosureIndicator
        case .notifications, .people:
            guard let prefs else { return cell }
            switch row(indexPath) {
            case .muted:
                let muted = (prefs.mutedUntil ?? 0) > Int64(Date().timeIntervalSince1970 * 1000)
                cell.textLabel?.text = NSLocalizedString("Pause Notifications", comment: "monitor prefs")
                if muted, let until = prefs.mutedUntil {
                    let date = Date(timeIntervalSince1970: TimeInterval(until) / 1000)
                    cell.detailTextLabel?.text = String(format: NSLocalizedString("Until %@", comment: "monitor prefs"), DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short))
                } else {
                    cell.detailTextLabel?.text = NSLocalizedString("Off", comment: "monitor prefs")
                }
                cell.accessoryType = .disclosureIndicator
            case .toggle(let title, let key):
                cell.textLabel?.text = title
                let toggle = UISwitch()
                toggle.isOn = prefs[keyPath: key]
                toggle.addAction(UIAction { [weak self] action in
                    let on = (action.sender as? UISwitch)?.isOn ?? false
                    self?.save { $0[keyPath: key] = on }
                }, for: .valueChanged)
                toggle.accessibilityLabel = title
                cell.accessoryView = toggle
                cell.selectionStyle = .none
            case .choice(let title, let key, let options):
                cell.textLabel?.text = title
                cell.detailTextLabel?.text = options.first { $0.value == prefs[keyPath: key] }?.title
                cell.accessoryType = .disclosureIndicator
            case .list(let title, let key, _):
                cell.textLabel?.text = title
                let list = prefs[keyPath: key]
                cell.detailTextLabel?.text = list.isEmpty ? NSLocalizedString("None", comment: "monitor prefs") : list.joined(separator: ", ")
                cell.accessoryType = .disclosureIndicator
            }
        case .servers:
            if indexPath.row < connection.servers.count {
                let s = connection.servers[indexPath.row]
                cell.textLabel?.text = s.displayName
                cell.detailTextLabel?.text = s.enabled ? "\(s.host):\(s.tcpPort)" : NSLocalizedString("Off", comment: "monitor")
                cell.accessoryType = .disclosureIndicator
            } else {
                cell.textLabel?.text = NSLocalizedString("Add Server", comment: "monitor")
                cell.textLabel?.textColor = CompactUI.accentColor
                cell.accessibilityTraits = .button
            }
        case .leave:
            cell.textLabel?.text = NSLocalizedString("Stop Monitoring All Servers", comment: "monitor")
            cell.textLabel?.textColor = .systemRed
            cell.accessibilityTraits = .button
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let cell = tableView.cellForRow(at: indexPath)
        switch Section(rawValue: indexPath.section)! {
        case .sound:
            chooseSound(from: cell)
        case .notifications, .people:
            guard let prefs else { return }
            switch row(indexPath) {
            case .muted:
                choosePause(from: cell)
            case .toggle:
                break
            case .choice(let title, let key, let options):
                let sheet = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
                for o in options {
                    let action = UIAlertAction(title: o.title, style: .default) { [weak self] _ in self?.save { $0[keyPath: key] = o.value } }
                    action.setValue(prefs[keyPath: key] == o.value, forKey: "checked")
                    sheet.addAction(action)
                }
                sheet.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "monitor"), style: .cancel))
                sheet.popoverPresentationController?.sourceView = cell
                present(sheet, animated: true)
            case .list(let title, let key, let help):
                let alert = UIAlertController(title: title, message: help, preferredStyle: .alert)
                alert.addTextField { $0.text = prefs[keyPath: key].joined(separator: ", "); $0.autocapitalizationType = .none }
                alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "monitor"), style: .cancel))
                alert.addAction(UIAlertAction(title: NSLocalizedString("Save", comment: "monitor"), style: .default) { [weak self] _ in
                    let words = (alert.textFields?.first?.text ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    self?.save { $0[keyPath: key] = words }
                })
                present(alert, animated: true)
            }
        case .servers:
            if indexPath.row < connection.servers.count {
                navigationController?.pushViewController(MonitorServerEditViewController(connection: connection, serverID: connection.servers[indexPath.row].id), animated: true)
            } else {
                MonitorSetup.chooseSavedServer(from: self, sourceView: cell) { [weak self] in self?.tableView.reloadData() }
            }
        case .leave:
            confirmStopEverything(from: cell)
        }
    }

    private func chooseSound(from cell: UITableViewCell?) {
        let sheet = UIAlertController(title: NSLocalizedString("Notification Sound", comment: "monitor prefs"), message: nil, preferredStyle: .actionSheet)
        for choice in MonitorNotificationSound.Choice.allCases {
            let action = UIAlertAction(title: Self.title(choice), style: .default) { [weak self] _ in
                MonitorNotificationSound.choice = choice
                if choice == .soundPack {
                    MonitorNotificationSounds.refresh()
                }
                self?.tableView.reloadSections([Section.sound.rawValue], with: .none)
            }
            action.setValue(MonitorNotificationSound.choice == choice, forKey: "checked")
            sheet.addAction(action)
        }
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "monitor"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = cell
        present(sheet, animated: true)
    }

    private func choosePause(from cell: UITableViewCell?) {
        let sheet = UIAlertController(title: NSLocalizedString("Pause Notifications", comment: "monitor prefs"), message: nil, preferredStyle: .actionSheet)
        let now = Date().timeIntervalSince1970
        for (title, hours) in [(NSLocalizedString("For 1 Hour", comment: "monitor prefs"), 1.0), (NSLocalizedString("For 8 Hours", comment: "monitor prefs"), 8.0), (NSLocalizedString("For 24 Hours", comment: "monitor prefs"), 24.0)] {
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.save { $0.mutedUntil = Int64((now + hours * 3600) * 1000) }
            })
        }
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Resume Now", comment: "monitor prefs"), style: .default) { [weak self] _ in
            self?.save { $0.mutedUntil = nil }
        })
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "monitor"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = cell
        present(sheet, animated: true)
    }

    private func confirmStopEverything(from cell: UITableViewCell?) {
        let sheet = UIAlertController(title: NSLocalizedString("Stop Monitoring All Servers?", comment: "monitor"),
                                      message: NSLocalizedString("You will no longer get notifications from the monitor, and its record of your servers and messages is deleted.", comment: "monitor"),
                                      preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Stop Monitoring", comment: "monitor"), style: .destructive) { [weak self] _ in
            Task { @MainActor in
                do {
                    try await MonitorCenter.shared.stopEverything()
                    self?.navigationController?.popViewController(animated: true)
                } catch {
                    self?.showError(error.localizedDescription)
                }
            }
        })
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "monitor"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = cell
        present(sheet, animated: true)
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: NSLocalizedString("Not Saved", comment: "monitor"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "monitor"), style: .default))
        present(alert, animated: true)
    }
}

/// The monitor's settings for a server: set up before it starts
/// monitoring a saved server, or changed later.
final class MonitorServerEditViewController: UITableViewController, UITextFieldDelegate {
    private struct Field {
        let title: String
        let field = UITextField()
    }

    private let connection: MonitorConnection?
    private let serverID: Int?
    /// The saved server being set up, before monitoring starts.
    private let saved: Server?
    private let name = Field(title: NSLocalizedString("Name", comment: "monitor server"))
    private let host = Field(title: NSLocalizedString("Address", comment: "monitor server"))
    private let port = Field(title: NSLocalizedString("TCP Port", comment: "monitor server"))
    private let nickname = Field(title: NSLocalizedString("Nickname", comment: "monitor server"))
    private let username = Field(title: NSLocalizedString("Username", comment: "monitor server"))
    private let password = Field(title: NSLocalizedString("Password", comment: "monitor server"))
    private let status = Field(title: NSLocalizedString("Status Message", comment: "monitor server"))
    private let channel = Field(title: NSLocalizedString("Channel to Join", comment: "monitor server"))
    private let channelPassword = Field(title: NSLocalizedString("Channel Password", comment: "monitor server"))
    private let encrypted = UISwitch()
    private let enabled = UISwitch()
    private let muted = UISwitch()
    private var wasMuted = false
    private let genderCell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
    private lazy var gender = newTableCellSegCtrl(genderCell, label: NSLocalizedString("Gender", comment: "preferences"),
                                                  values: [NSLocalizedString("Male", comment: "preferences"), NSLocalizedString("Female", comment: "preferences"), NSLocalizedString("Neutral", comment: "preferences")])

    private var isNew: Bool { serverID == nil }

    /// What the monitor is called and does there come first; where the
    /// server is comes from the saved server.
    private var sections: [[Field]] {
        [[nickname, status], [channel, channelPassword], [username, password], [name, host, port]]
    }

    /// Change a monitored server.
    init(connection: MonitorConnection, serverID: Int) {
        self.connection = connection
        self.serverID = serverID
        saved = nil
        super.init(style: .insetGrouped)
    }

    /// Set up monitoring of a saved server.
    init(saved: Server) {
        connection = MonitorCenter.shared.connection
        serverID = nil
        self.saved = saved
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let savedName = saved.map { $0.name.isEmpty ? $0.ipaddr : $0.name } ?? ""
        CompactUI.apply(to: self, title: isNew ? String(format: NSLocalizedString("Monitor %@", comment: "monitor"), savedName) : NSLocalizedString("Server Settings", comment: "monitor"))
        CompactUI.apply(to: tableView)
        let save = isNew
            ? UIBarButtonItem(title: NSLocalizedString("Monitor", comment: "monitor"), style: .done, target: self, action: #selector(save))
            : UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(save))
        navigationItem.rightBarButtonItem = save
        for f in sections.joined() {
            f.field.placeholder = f.title
            f.field.accessibilityLabel = f.title
            f.field.autocorrectionType = .no
            f.field.autocapitalizationType = .none
            f.field.clearButtonMode = .whileEditing
            f.field.delegate = self
        }
        name.field.autocapitalizationType = .words
        nickname.field.autocapitalizationType = .words
        status.field.autocapitalizationType = .sentences
        host.field.keyboardType = .URL
        port.field.keyboardType = .numberPad
        port.field.text = String(AppInfo.DEFAULT_TCPPORT)
        password.field.isSecureTextEntry = true
        channelPassword.field.isSecureTextEntry = true
        channel.field.placeholder = NSLocalizedString("None (stay out of channels)", comment: "monitor server")
        status.field.placeholder = NSLocalizedString("Status Message (optional)", comment: "monitor server")
        enabled.isOn = true
        encrypted.accessibilityLabel = NSLocalizedString("Encrypted", comment: "monitor server")
        enabled.accessibilityLabel = NSLocalizedString("Monitoring On", comment: "monitor server")
        muted.accessibilityLabel = NSLocalizedString("Mute Notifications", comment: "monitor server")
        // Like a live connection, until the monitor's own is known.
        gender.selectedSegmentIndex = preferredGenderIndex()
        if let saved {
            let input = MonitorCenter.input(for: saved)
            name.field.text = input.name
            host.field.text = input.host
            port.field.text = String(input.tcpPort)
            nickname.field.text = input.nickname
            username.field.text = input.username
            password.field.text = input.password
            encrypted.isOn = input.encrypted
            tableView.tableHeaderView = introduction()
        } else if let serverID, let s = connection?.servers.first(where: { $0.id == serverID }) {
            name.field.text = s.name
            host.field.text = s.host
            port.field.text = String(s.tcpPort)
            nickname.field.text = s.nickname
            username.field.text = s.username
            encrypted.isOn = s.encrypted
            enabled.isOn = s.enabled
            wasMuted = connection?.isMutedByHand(serverID) ?? false
            muted.isOn = wasMuted
            password.field.placeholder = NSLocalizedString("Unchanged", comment: "monitor server")
            channelPassword.field.placeholder = NSLocalizedString("Unchanged", comment: "monitor server")
            loadFullSettings(serverID)
        }
    }

    /// What monitoring does, said once, before it starts.
    private func introduction() -> UIView {
        let label = UILabel()
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = CompactUI.secondaryTextColor
        label.text = NSLocalizedString("TeamTalk NG's monitor service stays logged in to this server for you, even when the app is closed, and notifies you when people log in or send you messages. You can reply from the notification. Other people on the server see the monitor as a text-only user, with the nickname below.", comment: "monitor")
        let container = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 10))
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.layoutMarginsGuide.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: container.layoutMarginsGuide.trailingAnchor),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])
        let size = container.systemLayoutSizeFitting(CGSize(width: view.bounds.width, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        container.frame.size.height = size.height
        return container
    }

    /// Fields the server list does not carry (passwords are never sent).
    private func loadFullSettings(_ id: Int) {
        Task { @MainActor in
            guard let c = try? await connection?.api.serverConfig(id) else { return }
            username.field.text = c.username
            status.field.text = c.statusMsg
            if let mode = c.statusMode {
                gender.selectedSegmentIndex = MonitorGender.index(statusMode: mode)
            }
            channel.field.text = c.channel
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        // The fields, the switches, and (for a monitored server) stopping.
        sections.count + (isNew ? 1 : 2)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        // The monitor's gender follows its nickname and status.
        if section == 0 { return sections[0].count + 1 }
        if section < sections.count { return sections[section].count }
        if section == sections.count { return isNew ? 1 : 3 }
        return 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return NSLocalizedString("Monitor", comment: "monitor server")
        case 1: return NSLocalizedString("After Login", comment: "monitor server")
        case 2: return NSLocalizedString("Monitor's Login", comment: "monitor server")
        case 3: return NSLocalizedString("Server", comment: "monitor server")
        default: return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
        case 0: return NSLocalizedString("What other people on the server see.", comment: "monitor server")
        case 1: return NSLocalizedString("To read a channel's messages and reply there, the monitor must be in it.", comment: "monitor server")
        case 2: return NSLocalizedString("Use an account of its own for the monitor if the server allows only one login per account.", comment: "monitor server")
        case sections.count where !isNew:
            return NSLocalizedString("Mute Notifications keeps the monitor watching this server, but you get no notifications from it.", comment: "monitor server")
        default: return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 && indexPath.row == sections[0].count {
            genderCell.selectionStyle = .none
            return genderCell
        }
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        if indexPath.section < sections.count {
            let f = sections[indexPath.section][indexPath.row].field
            f.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(f)
            NSLayoutConstraint.activate([
                f.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                f.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                f.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
                f.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
                f.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
            ])
        } else if indexPath.section == sections.count {
            let toggle = [encrypted, enabled, muted][indexPath.row]
            cell.textLabel?.text = toggle.accessibilityLabel
            cell.accessoryView = toggle
        } else {
            cell.textLabel?.text = NSLocalizedString("Stop Monitoring This Server", comment: "monitor server")
            cell.textLabel?.textColor = .systemRed
            cell.selectionStyle = .default
            cell.accessibilityTraits = .button
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isNew, indexPath.section == sections.count + 1 else { return }
        confirmRemove(from: tableView.cellForRow(at: indexPath))
    }

    private func confirmRemove(from cell: UITableViewCell?) {
        guard let serverID, let connection else { return }
        let sheet = UIAlertController(title: NSLocalizedString("Stop Monitoring This Server?", comment: "monitor server"),
                                      message: NSLocalizedString("The monitor logs out and forgets the server and its message history.", comment: "monitor server"),
                                      preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Stop Monitoring", comment: "monitor server"), style: .destructive) { [weak self] _ in
            Task { @MainActor in
                do {
                    try await connection.api.removeServer(serverID)
                    await connection.refreshServers()
                    if let nav = self?.navigationController, let list = nav.viewControllers.first(where: { $0 is MonitorListViewController }) {
                        nav.popToViewController(list, animated: true)
                    } else {
                        self?.navigationController?.popViewController(animated: true)
                    }
                } catch {
                    self?.showError(error.localizedDescription)
                }
            }
        })
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "monitor"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = cell
        present(sheet, animated: true)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let all = Array(sections.joined())
        if let i = all.firstIndex(where: { $0.field === textField }), i + 1 < all.count {
            all[i + 1].field.becomeFirstResponder()
        } else {
            textField.resignFirstResponder()
        }
        return true
    }

    @objc private func save() {
        let text = { (f: Field) in (f.field.text ?? "").trimmingCharacters(in: .whitespaces) }
        guard !text(host).isEmpty else {
            showError(NSLocalizedString("Enter the server's address.", comment: "monitor server"))
            return
        }
        let input = MonitorServerInput(
            name: text(name).isEmpty ? text(host) : text(name),
            host: text(host),
            tcpPort: Int(text(port)) ?? AppInfo.DEFAULT_TCPPORT,
            encrypted: encrypted.isOn,
            nickname: text(nickname),
            username: text(username),
            password: password.field.text ?? "",
            statusMsg: text(status),
            statusMode: MonitorGender.statusMode(index: gender.selectedSegmentIndex),
            channel: text(channel),
            channelPassword: channelPassword.field.text ?? "",
            enabled: enabled.isOn)
        view.endEditing(true)
        navigationItem.rightBarButtonItem?.isEnabled = false
        Task { @MainActor in
            do {
                if let serverID, let connection {
                    try await connection.api.updateServer(serverID, input)
                    if muted.isOn != wasMuted {
                        try await MonitorCenter.shared.setMuted(serverID, muted.isOn)
                    }
                    await connection.refreshServers()
                } else {
                    try await MonitorCenter.shared.monitor(input)
                    UIAccessibility.post(notification: .announcement, argument: String(format: NSLocalizedString("Now monitoring %@", comment: "monitor"), input.name))
                }
                navigationController?.popViewController(animated: true)
            } catch {
                navigationItem.rightBarButtonItem?.isEnabled = true
                showError(error.localizedDescription)
            }
        }
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: isNew ? NSLocalizedString("Could Not Monitor This Server", comment: "monitor") : NSLocalizedString("Not Saved", comment: "monitor"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "monitor"), style: .default))
        present(alert, animated: true)
    }
}
