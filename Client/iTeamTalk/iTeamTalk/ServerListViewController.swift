/*
 * Copyright (c) 2005-2018, BearWare.dk
 * 
 * Contact Information:
 *
 * Bjoern D. Rasmussen
 * Kirketoften 5
 * DK-8260 Viby J
 * Denmark
 * Email: contact@bearware.dk
 * Phone: +45 20 20 54 59
 * Web: http://www.bearware.dk
 *
 * This source code is part of the TeamTalk SDK owned by
 * BearWare.dk. Use of this file, or its compiled unit, requires a
 * TeamTalk SDK License Key issued by BearWare.dk.
 *
 * The TeamTalk SDK License Agreement along with its Terms and
 * Conditions are outlined in the file License.txt included with the
 * TeamTalk SDK distribution.
 *
 */

import UIKit
import SwiftUI
import UniformTypeIdentifiers

@available(iOS 14.0, *)
struct ServerActionsMenu: View {
    let hasServers: Bool
    let addServer: () -> Void
    let importTTFile: () -> Void
    let exportServers: () -> Void
    let deleteAllServers: () -> Void
    var canReorder = false
    var reorderServers: () -> Void = {}

    var body: some View {
        Menu {
            Button(NSLocalizedString("Add Server", comment: "serverlist"), action: addServer)
            Button(NSLocalizedString("Import from .TT File", comment: "serverlist"), action: importTTFile)
            if canReorder {
                Button(NSLocalizedString("Reorder Servers", comment: "serverlist"), action: reorderServers)
            }
            if hasServers {
                Button(NSLocalizedString("Export Server List", comment: "serverlist"), action: exportServers)
                Button(NSLocalizedString("Delete All Servers", comment: "serverlist"), role: .destructive, action: deleteAllServers)
            }
        } label: {
            Image(systemName: "line.3.horizontal")
                .imageScale(.large)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
        .accessibilityLabel(Text(NSLocalizedString("Actions", comment: "serverlist")))
    }
}

enum ServerType {
    case LOCAL
}

// Properties of a TeamTalk server to connect to
class Server : NSObject {
    var name = ""
    var ipaddr = ""
    var tcpport = AppInfo.DEFAULT_TCPPORT
    var udpport = AppInfo.DEFAULT_UDPPORT
    var joincode = ""
    var nickname = ""
    var statusmsg = ""
    var username = ""
    var password = ""
    var channel = ""
    var chanpasswd = ""
    var servertype : ServerType = .LOCAL
    var encrypted = false
    var cacertdata = ""
    var certdata = ""
    var certprivkeydata = ""
    var certverifypeer = false
    /// The same server on every device of the NG Account.
    var syncID = UUID().uuidString
    /// Whether NG Account syncs this server's passwords.
    var syncPassword = true
    
    // Reserved for imported server metadata.
    var stats_usercount = 0
    var stats_country = ""
    var stats_servername = ""
    var stats_motd = ""
    
    override init() {
        
    }
    
    @objc init(coder dec: NSCoder!) {
        name = dec.decodeObject(forKey: "name") as! String
        ipaddr = dec.decodeObject(forKey: "ipaddr") as! String
        tcpport = dec.decodeInteger(forKey: "tcpport")
        udpport = dec.decodeInteger(forKey: "udpport")
        username = dec.decodeObject(forKey: "username") as! String
        password = dec.decodeObject(forKey: "password") as! String
        nickname = dec.decodeObject(forKey: "nickname") as? String ?? ""
        statusmsg = dec.decodeObject(forKey: "statusmsg") as? String ?? ""
        channel = dec.decodeObject(forKey: "channel") as! String
        chanpasswd = dec.decodeObject(forKey: "chanpasswd") as! String
        encrypted = dec.decodeBool(forKey: "encrypted")
        cacertdata = dec.decodeObject(forKey: "cacertdata") as? String ?? ""
        certdata = dec.decodeObject(forKey: "certdata") as? String ?? ""
        certprivkeydata = dec.decodeObject(forKey: "certprivkeydata") as? String ?? ""
        certverifypeer = dec.decodeBool(forKey: "certverifypeer")
        syncID = dec.decodeObject(forKey: "syncid") as? String ?? ""
        syncPassword = dec.containsValue(forKey: "syncpassword") ? dec.decodeBool(forKey: "syncpassword") : true
    }
    
