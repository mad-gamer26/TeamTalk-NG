/*
 * The Monitors screen: the servers TeamTalk NG's monitor service watches
 * for this phone, and starting to monitor one from the saved server list.
 */

import UIKit

/// Asking, in plain words, before monitoring a saved server.
enum MonitorSetup {
    /// Set up monitoring of a saved server: the monitor's nickname, status
    /// and channel first, then it starts.
    static func offerToMonitor(_ server: Server, from vc: UIViewController, done: (() -> Void)? = nil) {
        let name = server.name.isEmpty ? server.ipaddr : server.name
        if MonitorCenter.shared.monitored(server) != nil {
            let alert = UIAlertController(title: String(format: NSLocalizedString("%@ Is Already Monitored", comment: "monitor"), name), message: nil, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "monitor"), style: .default))
            vc.present(alert, animated: true)
            return
        }
        vc.navigationController?.pushViewController(MonitorServerEditViewController(saved: server), animated: true)
    }

    /// Choose one of the saved servers to monitor.
    static func chooseSavedServer(from vc: UIViewController, sourceView: UIView?, done: (() -> Void)? = nil) {
        let saved = loadLocalServers().filter { MonitorCenter.shared.monitored($0) == nil }
        guard !saved.isEmpty else {
            let alert = UIAlertController(title: NSLocalizedString("No Servers to Add", comment: "monitor"),
                                          message: NSLocalizedString("Every saved server is already monitored. Add a server to your server list first.", comment: "monitor"),
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "monitor"), style: .default))
            vc.present(alert, animated: true)
            return
        }
        let sheet = UIAlertController(title: NSLocalizedString("Monitor a Saved Server", comment: "monitor"), message: nil, preferredStyle: .actionSheet)
        for s in saved {
            sheet.addAction(UIAlertAction(title: s.name.isEmpty ? s.ipaddr : s.name, style: .default) { _ in
                offerToMonitor(s, from: vc, done: done)
            })
        }
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "monitor"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = sourceView ?? vc.view
        vc.present(sheet, animated: true)
    }
}

final class MonitorListViewController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case servers, actions
    }

    private var connection: MonitorConnection? { MonitorCenter.shared.connection }
    private var servers: [MonitorServerSummary] { connection?.servers ?? [] }

    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        CompactUI.apply(to: self, title: NSLocalizedString("Monitors", comment: "monitor"))
        CompactUI.apply(to: tableView)
        let add = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addServer))
        add.accessibilityLabel = NSLocalizedString("Monitor a Saved Server", comment: "monitor")
        navigationItem.rightBarButtonItem = add
        NotificationCenter.default.addObserver(self, selector: #selector(monitorChanged), name: .monitorChanged, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        MonitorCenter.shared.reload()
        if let connection {
            Task { await connection.refreshServers() }
        }
        tableView.reloadData()
    }

    @objc private func monitorChanged() {
        tableView.reloadData()
    }

    @objc private func addServer() {
        MonitorSetup.chooseSavedServer(from: self, sourceView: nil) { [weak self] in self?.tableView.reloadData() }
    }

    // MARK: Table

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .servers: return servers.count
        case .actions: return connection == nil ? 0 : 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        Section(rawValue: section) == .servers && !servers.isEmpty ? NSLocalizedString("Monitored Servers", comment: "monitor") : nil
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .servers:
            if servers.isEmpty {
                return NSLocalizedString("The monitor stays logged in to your servers even when TeamTalk NG is closed. It notifies you when people log in or send you messages, and lets you reply and see who is on. Add a server with the + button, or choose Monitor This Server on a server in your list.", comment: "monitor")
            }
            if let connection, !connection.online, let error = connection.lastError {
                return error
            }
            return nil
        case .actions:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.detailTextLabel?.textColor = CompactUI.secondaryTextColor
        switch Section(rawValue: indexPath.section)! {
        case .servers:
            let s = servers[indexPath.row]
            cell.accessoryType = .disclosureIndicator
            cell.imageView?.image = UIImage(systemName: s.status == .loggedIn ? "dot.radiowaves.left.and.right" : (s.status == .paused || s.status == .steppedAside ? "pause.circle" : "exclamationmark.triangle"))
            cell.textLabel?.text = s.displayName
            var details = [s.enabled ? s.status.text : NSLocalizedString("Off", comment: "monitor")]
            if s.status == .loggedIn {
                details.append(String(format: NSLocalizedString("%d online", comment: "monitor"), max(0, s.userCount - 1)))
            } else if let reason = s.reason, !reason.isEmpty, s.status != .paused {
                details.append(reason)
            }
            if s.unreadPrivateMessages > 0 {
                details.append(String(format: NSLocalizedString("%d unread", comment: "monitor"), s.unreadPrivateMessages))
            }
            if connection?.isMutedByHand(s.id) == true {
                details.append(NSLocalizedString("muted", comment: "monitor: notifications muted"))
            }
            cell.detailTextLabel?.text = details.joined(separator: ", ")
            cell.detailTextLabel?.numberOfLines = 0
            cell.accessibilityLabel = "\(s.displayName), \(details.joined(separator: ", "))"
        case .actions:
            cell.textLabel?.text = NSLocalizedString("Monitor Settings", comment: "monitor")
            cell.imageView?.image = UIImage(systemName: "bell")
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section)! {
        case .servers:
            guard let connection else { return }
            navigationController?.pushViewController(MonitorSessionViewController(connection: connection, serverID: servers[indexPath.row].id), animated: true)
        case .actions:
            if let connection {
                navigationController?.pushViewController(MonitorSettingsViewController(connection: connection), animated: true)
            }
        }
    }

    /// Show a monitored server, and a conversation in it, from a tapped
    /// notification.
    func show(ref: String, serverID: Int, chat: MonitorPrivateChat?) {
        MonitorCenter.shared.reload()
        guard let c = MonitorCenter.shared.connection(ref: ref) else { return }
        navigationController?.popToViewController(self, animated: false)
        let session = MonitorSessionViewController(connection: c, serverID: serverID)
        navigationController?.pushViewController(session, animated: false)
        if let chat {
            session.loadViewIfNeeded()
            session.showPrivateMessages(chat)
        }
    }
}
