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

class JoinCodeCell : UITableViewCell {
    @IBOutlet weak var joincodecopyBtn: UIButton!
    @IBOutlet weak var joincodeLabel: UILabel!
}

class ServerDetailViewController : UITableViewController, UITextFieldDelegate {

    var server = Server()

    let SECTION_NAME = 0,
        SECTION_STATUS = 1,
        SECTION_CON = 2,
        SECTION_AUTH = 3,
        SECTION_DISPLAY = 4,
        SECTION_CHAN = 5,
        SECTION_COUNT = 6

    var nameItems = [UITableViewCell]()
    var statusItems = [UITableViewCell]()
    var displayItems = [UITableViewCell]()
    var conItems = [UITableViewCell]()
    var authItems = [UITableViewCell]()
    var chanItems = [UITableViewCell]()
    
    var namefield : UITextField?
    var ipaddrfield : UITextField?
    var tcpportfield : UITextField?
    var udpportfield : UITextField?
    var encryptedfield : UISwitch?
    var usernamefield : UITextField?
    var passwdfield : UITextField?
    var nicknamefield : UITextField?
    var statusmsgfield : UITextField?
    var chanfield : UITextField?
    var chpasswdfield : UITextField?
    var syncpasswdfield : UISwitch?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // ServerList Entry section
        let namecell = UITableViewCell(style: .default, reuseIdentifier: nil)
        namefield = newTableCellTextField(namecell, label: NSLocalizedString("Name", comment: "server entry"), initial: server.name)
        namefield!.delegate = self
        nameItems.append(namecell)

        // Status section
        if server.servertype != .LOCAL {
            let usercountcell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            usercountcell.selectionStyle = .none
            usercountcell.textLabel?.text = NSLocalizedString("Users Online", comment: "server entry")
            usercountcell.detailTextLabel?.text = String(server.stats_usercount)
            statusItems.append(usercountcell)
            
            let motdcell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            motdcell.selectionStyle = .none
            motdcell.textLabel?.text = NSLocalizedString("Message of the Day", comment: "server entry")
            motdcell.detailTextLabel?.text = server.stats_motd
            statusItems.append(motdcell)
            
            let countrycell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            countrycell.selectionStyle = .none
            countrycell.textLabel?.text = NSLocalizedString("Country", comment: "server entry")
            countrycell.detailTextLabel?.text = server.stats_country
            statusItems.append(countrycell)
        }

        // Display section
        let nicknamecell = UITableViewCell(style: .default, reuseIdentifier: nil)
        nicknamefield = newTableCellTextField(nicknamecell, label: NSLocalizedString("Nickname", comment: "server entry"), initial: server.nickname)
        nicknamefield!.delegate = self
        nicknamefield!.autocorrectionType = .no
        nicknamefield!.spellCheckingType = .no
        nicknamefield!.autocapitalizationType = .none
        displayItems.append(nicknamecell)

        let statusmsgcell = UITableViewCell(style: .default, reuseIdentifier: nil)
        statusmsgfield = newTableCellTextField(statusmsgcell, label: NSLocalizedString("Status Message", comment: "server entry"), initial: server.statusmsg)
        statusmsgfield!.delegate = self
        displayItems.append(statusmsgcell)

        // Connection section
        let ipaddrcell = UITableViewCell(style: .default, reuseIdentifier: nil)
        ipaddrfield = newTableCellTextField(ipaddrcell, label: NSLocalizedString("Host address", comment: "server entry"), initial: server.ipaddr)
        ipaddrfield!.delegate = self
        ipaddrfield!.keyboardType = .URL
        ipaddrfield!.spellCheckingType = .no
        ipaddrfield!.autocorrectionType = .no
        ipaddrfield!.autocapitalizationType = .none
        conItems.append(ipaddrcell)

        let tcpportcell = UITableViewCell(style: .default, reuseIdentifier: nil)
        tcpportfield = newTableCellTextField(tcpportcell, label: NSLocalizedString("TCP Port", comment: "server entry"), initial: String(server.tcpport))
        tcpportfield!.delegate = self
        tcpportfield!.keyboardType = .numberPad
        conItems.append(tcpportcell)

        let udpportcell = UITableViewCell(style: .default, reuseIdentifier: nil)
        udpportfield = newTableCellTextField(udpportcell, label: NSLocalizedString("UDP Port", comment: "server entry"), initial: String(server.udpport))
        udpportfield!.delegate = self
        udpportfield!.keyboardType = .numberPad
        conItems.append(udpportcell)

        let encryptedcell = UITableViewCell(style: .default, reuseIdentifier: nil)
        encryptedfield = newTableCellSwitch(encryptedcell, label: NSLocalizedString("Encrypted", comment: "server entry"), initial: server.encrypted)
        conItems.append(encryptedcell)

        refreshAuthorizationItems()
        
        //initial channel
        let chancell = UITableViewCell(style: .default, reuseIdentifier: nil)
        chanfield = newTableCellTextField(chancell, label: NSLocalizedString("Channel", comment: "server entry"), initial: server.channel)
        chanfield!.delegate = self
        chanfield!.autocorrectionType = .no
        chanfield!.spellCheckingType = .no
        chanfield!.autocapitalizationType = .none
        chanItems.append(chancell)

        let chpasswdcell = UITableViewCell(style: .default, reuseIdentifier: nil)
        chpasswdfield = newTableCellTextField(chpasswdcell, label: NSLocalizedString("Password", comment: "server entry"), initial: server.chanpasswd)
        chpasswdfield!.delegate = self
        chpasswdfield!.autocorrectionType = .no
        chpasswdfield!.spellCheckingType = .no
        chpasswdfield!.autocapitalizationType = .none
        chpasswdfield!.isSecureTextEntry = true
        chanItems.append(chpasswdcell)