    @objc func encodeWithCoder(_ enc: NSCoder!) {
        enc.encode(name, forKey: "name")
        enc.encode(ipaddr, forKey: "ipaddr")
        enc.encode(tcpport, forKey: "tcpport")
        enc.encode(udpport, forKey: "udpport")
        enc.encode(username, forKey: "username")
        enc.encode(password, forKey: "password")
        enc.encode(nickname, forKey: "nickname")
        enc.encode(statusmsg, forKey: "statusmsg")
        enc.encode(channel, forKey: "channel")
        enc.encode(chanpasswd, forKey: "chanpasswd")
        enc.encode(encrypted, forKey: "encrypted")
        enc.encode(cacertdata, forKey: "cacertdata")
        enc.encode(certdata, forKey: "certdata")
        enc.encode(certprivkeydata, forKey: "certprivkeydata")
        enc.encode(certverifypeer, forKey: "certverifypeer")
        enc.encode(syncID, forKey: "syncid")
        enc.encode(syncPassword, forKey: "syncpassword")
    }
}

/// The server list already has this server with the same login.
func isServerSaved(_ server: Server) -> Bool {
    loadLocalServers().contains { saved in
        saved.ipaddr.caseInsensitiveCompare(server.ipaddr) == .orderedSame
            && saved.tcpport == server.tcpport
            && saved.udpport == server.udpport
            && saved.encrypted == server.encrypted
            && saved.username == server.username
            && saved.password == server.password
            && saved.cacertdata == server.cacertdata
            && saved.certdata == server.certdata
            && saved.certprivkeydata == server.certprivkeydata
            && saved.certverifypeer == server.certverifypeer
    }
}

/// Saves a server to the list under `name` (replacing one of that name).
func saveServerToList(_ server: Server, named name: String) {
    let existing = loadLocalServers()
    // Replacing a server keeps it the same server in the NG Account.
    if let replaced = existing.first(where: { $0.name == name }) {
        server.syncID = replaced.syncID
    }
    var servers = existing.filter { $0.name != name }
    server.name = name
    server.servertype = .LOCAL
    servers.append(server)
    saveLocalServers(servers)
}

let SERVER_LIST_KEY = "ServerList"

func loadServers(from defaults: UserDefaults) -> [Server] {
    var servers = [Server]()

    if let stored = defaults.array(forKey: SERVER_LIST_KEY) {
        for e in stored {
            guard let data = e as? Data,
                  let server = NSKeyedUnarchiver.unarchiveObject(with: data) as? Server else { continue }
            servers.append(server)
        }
    }
    return servers
}

func loadLocalServers() -> [Server] {
    return loadServers(from: UserDefaults.standard)
}

func saveLocalServers(_ servers : [Server]) {
    //Store local servers
    let defaults = UserDefaults.standard
    var s_array = [Data]()
    for s in servers {
        let data = NSKeyedArchiver.archivedData(withRootObject: s)
        s_array.append(data)
    }
    defaults.set(s_array, forKey: SERVER_LIST_KEY)
    defaults.synchronize()
    saveControlCenterServers(servers)
    NotificationCenter.default.post(name: .localServersSaved, object: nil)
}

func saveControlCenterServers(_ servers: [Server]) {
    let records = servers
        .filter { $0.servertype == .LOCAL && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
        .map { ControlCenterServerRecord(id: $0.name, name: $0.name) }
    ControlCenterServerStore.saveServers(records)
}

class ServerListViewController : UITableViewController,
    UIDocumentPickerDelegate,
    XMLParserDelegate {
    
    // server for segue
    var currentServer = Server()
    // list of available servers
    var servers = [Server]()
    
    var nextappupdate = Date()
    var actionsMenuHost: UIViewController?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
        
        CompactUI.apply(to: self, title: NSLocalizedString("Servers", comment: "serverlist"))
        CompactUI.apply(to: tableView)
        NotificationCenter.default.addObserver(self, selector: #selector(iCloudSettingsDidApply), name: .iCloudSettingsDidApply, object: nil)
        // Servers from the NG Account (another iPhone added or changed some).
        NotificationCenter.default.addObserver(self, selector: #selector(iCloudSettingsDidApply), name: .ngSyncApplied, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(connectedServerSessionsDidChange), name: .connectedServerSessionsDidChange, object: nil)
        tableView.rowHeight = 52
        tableView.estimatedRowHeight = 52
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 12)
        tableView.tableHeaderView = nil
        configureActionsButton()
        if #available(iOS 13.0, *) {
        }
        else {
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(serverRowLongPressed(_:)))
            tableView.addGestureRecognizer(longPress)
        }

        if let setupbtn = self.navigationItem.leftBarButtonItem {
            setupbtn.accessibilityLabel = NSLocalizedString("Settings", comment: "serverlist")
        }
    }

    @objc private func iCloudSettingsDidApply() {
        DispatchQueue.main.async { [weak self] in self?.refreshAvailableServers() }
    }

    @objc private func connectedServerSessionsDidChange() {
        DispatchQueue.main.async { [weak self] in self?.refreshAvailableServers() }
    }

    private func refreshAvailableServers() {
        servers = loadLocalServers().filter { ConnectedServerManager.shared.isConnectedServer($0) == false }
        reloadServerTable()
        configureConnectedServersButton()
    }

    private func configureConnectedServersButton() {
        guard navigationController?.topViewController === self else { return }
        let monitors = UIBarButtonItem(title: NSLocalizedString("Monitors", comment: "serverlist"),
                                       style: .plain,
                                       target: self,
                                       action: #selector(showMonitors))
        monitors.accessibilityLabel = NSLocalizedString("Monitors", comment: "serverlist")
        var items = [monitors, UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)]
        if ConnectedServerManager.shared.hasSessions {
            let connectedServers = UIBarButtonItem(title: NSLocalizedString("Connected Servers", comment: "serverlist"),
                                                   style: .plain,
                                                   target: self,
                                                   action: #selector(showLastConnectedServer))
            connectedServers.accessibilityLabel = NSLocalizedString("Connected Servers", comment: "serverlist")
            items.append(connectedServers)
        }
        toolbarItems = items
        navigationController?.setToolbarHidden(false, animated: false)
    }

    @objc private func showMonitors() {
        navigationController?.pushViewController(MonitorListViewController(), animated: true)
    }

    @objc private func showLastConnectedServer() {
        guard let navigationController,
              let session = ConnectedServerManager.shared.activeSession ?? ConnectedServerManager.shared.sessions.last else { return }
        ConnectedServerManager.shared.show(session, in: navigationController)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    func configureActionsButton() {
        var menu = ServerActionsMenu(hasServers: servers.isEmpty == false, addServer: { [weak self] in
            self?.addServerFromActions()
        }, importTTFile: { [weak self] in
            self?.showTTFileImporter()
        }, exportServers: { [weak self] in
            self?.exportServerList()
        }, deleteAllServers: { [weak self] in
            self?.confirmDeleteAllServers()
        })
        menu.canReorder = loadLocalServers().count > 1
        menu.reorderServers = { [weak self] in self?.startReordering() }
        let host = UIHostingController(rootView: menu)
        host.view.backgroundColor = .clear
        host.view.sizeToFit()
        host.view.accessibilityLabel = NSLocalizedString("Actions", comment: "serverlist")
        actionsMenuHost = host
        let actionsButton = UIBarButtonItem(customView: host.view)
        actionsButton.accessibilityLabel = NSLocalizedString("Actions", comment: "serverlist")
        navigationItem.rightBarButtonItem = actionsButton
    }

    @objc func showActionsFallback() {
        let alert = UIAlertController(title: NSLocalizedString("Actions", comment: "serverlist"), message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Add Server", comment: "serverlist"), style: .default) { _ in
            self.addServerFromActions()
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Import from .TT File", comment: "serverlist"), style: .default) { _ in
            self.showTTFileImporter()
        })
        if servers.isEmpty == false {
            alert.addAction(UIAlertAction(title: NSLocalizedString("Export Server List", comment: "serverlist"), style: .default) { _ in
                self.exportServerList()
            })
            alert.addAction(UIAlertAction(title: NSLocalizedString("Delete All Servers", comment: "serverlist"), style: .destructive) { _ in
                self.confirmDeleteAllServers()
            })
        }
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "Dialog message"), style: .cancel, handler: nil))
        present(alert, animated: true)
    }

    func addServerFromActions() {
        performSegue(withIdentifier: "New Server", sender: self)
    }

    func showTTFileImporter() {
        let picker: UIDocumentPickerViewController
        if #available(iOS 14.0, *) {
            var contentTypes = [UTType.data]
            if let teamTalkType = UTType("dk.bearware.teamtalkhost") {
                contentTypes.insert(teamTalkType, at: 0)
            }
            picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        }
        else {
            picker = UIDocumentPickerViewController(documentTypes: ["dk.bearware.teamtalkhost", "public.data"], in: .import)
        }
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        importServers(fromTTFile: url)
    }

    func importServers(fromTTFile url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer {
            if access {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let data = try? Data(contentsOf: url) else {
            showImportResult(message: NSLocalizedString("Unable to open .TT file.", comment: "serverlist"))
            return
        }

        let serverparser = ServerParser()
        let parser = XMLParser(data: data)
        parser.delegate = serverparser

        guard parser.parse() else {
            showImportResult(message: NSLocalizedString("Unable to read .TT file.", comment: "serverlist"))
            return
        }

        let importedServers = serverparser.servers.filter({ $0.ipaddr.isEmpty == false })
        guard importedServers.isEmpty == false else {
            showImportResult(message: NSLocalizedString("No servers found in .TT file.", comment: "serverlist"))
            return
        }

        var localServers = loadLocalServers()
        var existingKeys = Set(localServers.map({ serverImportKey($0) }))
        var newServers = [Server]()
        for server in importedServers {
            let key = serverImportKey(server)
            if existingKeys.contains(key) == false {
                existingKeys.insert(key)
                server.servertype = .LOCAL
                newServers.append(server)
            }
        }

        localServers.append(contentsOf: newServers)
        saveLocalServers(localServers)
        refreshAvailableServers()

        let message = String(format: NSLocalizedString("Imported %d servers from .TT file.", comment: "serverlist"), newServers.count)
        showImportResult(message: message)
    }

    func showImportResult(message: String) {
        let alert = UIAlertController(title: NSLocalizedString("Import Complete", comment: "serverlist"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
        present(alert, animated: true)
    }

    func exportServerList() {
        do {
            let exportURL = try writeServerListExportFile()
            let activity = UIActivityViewController(activityItems: [exportURL], applicationActivities: nil)
            if let popover = activity.popoverPresentationController {
                popover.barButtonItem = navigationItem.rightBarButtonItem
                popover.sourceView = view
                popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            }
            present(activity, animated: true)
        } catch {
            showServerListError(error)
        }
    }

    func confirmDeleteAllServers() {
        let alert = UIAlertController(title: NSLocalizedString("Delete All Servers?", comment: "serverlist"),
                                      message: NSLocalizedString("Are you sure you wish to delete all the servers in your server list?", comment: "serverlist"),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "Dialog message"), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("Delete All Servers", comment: "serverlist"), style: .destructive) { _ in
            self.servers.removeAll()
            saveLocalServers([])
            self.refreshAvailableServers()
        })
        present(alert, animated: true)
    }

    func confirmDeleteServer(at index: Int) {
        guard servers.indices.contains(index) else { return }
        let server = servers[index]
        let name = server.name.isEmpty ? NSLocalizedString("Unnamed Server", comment: "serverlist") : server.name
        let alert = UIAlertController(title: NSLocalizedString("Delete Server?", comment: "serverlist"),
                                      message: String(format: NSLocalizedString("Are you sure you wish to delete %@ from your server list?", comment: "serverlist"), name),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "Dialog message"), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("Delete", comment: "serverlist"), style: .destructive) { _ in
            // Look the server up again in case the list changed while the alert was up.
            if let current = self.servers.firstIndex(where: { $0 === server }) {
                self.deleteServer(at: current)
            }
        })
        present(alert, animated: true)
    }

    func writeServerListExportFile() throws -> URL {
        let exportServers = servers.filter { $0.servertype == .LOCAL }
        let xml = serverListExportXML(for: exportServers)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TeamTalk Servers").appendingPathExtension("tt")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try xml.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }

    func serverListExportXML(for servers: [Server]) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<teamtalk>\n"
        for server in servers {
            xml += "  <host>\n"
            xml += "    <name>\(xmlEscaped(server.name))</name>\n"
            xml += "    <address>\(xmlEscaped(server.ipaddr))</address>\n"
            xml += "    <tcpport>\(server.tcpport)</tcpport>\n"
            xml += "    <udpport>\(server.udpport)</udpport>\n"
            xml += "    <encrypted>\(server.encrypted ? "true" : "false")</encrypted>\n"
            xml += "    <auth>\n"
            xml += "      <username>\(xmlEscaped(server.username))</username>\n"
            xml += "      <password>\(xmlEscaped(server.password))</password>\n"
            xml += "      <nickname>\(xmlEscaped(server.nickname))</nickname>\n"
            xml += "      <statusmsg>\(xmlEscaped(server.statusmsg))</statusmsg>\n"
            xml += "    </auth>\n"
            xml += "    <join>\n"
            xml += "      <channel>\(xmlEscaped(server.channel))</channel>\n"
            xml += "      <password>\(xmlEscaped(server.chanpasswd))</password>\n"
            xml += "    </join>\n"
            xml += "  </host>\n"
        }
        xml += "</teamtalk>\n"
        return xml
    }

    func xmlEscaped(_ value: String) -> String {
        return value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    func showServerListError(_ error: Error) {
        let alert = UIAlertController(title: NSLocalizedString("Server List Error", comment: "serverlist"),
                                      message: error.localizedDescription,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Dialog message"), style: .default))
        present(alert, animated: true)
    }

    func serverImportKey(_ server: Server) -> String {
        return "\(server.name)|\(server.ipaddr)|\(server.tcpport)|\(server.udpport)"
    }

    func updateEmptyState() {
        if servers.isEmpty {
            let label = UILabel()
            label.text = NSLocalizedString("No Servers", comment: "serverlist")
            label.font = UIFont.preferredFont(forTextStyle: .headline)
            label.textColor = CompactUI.secondaryTextColor
            label.textAlignment = .center
            label.adjustsFontForContentSizeCategory = true
            tableView.backgroundView = label
        }
        else {
            tableView.backgroundView = nil
        }
    }

    func reloadServerTable() {
        tableView.reloadData()
        updateEmptyState()
        configureActionsButton()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // The Monitors and Connected Servers bar belongs to this list only.
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        refreshAvailableServers()
        
        if (nextappupdate as NSDate).earlierDate(Date()) == nextappupdate {
            Timer.scheduledTimer(timeInterval: 2.0, target: self, selector: #selector(ServerListViewController.checkAppUpdate), userInfo: nil, repeats: false)
        }
        
    }
    
    @objc func checkAppUpdate() {
        
        // check for new version
        if let url = URL(string: AppInfo.getUpdateURL()) {
            let task = URLSession.shared.dataTask(with: url) { data, response, error in
                if error != nil {
                    print ("Failed to check app update \(url.absoluteString)")
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    print ("Failed to check app update \(url.absoluteString)")
                    return
                }
                if let data = data {
                    let parser = XMLParser(data: data)
                    let updateparser = AppUpdateParser()
                    parser.delegate = updateparser
                    parser.parse()
                }
            }
            task.resume()
        }
        nextappupdate = nextappupdate.addingTimeInterval(60 * 60 * 24)
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    func saveServerList() {
        // This list leaves out servers connected right now: they keep their
        // places, and the rest fill the others in this list's order (the
        // order also syncs to the NG Account's other iPhones).
        var remaining = servers[...]
        var merged = [Server]()
        for saved in loadLocalServers() {
            if ConnectedServerManager.shared.isConnectedServer(saved) {
                merged.append(saved)
            } else if let next = remaining.popFirst() {
                merged.append(next)
            }
        }
        merged.append(contentsOf: remaining)
        saveLocalServers(merged.filter({$0.servertype == .LOCAL}))
    }
    
    override func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return servers.count
    }
    
    fileprivate func createServerCell(_ tableView: UITableView, _ indexPath: IndexPath, _ serverIndex: Int) -> UITableViewCell {
        let cellIdentifier = "ServerTableCell"
        
        let cell = tableView.dequeueReusableCell(withIdentifier: cellIdentifier, for: indexPath) as! ServerTableCell
        let server = servers[serverIndex]
        cell.connectBtn.tag = serverIndex
        cell.connectBtn.isHidden = true
        cell.backgroundColor = CompactUI.secondaryBackgroundColor
        cell.selectedBackgroundView = UIView()
        cell.selectedBackgroundView?.backgroundColor = CompactUI.accentColor.withAlphaComponent(0.12)
        CompactUI.stylePrimaryLabel(cell.nameLabel)
        CompactUI.styleSecondaryLabel(cell.detailLabel)
        cell.nameLabel.text = server.name.isEmpty ? NSLocalizedString("Unnamed Server", comment: "serverlist") : server.name
        cell.detailLabel.text = "\(server.ipaddr):\(server.tcpport)"
        // No server icon: the image stays empty and narrow (it only keeps
        // the labels off the edge).
        cell.iconImageView.image = nil
        cell.iconImageView.isHidden = true
        cell.iconImageView.constraints.first { $0.firstAttribute == .width }?.constant = 12
        
        cell.isAccessibilityElement = true
        cell.iconImageView.isAccessibilityElement = false
        cell.nameLabel.isAccessibilityElement = false
        cell.detailLabel.isAccessibilityElement = false
        cell.connectBtn.isAccessibilityElement = false
        cell.accessibilityTraits = [.button]
        cell.accessibilityLabel = [cell.nameLabel.text, cell.detailLabel.text]
            .compactMap({$0})
            .filter({$0.isEmpty == false})
            .joined(separator: ", ")
        cell.accessibilityActivationHandler = { [weak self] in
            self?.connectToServer(at: serverIndex)
            return true
        }
        cell.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: NSLocalizedString("Edit", comment: "serverlist")) { [weak self] _ in
                self?.editServer(at: serverIndex)
                return true
            },
            UIAccessibilityCustomAction(name: NSLocalizedString("Monitor This Server", comment: "serverlist")) { [weak self] _ in
                self?.monitorServer(at: serverIndex)
                return true
            },
            UIAccessibilityCustomAction(name: NSLocalizedString("Delete", comment: "serverlist")) { [weak self] _ in
                self?.confirmDeleteServer(at: serverIndex)
                return true
            }
        ]

        return cell
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        return createServerCell(tableView, indexPath, indexPath.row)
    }

    // MARK: Reordering

    /// Reordering happens on its own screen.
    func startReordering() {
        // Every saved server, connected ones too.
        let reorder = ReorderServersViewController(servers: loadLocalServers()) { [weak self] ordered in
            saveLocalServers(ordered.filter { $0.servertype == .LOCAL })
            self?.refreshAvailableServers()
        }
        navigationController?.pushViewController(reorder, animated: true)
    }


    func connectToServer(at index: Int) {
        guard servers.indices.contains(index) else { return }
        currentServer = servers[index]
        if let existing = ConnectedServerManager.shared.session(for: currentServer),
           let navigationController {
            ConnectedServerManager.shared.show(existing, in: navigationController)
            return
        }
        performSegue(withIdentifier: "Show ChannelList", sender: self)
    }

    /// Connect to a server, saved or not (the connected screen then offers
    /// to save it).
    func connect(to server: Server) {
        currentServer = server
        if let existing = ConnectedServerManager.shared.session(for: server), let navigationController {
            ConnectedServerManager.shared.show(existing, in: navigationController)
            return
        }
        performSegue(withIdentifier: "Show ChannelList", sender: self)
    }

    func connectToSavedServer(named serverName: String) -> Bool {
        if let connected = ConnectedServerManager.shared.sessions.first(where: { $0.server.name == serverName }),
           let navigationController {
            ConnectedServerManager.shared.show(connected, in: navigationController)
            return true
        }

        if let savedServer = loadLocalServers().first(where: { $0.name == serverName }),
           let connected = ConnectedServerManager.shared.session(for: savedServer),
           let navigationController {
            ConnectedServerManager.shared.show(connected, in: navigationController)
            return true
        }
        refreshAvailableServers()

        guard let index = servers.firstIndex(where: { $0.name == serverName }) else {
            return false
        }

        connectToServer(at: index)
        return true
    }

    func editServer(at index: Int) {
        guard servers.indices.contains(index) else { return }
        currentServer = servers[index]
        performSegue(withIdentifier: "Show Server", sender: index)
    }

    func deleteServer(at index: Int) {
        guard servers.indices.contains(index) else { return }
        servers.remove(at: index)
        saveServerList()
        reloadServerTable()
    }

    @objc @available(iOS 8.0, *)
    func editServer(_ action: UIAccessibilityCustomAction) -> Bool {
        if let ac = action as? MyCustomAction {
            editServer(at: ac.tag)
        }
        return true
    }
    
    @objc @available(iOS 8.0, *)
    func deleteServer(_ action: UIAccessibilityCustomAction) -> Bool {
        
        if let ac = action as? MyCustomAction {
            confirmDeleteServer(at: ac.tag)
        }
        return true
    }

    @objc func serverRowLongPressed(_ sender: UILongPressGestureRecognizer) {
        guard sender.state == .began else { return }

        let point = sender.location(in: tableView)
        guard let indexPath = tableView.indexPathForRow(at: point) else { return }
        showServerRowActions(for: indexPath.row)
    }

    func showServerRowActions(for index: Int) {
        guard servers.indices.contains(index) else { return }

        let alert = UIAlertController(title: servers[index].name, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Edit", comment: "serverlist"), style: .default) { _ in
            self.editServer(at: index)
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Delete", comment: "serverlist"), style: .destructive) { _ in
            self.confirmDeleteServer(at: index)
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "Dialog message"), style: .cancel, handler: nil))
        present(alert, animated: true)
    }

    @available(iOS 13.0, *)
    override func tableView(_ tableView: UITableView,
                            contextMenuConfigurationForRowAt indexPath: IndexPath,
                            point: CGPoint) -> UIContextMenuConfiguration? {
        let index = indexPath.row
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let edit = UIAction(title: NSLocalizedString("Edit", comment: "serverlist"),
                                image: UIImage(systemName: "pencil")) { _ in
                self.editServer(at: index)
            }
            let monitor = UIAction(title: NSLocalizedString("Monitor This Server", comment: "serverlist"),
                                   image: UIImage(systemName: "bell.badge")) { _ in
                self.monitorServer(at: index)
            }
            let delete = UIAction(title: NSLocalizedString("Delete", comment: "serverlist"),
                                  image: UIImage(systemName: "trash"),
                                  attributes: .destructive) { _ in
                self.confirmDeleteServer(at: index)
            }
            return UIMenu(title: "", children: [edit, monitor, delete])
        }
    }

    /// Have TeamTalk NG's monitor service watch a saved server.
    private func monitorServer(at index: Int) {
        guard servers.indices.contains(index) else { return }
        MonitorSetup.offerToMonitor(servers[index], from: self)
    }

    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.identifier == "Show Server" {
            if let action = sender as? MyCustomAction {
                currentServer = servers[action.tag]
            }
            else if let index = sender as? Int {
                currentServer = servers[index]
            }
            else if let button = sender as? UIButton {
                currentServer = servers[button.tag]
            }
            else if let index = self.tableView.indexPathForSelectedRow {
                currentServer = servers[index.row]
            }
            let serverDetail = segue.destination as! ServerDetailViewController
            serverDetail.server = currentServer
        }
        else if segue.identifier == "New Server" {
            
        }
        else if segue.identifier == "Show ChannelList" {
            if let index = self.tableView.indexPathForSelectedRow {
                currentServer = servers[index.row]
            }
            else if let button = sender as? UIButton {
                currentServer = servers[button.tag]
            }
            let vc = segue.destination as! MainTabBarController
            vc.setTeamTalkServer(currentServer)
        }
    }
    
    @IBAction func deleteServerDetail(_ segue:UIStoryboardSegue) {
        let vc = segue.source as! ServerDetailViewController
        
        vc.saveServerDetail()
        let name = vc.namefield?.text
        
        servers = servers.filter({$0.name != name})
        
        saveServerList()
        
        reloadServerTable()
    }
    
    @IBAction func saveServerDetail(_ segue:UIStoryboardSegue) {
        let vc = segue.source as! ServerDetailViewController
        
        vc.saveServerDetail()
        let name = vc.server.name
        
        if let found = servers.map({$0.name}).firstIndex(of: name) {
            servers[found] = vc.server
        }
        else {
            servers.append(vc.server)
        }
        
        self.currentServer = vc.server
        
        saveServerList()
        
        reloadServerTable()
    }
    
    @IBAction func connectToServer(_ sender: UIButton) {
        currentServer = servers[sender.tag]
    }

    func openUrl(_ url: URL) {
        if url.absoluteString.starts(with: AppInfo.TTLINK_PREFIX) {
            guard let link = TeamTalkServerLink(url: url),
                  let navigationController else { return }
            let details = ServerLinkDetailsViewController(link: link) { [weak self, weak navigationController] server in
                guard let self, let navigationController else { return }
                navigationController.popToViewController(self, animated: false)
                if let connected = ConnectedServerManager.shared.session(for: server) {
                    ConnectedServerManager.shared.show(connected, in: navigationController)
                    return
                }
                self.currentServer = server
                self.performSegue(withIdentifier: "Show ChannelList", sender: self)
            }
            navigationController.pushViewController(details, animated: true)
            return
        }

        if url.isFileURL {
            importServers(fromTTFile: url)
            return
        }
        else if url.absoluteString.starts(with: AppInfo.TTLINK_PREFIX){
            do {
                // assume TT url
                let url_str = url.absoluteString
                let ns_str = url_str as NSString
                let url_range = NSMakeRange(0, url_str.count)

                // ip-addr
                let host = AppInfo.TTLINK_PREFIX + "([^\\??!/]*)/?\\??"
                let host_regex = try NSRegularExpression(pattern: host, options: .caseInsensitive)
                let host_matches = host_regex.matches(in: url_str, options: .reportCompletion, range: url_range)
                if let m = host_matches.first {
                    currentServer.ipaddr = ns_str.substring(with: m.range(at: 1))
                }
                
                //tcp port
                let tcpport = "[&|\\?]tcpport=(\\d+)"
                let tcpport_regex = try NSRegularExpression(pattern: tcpport, options: .caseInsensitive)
                let tcpport_matches = tcpport_regex.matches(in: url_str, options: .reportCompletion, range: url_range)
                if let m = tcpport_matches.first {
                    let s = ns_str.substring(with: m.range(at: 1))
                    currentServer.tcpport = Int(s) ?? currentServer.tcpport
                }
                
                // udp port
                let udpport = "[&|\\?]udpport=(\\d+)"
                let udpport_regex = try NSRegularExpression(pattern: udpport, options: .caseInsensitive)
                let udpport_matches = udpport_regex.matches(in: url_str, options: .reportCompletion, range: url_range)
                if let m = udpport_matches.first {
                    let s = ns_str.substring(with: m.range(at: 1))
                    currentServer.udpport = Int(s) ?? currentServer.udpport
                }

                // encrypted
                let encrypted = "[&|\\?]encrypted=([^&]*)"
                let encrypted_regex = try NSRegularExpression(pattern: encrypted, options: .caseInsensitive)
                let encrypted_matches = encrypted_regex.matches(in: url_str, options: .reportCompletion, range: url_range)
                if let m = encrypted_matches.first {
                    let str = ns_str.substring(with: m.range(at: 1))
                    currentServer.encrypted = str == "true" || str == "1"
                }

                // username
                let username = "[&|\\?]username=([^&]*)"
                let username_regex = try NSRegularExpression(pattern: username, options: .caseInsensitive)
                let username_matches = username_regex.matches(in: url_str, options: .reportCompletion, range: url_range)
                if let m = username_matches.first {
                    let urlusername = ns_str.substring(with: m.range(at: 1))
                    currentServer.username = urlusername.removingPercentEncoding!
                }
                
                // password
                let password = "[&|\\?]password=([^&]*)"
                let password_regex = try NSRegularExpression(pattern: password, options: .caseInsensitive)
                let password_matches = password_regex.matches(in: url_str, options: .reportCompletion, range: url_range)
                if let m = password_matches.first {
                    let urlpasswd = ns_str.substring(with: m.range(at: 1))
                    currentServer.password = urlpasswd.removingPercentEncoding!
                }

                // nickname
                let nickname = "[&|\\?]nickname=([^&]*)"
                let nickname_regex = try NSRegularExpression(pattern: nickname, options: .caseInsensitive)
                let nickname_matches = nickname_regex.matches(in: url_str, options: .reportCompletion, range: url_range)
                if let m = nickname_matches.first {
                    let urlnickname = ns_str.substring(with: m.range(at: 1))
                    currentServer.nickname = urlnickname.removingPercentEncoding!
                }

                // channel
                let channel = "[&|\\?]channel=([^&]*)"
                let channel_regex = try NSRegularExpression(pattern: channel, options: .caseInsensitive)
                let channel_matches = channel_regex.matches(in: url_str, options: .reportCompletion, range: url_range)
                if let m = channel_matches.first {
                    let urlchannel = ns_str.substring(with: m.range(at: 1))
                    currentServer.channel = urlchannel.removingPercentEncoding!
                }
                
                // channel password
                let chpasswd = "[&|\\?]chanpasswd=([^&]*)"
                let chpasswd_regex = try NSRegularExpression(pattern: chpasswd, options: .caseInsensitive)
                let chpasswd_matches = chpasswd_regex.matches(in: url_str, options: .reportCompletion, range: url_range)
                if let m = chpasswd_matches.first {
                    let urlchpasswd = ns_str.substring(with: m.range(at: 1))
                    currentServer.chanpasswd = urlchpasswd.removingPercentEncoding!
                }
            }
            catch {
                
            }
        }
        
        if !currentServer.ipaddr.isEmpty {
            performSegue(withIdentifier: "Show ChannelList", sender: self)
        }
    }
}