        let showchpasswdcell = UITableViewCell(style: .default, reuseIdentifier: nil)
        let showchpasswdswitch = newTableCellSwitch(showchpasswdcell, label: NSLocalizedString("Show Channel Password", comment: "server entry"), initial: false)
        showchpasswdswitch.addAction(UIAction { [weak self] action in
            guard let field = self?.chpasswdfield, let toggle = action.sender as? UISwitch else { return }
            field.isSecureTextEntry = toggle.isOn == false
        }, for: .valueChanged)
        chanItems.append(showchpasswdcell)
        
        tableView.dataSource = self
        tableView.delegate = self
    }
    
    func refreshAuthorizationItems() {
        self.authItems.removeAll()
        
        // Authentication section
        let usernamecell = UITableViewCell(style: .default, reuseIdentifier: nil)
        usernamefield = newTableCellTextField(usernamecell, label: NSLocalizedString("Username", comment: "server entry"), initial: server.username)
        usernamefield!.delegate = self
        usernamefield!.autocorrectionType = .no
        usernamefield!.spellCheckingType = .no
        usernamefield!.autocapitalizationType = .none
        authItems.append(usernamecell)
        
        let passwdcell = UITableViewCell(style: .default, reuseIdentifier: nil)
        passwdfield = newTableCellTextField(passwdcell, label: NSLocalizedString("Password", comment: "server entry"), initial: server.password)
        passwdfield!.delegate = self
        passwdfield!.autocorrectionType = .no
        passwdfield!.spellCheckingType = .no
        passwdfield!.autocapitalizationType = .none
        passwdfield!.isSecureTextEntry = true
        authItems.append(passwdcell)

        let showpasswdcell = UITableViewCell(style: .default, reuseIdentifier: nil)
        let showpasswdswitch = newTableCellSwitch(showpasswdcell, label: NSLocalizedString("Show Password", comment: "server entry"), initial: false)
        showpasswdswitch.addAction(UIAction { [weak self] action in
            guard let field = self?.passwdfield, let toggle = action.sender as? UISwitch else { return }
            field.isSecureTextEntry = toggle.isOn == false
        }, for: .valueChanged)
        authItems.append(showpasswdcell)

        // Off: this server syncs to the NG Account without its passwords.
        let syncpasswdcell = UITableViewCell(style: .default, reuseIdentifier: nil)
        syncpasswdfield = newTableCellSwitch(syncpasswdcell, label: NSLocalizedString("Sync Passwords with NG Account", comment: "server entry"), initial: server.syncPassword)
        authItems.append(syncpasswdcell)
    }
    
    @objc func copyJoinCode() {
        UIPasteboard.general.string = self.server.joincode
    }
    
    func saveServerDetail() {
        server.name = namefield!.text!
        server.ipaddr = ipaddrfield!.text!
        if let n = Int(tcpportfield!.text!) {
            server.tcpport = n
        }
        if let n = Int(udpportfield!.text!) {
            server.udpport = n
        }
        server.encrypted = encryptedfield!.isOn
        let username = usernamefield!.text!.trimmingCharacters(in: .whitespacesAndNewlines)
        server.username = username
        server.password = passwdfield!.text!
        server.nickname = nicknamefield!.text!
        server.statusmsg = statusmsgfield!.text!
        server.servertype = .LOCAL
        let channame = chanfield!.text!.trimmingCharacters(in: .whitespacesAndNewlines)
        server.channel = channame
        server.chanpasswd = chpasswdfield!.text!
        server.syncPassword = syncpasswdfield?.isOn ?? true
    }
    
    func textFieldShouldReturn(_ textfield: UITextField) -> Bool {
        textfield.resignFirstResponder()
        return false
    }
    
    override func numberOfSections(in tableView: UITableView) -> Int {
        return SECTION_COUNT
    }
    
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case SECTION_NAME :
            return NSLocalizedString("Server List Entry", comment: "server entry")
        case SECTION_STATUS :
            return nil
        case SECTION_DISPLAY :
            return NSLocalizedString("User Display", comment: "server entry")
        case SECTION_CON :
            return NSLocalizedString("Connection", comment: "server entry")
        case SECTION_AUTH :
            return NSLocalizedString("Authentication", comment: "server entry")
        case SECTION_CHAN :
            return NSLocalizedString("Join Channel", comment: "server entry")
        default :
            return nil
        }
    }
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        
        switch section {
        case SECTION_NAME :
            return nameItems.count
        case SECTION_STATUS :
            return statusItems.count
        case SECTION_DISPLAY :
            return displayItems.count
        case SECTION_CON :
            return conItems.count
        case SECTION_AUTH :
            return authItems.count
        case SECTION_CHAN :
            return chanItems.count
        default :
            return 0
        }
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        
        switch indexPath.section {
        case SECTION_NAME :
            return nameItems[indexPath.row]
        case SECTION_STATUS :
            return statusItems[indexPath.row]
        case SECTION_DISPLAY :
            return displayItems[indexPath.row]
        case SECTION_CON :
            return conItems[indexPath.row]
        case SECTION_AUTH :
            return authItems[indexPath.row]
        case SECTION_CHAN :
            return chanItems[indexPath.row]
        default :
            break
        }
        
        return UITableViewCell()
    }
    
}