private struct TeamTalkServerLink {
    let server: Server
    let details: [(label: String, value: String)]

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, host.isEmpty == false else { return nil }

        var items = [String: String]()
        for item in components.queryItems ?? [] {
            items[item.name.lowercased()] = item.value ?? ""
        }

        let server = Server()
        server.ipaddr = host
        if let value = items["tcpport"], let port = Int(value) { server.tcpport = port }
        if let value = items["udpport"], let port = Int(value) { server.udpport = port }
        if let value = items["encrypted"] { server.encrypted = value.lowercased() == "true" || value == "1" }
        if let value = items["username"] { server.username = value }
        if let value = items["password"] { server.password = value }
        if let value = items["nickname"] { server.nickname = value }
        if let value = items["channel"] { server.channel = value }
        if let value = items["chanpasswd"] { server.chanpasswd = value }
        self.server = server

        var details = [(String, String)]()
        details.append((NSLocalizedString("Host", comment: "server link detail"), host))
        if let value = items["tcpport"] { details.append((NSLocalizedString("TCP Port", comment: "server link detail"), value)) }
        if let value = items["udpport"] { details.append((NSLocalizedString("UDP Port", comment: "server link detail"), value)) }
        if let value = items["encrypted"] {
            let enabled = value.lowercased() == "true" || value == "1"
            details.append((NSLocalizedString("Encrypted", comment: "server link detail"),
                            enabled ? NSLocalizedString("Yes", comment: "yes") : NSLocalizedString("No", comment: "no")))
        }
        if let value = items["username"] { details.append((NSLocalizedString("Username", comment: "server link detail"), value)) }
        if let value = items["password"] { details.append((NSLocalizedString("Password", comment: "server link detail"), value)) }
        if let value = items["channel"] { details.append((NSLocalizedString("Channel", comment: "server link detail"), value)) }
        self.details = details
    }
}

/// Reorders the server list with the system drag handles (and iOS's own
/// Move up and Move down for VoiceOver). Each change is saved straight away.
private final class ReorderServersViewController: UITableViewController {
    private var servers: [Server]
    private let changed: ([Server]) -> Void

    init(servers: [Server], changed: @escaping ([Server]) -> Void) {
        self.servers = servers
        self.changed = changed
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Reorder Servers", comment: "serverlist")
        tableView.isEditing = true
        tableView.allowsSelectionDuringEditing = false
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        servers.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let server = servers[indexPath.row]
        cell.textLabel?.text = server.name.isEmpty ? NSLocalizedString("Unnamed Server", comment: "serverlist") : server.name
        cell.detailTextLabel?.text = "\(server.ipaddr):\(server.tcpport)"
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.showsReorderControl = true
        cell.selectionStyle = .none
        // The cell keeps UIKit's own accessibility, so VoiceOver finds its
        // reorder control (the system drag handle).
        // iOS gives reorderable rows Move up and Move down itself.
        return cell
    }

    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { true }

    override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle { .none }

    override func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool { false }

    override func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        let server = servers.remove(at: sourceIndexPath.row)
        servers.insert(server, at: destinationIndexPath.row)
        changed(servers)
        // positions and actions of the rows change
        DispatchQueue.main.async { [weak self] in self?.tableView.reloadData() }
    }

}

private final class ServerLinkDetailsViewController: UITableViewController {
    private let link: TeamTalkServerLink
    private let connect: (Server) -> Void

    init(link: TeamTalkServerLink, connect: @escaping (Server) -> Void) {
        self.link = link
        self.connect = connect
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Server Link", comment: "server link screen title")
        configureButtons()
    }

    private func configureButtons() {
        var buttons = [UIBarButtonItem(title: NSLocalizedString("Connect", comment: "connect to server"),
                                       style: .done,
                                       target: self,
                                       action: #selector(connectToServer))]
        if isServerSaved(link.server) == false {
            let save = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.down"),
                                       style: .plain,
                                       target: self,
                                       action: #selector(showSaveServerDialog))
            save.accessibilityLabel = NSLocalizedString("Save Server", comment: "main-tab")
            buttons.append(save)
        }
        navigationItem.rightBarButtonItems = buttons
    }

    /// The same as Save Server on a connected server.
    @objc private func showSaveServerDialog() {
        let alert = UIAlertController(title: NSLocalizedString("Save Server", comment: "Dialog message"),
                                      message: NSLocalizedString("Enter a name for this server.", comment: "Dialog message"),
                                      preferredStyle: .alert)
        alert.addTextField { [link] textField in
            textField.text = link.server.name.isEmpty ? link.server.ipaddr : link.server.name
            textField.placeholder = NSLocalizedString("Server Name", comment: "server entry name")
        }
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "Dialog message"), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("Save", comment: "Dialog message"), style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            saveServerToList(self.link.server, named: name.isEmpty ? self.link.server.ipaddr : name)
            self.configureButtons()
        })
        present(alert, animated: true)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        link.details.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        let detail = link.details[indexPath.row]
        cell.textLabel?.text = detail.label
        cell.detailTextLabel?.text = detail.value
        cell.selectionStyle = .none
        cell.accessibilityLabel = detail.label
        cell.accessibilityValue = detail.value
        return cell
    }

    @objc private func connectToServer() {
        connect(link.server)
    }
}

class AppUpdateParser : NSObject, XMLParserDelegate {

    var elementStack = [String]()
    var update = ""
    var registerUrl = ""
    
    func parser(_ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String : String]) {
        
        elementStack.append(elementName)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let path = getXMLPath(elementStack: elementStack)
        switch path {
        case "/teamtalk/update/name" :
            update = string
        case "/teamtalk/bearware/register-url" :
            registerUrl = string
        default :
             print("Unknown path " + path)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?) {
        
        self.elementStack.removeLast()
    }

}

class ServerParser : NSObject, XMLParserDelegate {
    
    var currentServer = Server()
    var elementStack = [String]()
    var servers = [Server]()
    
    func parser(_ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String : String]) {
        
        elementStack.append(elementName)
        if elementName == "host" {
            currentServer = Server()
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        
        switch elementStack.last! {
        case "teamtalk" : break
        case "host" : break
        // <host>
        case "id" : break
        case "name" :
            currentServer.name = string
        case "address" :
            currentServer.ipaddr = string
        case "tcpport" :
            let v : String = string
            currentServer.tcpport = Int(v.trimmingCharacters(in: .whitespacesAndNewlines)) ?? currentServer.tcpport
        case "udpport" :
            let v : String = string
            currentServer.udpport = Int(v.trimmingCharacters(in: .whitespacesAndNewlines)) ?? currentServer.udpport
        case "encrypted" :
            currentServer.encrypted = string == "true"
        case "joincode" :
            currentServer.joincode = string
        case "listing" :
            break
        case "auth" : break
        case "join" : break
        // <auth>
        case "username" :
            currentServer.username = string
        // <auth> or <join>
        case "password" :
            if elementStack.firstIndex(of: "auth") != nil {
                currentServer.password = string
            }
            else if elementStack.firstIndex(of: "join") != nil {
                currentServer.chanpasswd = string
            }
        // <auth>
        case "nickname" :
            currentServer.nickname = string
        case "statusmsg" :
            currentServer.statusmsg = string
        case "channel" :
            currentServer.channel = string

        // <stats>
        case "stats" : break
        case "user-count" :
            currentServer.stats_usercount = Int(string) ?? 0
        case "country" :
            currentServer.stats_country = string
        case "servername" :
            currentServer.stats_servername += string
        case "motd" :
            currentServer.stats_motd += string
        case "active" :
            break
            
        // <trusted-certificate>
        case "trusted-certificate" : break
        case "certificate-authority-pem" :
            currentServer.cacertdata += string
        case "client-certificate-pem" :
            currentServer.certdata += string
        case "client-private-key-pem" :
            currentServer.certprivkeydata += string
        case "verify-peer" :
            currentServer.certverifypeer = string == "true"
        default :
            print("Unknown tag " + self.elementStack.last!)
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?) {
            
            self.elementStack.removeLast()
            if elementName == "host" {
                servers.append(currentServer)
            }
    }
    
}
