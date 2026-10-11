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

class UserDetailViewController : UITableViewController, TeamTalkEvent {
    
    @IBOutlet weak var navtitle: UINavigationItem!
    var voiceslider: UISlider?
    var voiceswitch: UISwitch?
    var mediaslider: UISlider?
    var mediaswitch: UISwitch?
    
    var subusermsgswitch: UISwitch?
    var subchanmsgswitch: UISwitch?
    var subbcastmsgswitch: UISwitch?
    var subvoiceswitch: UISwitch?
    var subwebcamswitch: UISwitch?
    var submediafileswitch: UISwitch?
    var subdesktopswitch: UISwitch?

    var interceptusermsgswitch: UISwitch?
    var interceptchanmsgswitch: UISwitch?
    var interceptvoiceswitch: UISwitch?
    var interceptwebcamswitch: UISwitch?
    var interceptmediafileswitch: UISwitch?
    var interceptdesktopswitch: UISwitch?
    var isCurrentUserAdmin = false
    
    var userid : INT32 = 0, kick_cmdid : INT32 = 0, kickban_cmdid : INT32 = 0
    
    let SECTION_GENERAL = 0,
        SECTION_VOLUME = 1,
        SECTION_SUBSCRIPTIONS = 2,
        SECTION_INTERCEPT = 3,
        SECTION_ACTIONS = 4,
        SECTION_COUNT = 5
    
    var general_items = [UITableViewCell]()
    var action_items = [UITableViewCell]()
    var volume_items = [UITableViewCell]()
    var subscription_items = [UITableViewCell]()
    var intercept_items = [UITableViewCell]()
    var expandedSections = Set<Int>()
    var sectionHeaderHosts = [Int: UIViewController]()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let user = userForDisplay()
        isCurrentUserAdmin = currentUserIsAdmin()
        navtitle.title = getDisplayName(user)
        
        addToTTMessages(self)
        
        // general items
        addUserInfoRows(user)
        
        // volume items
        let voicevolcell = UITableViewCell(style: .default, reuseIdentifier: nil)
        voiceslider = newTableCellSlider(voicevolcell, label: NSLocalizedString("Voice Volume", comment: "user detail"), min: 0, max: 100, initial: Float(refVolumeToPercent(Int(user.nVolumeVoice))))
        voiceslider!.addTarget(self, action: #selector(UserDetailViewController.voiceVolumeChanged(_:)), for: .valueChanged)
        volume_items.append(voicevolcell)
        
        let voicemutecell = UITableViewCell(style: .default, reuseIdentifier: nil)
        voiceswitch = newTableCellSwitch(voicemutecell, label: NSLocalizedString("Mute Voice", comment: "user detail"), initial: (user.uUserState & USERSTATE_MUTE_VOICE.rawValue) != 0)
        voiceswitch!.addTarget(self, action: #selector(UserDetailViewController.muteVoice(_:)), for: .valueChanged)
        volume_items.append(voicemutecell)

        let mediavolcell = UITableViewCell(style: .default, reuseIdentifier: nil)
        mediaslider = newTableCellSlider(mediavolcell, label: NSLocalizedString("Media File Volume", comment: "user detail"), min: 0, max: 100, initial: Float(refVolumeToPercent(Int(user.nVolumeMediaFile))))
        mediaslider!.addTarget(self, action: #selector(UserDetailViewController.mediaVolumeChanged(_:)), for: .valueChanged)
        volume_items.append(mediavolcell)
        
        let mediamutecell = UITableViewCell(style: .default, reuseIdentifier: nil)
        mediaswitch = newTableCellSwitch(mediamutecell, label: NSLocalizedString("Mute Media File", comment: "user detail"), initial: (user.uUserState & USERSTATE_MUTE_MEDIAFILE.rawValue) != 0)
        mediaswitch!.addTarget(self, action: #selector(UserDetailViewController.muteMediaStream(_:)), for: .valueChanged)
        volume_items.append(mediamutecell)
        
        // subscription items
        let subusermsgcell = UITableViewCell(style: .default, reuseIdentifier: nil)
        subusermsgswitch = newTableCellSwitch(subusermsgcell, label: NSLocalizedString("User Messages", comment: "user detail"), initial: (user.uLocalSubscriptions & SUBSCRIBE_USER_MSG.rawValue) != 0)
        subusermsgswitch!.addTarget(self, action: #selector(UserDetailViewController.subscriptionChanged(_:)), for: .valueChanged)
        subscription_items.append(subusermsgcell)
        
        let subchanmsgcell = UITableViewCell(style: .default, reuseIdentifier: nil)
        subchanmsgswitch = newTableCellSwitch(subchanmsgcell, label: NSLocalizedString("Channel Messages", comment: "user detail"), initial: (user.uLocalSubscriptions & SUBSCRIBE_CHANNEL_MSG.rawValue) != 0)
        subchanmsgswitch!.addTarget(self, action: #selector(UserDetailViewController.subscriptionChanged(_:)), for: .valueChanged)
        subscription_items.append(subchanmsgcell)

        let subbcastmsgcell = UITableViewCell(style: .default, reuseIdentifier: nil)
        subbcastmsgswitch = newTableCellSwitch(subbcastmsgcell, label: NSLocalizedString("Broadcast Messages", comment: "user detail"), initial: (user.uLocalSubscriptions & SUBSCRIBE_BROADCAST_MSG.rawValue) != 0)
        subbcastmsgswitch!.addTarget(self, action: #selector(UserDetailViewController.subscriptionChanged(_:)), for: .valueChanged)
        subscription_items.append(subbcastmsgcell)

        let subvoicecell = UITableViewCell(style: .default, reuseIdentifier: nil)
        subvoiceswitch = newTableCellSwitch(subvoicecell, label: NSLocalizedString("Voice", comment: "user detail"), initial: (user.uLocalSubscriptions & SUBSCRIBE_VOICE.rawValue) != 0)
        subvoiceswitch!.addTarget(self, action: #selector(UserDetailViewController.subscriptionChanged(_:)), for: .valueChanged)
        subscription_items.append(subvoicecell)
        
        let subwebcamcell = UITableViewCell(style: .default, reuseIdentifier: nil)
        subwebcamswitch = newTableCellSwitch(subwebcamcell, label: NSLocalizedString("WebCam", comment: "user detail"), initial: (user.uLocalSubscriptions & SUBSCRIBE_VIDEOCAPTURE.rawValue) != 0)
        subwebcamswitch!.addTarget(self, action: #selector(UserDetailViewController.subscriptionChanged(_:)), for: .valueChanged)
        subscription_items.append(subwebcamcell)
        
        let submediafilecell = UITableViewCell(style: .default, reuseIdentifier: nil)
        submediafileswitch = newTableCellSwitch(submediafilecell, label: NSLocalizedString("Media File", comment: "user detail"), initial: (user.uLocalSubscriptions & SUBSCRIBE_MEDIAFILE.rawValue) != 0)
        submediafileswitch!.addTarget(self, action: #selector(UserDetailViewController.subscriptionChanged(_:)), for: .valueChanged)
        subscription_items.append(submediafilecell)
        
        let subdesktopcell = UITableViewCell(style: .default, reuseIdentifier: nil)
        subdesktopswitch = newTableCellSwitch(subdesktopcell, label: NSLocalizedString("Desktop", comment: "user detail"), initial: (user.uLocalSubscriptions & SUBSCRIBE_DESKTOP.rawValue) != 0)
        subdesktopswitch!.addTarget(self, action: #selector(UserDetailViewController.subscriptionChanged(_:)), for: .valueChanged)
        subscription_items.append(subdesktopcell)

        // intercept items
        if isCurrentUserAdmin {
            let interceptusermsgcell = UITableViewCell(style: .default, reuseIdentifier: nil)
            interceptusermsgswitch = newTableCellSwitch(interceptusermsgcell, label: NSLocalizedString("User Messages", comment: "user detail"), initial: (user.uLocalSubscriptions & SUBSCRIBE_INTERCEPT_USER_MSG.rawValue) != 0)
            interceptusermsgswitch!.addTarget(self, action: #selector(UserDetailViewController.interceptChanged(_:)), for: .valueChanged)
            intercept_items.append(interceptusermsgcell)

            let interceptchanmsgcell = UITableViewCell(style: .default, reuseIdentifier: nil)
            interceptchanmsgswitch = newTableCellSwitch(interceptchanmsgcell, label: NSLocalizedString("Channel Messages", comment: "user detail"), initial: (user.uLocalSubscriptions & SUBSCRIBE_INTERCEPT_CHANNEL_MSG.rawValue) != 0)
            interceptchanmsgswitch!.addTarget(self, action: #selector(UserDetailViewController.interceptChanged(_:)), for: .valueChanged)
            intercept_items.append(interceptchanmsgcell)

            let interceptvoicecell = UITableViewCell(style: .default, reuseIdentifier: nil)
            interceptvoiceswitch = newTableCellSwitch(interceptvoicecell, label: NSLocalizedString("Voice", comment: "user detail"), initial: (user.uLocalSubscriptions & SUBSCRIBE_INTERCEPT_VOICE.rawValue) != 0)
            interceptvoiceswitch!.addTarget(self, action: #selector(UserDetailViewController.interceptChanged(_:)), for: .valueChanged)
            intercept_items.append(interceptvoicecell)

            let interceptwebcamcell = UITableViewCell(style: .default, reuseIdentifier: nil)
            interceptwebcamswitch = newTableCellSwitch(interceptwebcamcell, label: NSLocalizedString("WebCam", comment: "user detail"), initial: (user.uLocalSubscriptions & SUBSCRIBE_INTERCEPT_VIDEOCAPTURE.rawValue) != 0)
            interceptwebcamswitch!.addTarget(self, action: #selector(UserDetailViewController.interceptChanged(_:)), for: .valueChanged)
            intercept_items.append(interceptwebcamcell)

            let interceptmediafilecell = UITableViewCell(style: .default, reuseIdentifier: nil)
            interceptmediafileswitch = newTableCellSwitch(interceptmediafilecell, label: NSLocalizedString("Media File", comment: "user detail"), initial: (user.uLocalSubscriptions & SUBSCRIBE_INTERCEPT_MEDIAFILE.rawValue) != 0)
            interceptmediafileswitch!.addTarget(self, action: #selector(UserDetailViewController.interceptChanged(_:)), for: .valueChanged)
            intercept_items.append(interceptmediafilecell)

            let interceptdesktopcell = UITableViewCell(style: .default, reuseIdentifier: nil)
            interceptdesktopswitch = newTableCellSwitch(interceptdesktopcell, label: NSLocalizedString("Desktop", comment: "user detail"), initial: (user.uLocalSubscriptions & SUBSCRIBE_INTERCEPT_DESKTOP.rawValue) != 0)
            interceptdesktopswitch!.addTarget(self, action: #selector(UserDetailViewController.interceptChanged(_:)), for: .valueChanged)
            intercept_items.append(interceptdesktopcell)
        }

        // action items
        let kickusercell = tableView.dequeueReusableCell(withIdentifier: "kickcell")
        action_items.append(kickusercell!)
        
        let kickbancell = tableView.dequeueReusableCell(withIdentifier: "kickbancell")
        action_items.append(kickbancell!)

        //        let sendmsgcell = tableView.dequeueReusableCellWithIdentifier("sendmessagecell")
        //        action_items.append(sendmsgcell!)
        
        tableView.dataSource = self
        tableView.delegate = self

    }

    // MARK: Hooks
    // The monitor's user details (MonitorUserDetailViewController) show
    // someone on a server it watches, without a live connection.

    /// The user to show.
    func userForDisplay() -> User {
        var user = User()
        TT_GetUser(ttInst, userid, &user)
        return user
    }

    /// Volume, subscriptions and intercepts need a live connection.
    var showsConnectionSections: Bool { true }

    func addUserInfoRows(_ user: User) {
        addInfoCell(label: NSLocalizedString("Nickname", comment: "user detail"),
                    value: getUser(user, strprop: NICKNAME))
        addInfoCell(label: NSLocalizedString("Username", comment: "user detail"),
                    value: getUser(user, strprop: USERNAME))
        addInfoCell(label: NSLocalizedString("User ID", comment: "user detail"),
                    value: "\(user.nUserID)")
        addInfoCell(label: NSLocalizedString("Status Message", comment: "user detail"),
                    value: getUser(user, strprop: STATUSMSG))
        addInfoCell(label: NSLocalizedString("Channel", comment: "user detail"),
                    value: channelName(for: user.nChannelID))
        addInfoCell(label: NSLocalizedString("Client", comment: "user detail"),
                    value: clientDisplayName(for: user))
        addInfoCell(label: NSLocalizedString("User Type", comment: "user detail"),
                    value: (user.uUserType & USERTYPE_ADMIN.rawValue) != 0 ? NSLocalizedString("Administrator", comment: "user detail") : NSLocalizedString("User", comment: "user detail"))

        if currentUserIsAdmin() {
            addInfoCell(label: NSLocalizedString("IP Address", comment: "user detail"),
                        value: getUser(user, strprop: IPADDR))
        }
    }

    func addInfoCell(label: String, value: String) {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedValue.isEmpty == false else {
            return
        }

        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.textLabel?.text = label
        cell.detailTextLabel?.text = trimmedValue
        cell.detailTextLabel?.numberOfLines = 0
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = label
        cell.accessibilityValue = trimmedValue
        cell.accessibilityTraits = [.button]
        general_items.append(cell)
    }

    func clientDisplayName(for user: User) -> String {
        let clientName = getUser(user, strprop: CLIENTNAME)
        let clientVersion = clientVersionString(from: user.uVersion)

        guard clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return clientVersion
        }

        guard clientVersion.isEmpty == false else {
            return clientName
        }

        return "\(clientName) \(clientVersion)"
    }

    func clientVersionString(from version: UINT32) -> String {
        guard version != 0 else {
            return ""
        }

        let major = (version >> 16) & 0xFF
        let minor = (version >> 8) & 0xFF
        let build = version & 0xFF
        return "\(major).\(minor).\(build)"
    }

    func channelName(for channelID: INT32) -> String {
        guard channelID > 0 else {
            return NSLocalizedString("No channel", comment: "user detail")
        }

        var channel = Channel()
        guard TT_GetChannel(ttInst, channelID, &channel) == TRUE else {
            return "\(channelID)"
        }

        let name = getChannel(channel, strprop: NAME)
        return name.isEmpty ? NSLocalizedString("root", comment: "user detail") : name
    }

    func currentUserIsAdmin() -> Bool {
        var currentUser = User()
        guard TT_GetUser(ttInst, TT_GetMyUserID(ttInst), &currentUser) == TRUE else {
            return false
        }

        return (currentUser.uUserType & USERTYPE_ADMIN.rawValue) != 0
    }

    @objc func voiceVolumeChanged(_ sender: UISlider) {
        TT_SetUserVolume(ttInst, userid, STREAMTYPE_VOICE, INT32(refVolume(Double(sender.value))))
        // tell TeamTalk event loop to send us an updated User-struct
        TT_PumpMessage(ttInst, CLIENTEVENT_USER_STATECHANGE, userid)
    }
    
    @objc func mediaVolumeChanged(_ sender: UISlider) {
        TT_SetUserVolume(ttInst, userid, STREAMTYPE_MEDIAFILE_AUDIO, INT32(refVolume(Double(sender.value))))
        // tell TeamTalk event loop to send us an updated User-struct
        TT_PumpMessage(ttInst, CLIENTEVENT_USER_STATECHANGE, userid)
    }
    
    @objc func muteVoice(_ sender: UISwitch) {
        TT_SetUserMute(ttInst, userid, STREAMTYPE_VOICE, (sender.isOn ? TRUE : FALSE))
        // tell TeamTalk event loop to send us an updated User-struct
        TT_PumpMessage(ttInst, CLIENTEVENT_USER_STATECHANGE, userid)
    }
    
    @objc func muteMediaStream(_ sender: UISwitch) {
        TT_SetUserMute(ttInst, userid, STREAMTYPE_MEDIAFILE_AUDIO, (sender.isOn ? TRUE : FALSE))
        // tell TeamTalk event loop to send us an updated User-struct
        TT_PumpMessage(ttInst, CLIENTEVENT_USER_STATECHANGE, userid)
    }
    
    @objc func subscriptionChanged(_ sender: UISwitch) {
        var sub = SUBSCRIBE_NONE
        
        switch sender {
        case subusermsgswitch! :
            sub = SUBSCRIBE_USER_MSG
        case subchanmsgswitch! :
            sub = SUBSCRIBE_CHANNEL_MSG
        case subbcastmsgswitch! :
            sub = SUBSCRIBE_BROADCAST_MSG
        case subvoiceswitch! :
            sub = SUBSCRIBE_VOICE
        case subwebcamswitch! :
            sub = SUBSCRIBE_VIDEOCAPTURE
        case submediafileswitch! :
            sub = SUBSCRIBE_MEDIAFILE
        case subdesktopswitch! :
            sub = SUBSCRIBE_DESKTOP
        default :
            break
        }
        
        if sender.isOn {
            TT_DoSubscribe(ttInst, userid, sub.rawValue)
        }
        else {
            TT_DoUnsubscribe(ttInst, userid, sub.rawValue)
        }
    }

    @objc func interceptChanged(_ sender: UISwitch) {
        var sub = SUBSCRIBE_NONE

        switch sender {
        case interceptusermsgswitch! :
            sub = SUBSCRIBE_INTERCEPT_USER_MSG
        case interceptchanmsgswitch! :
            sub = SUBSCRIBE_INTERCEPT_CHANNEL_MSG
        case interceptvoiceswitch! :
            sub = SUBSCRIBE_INTERCEPT_VOICE
        case interceptwebcamswitch! :
            sub = SUBSCRIBE_INTERCEPT_VIDEOCAPTURE
        case interceptmediafileswitch! :
            sub = SUBSCRIBE_INTERCEPT_MEDIAFILE
        case interceptdesktopswitch! :
            sub = SUBSCRIBE_INTERCEPT_DESKTOP
        default :
            break
        }

        if sender.isOn {
            TT_DoSubscribe(ttInst, userid, sub.rawValue)
        }
        else {
            TT_DoUnsubscribe(ttInst, userid, sub.rawValue)
        }
    }
    
    @IBAction func kickandbanUser(_ sender: UIButton) {
        var user = User()
        TT_GetUser(ttInst, userid, &user)
        
        kickban_cmdid = TT_DoKickUser(ttInst, userid, 0)
    }
    
    @IBAction func kickUser(_ sender: UIButton) {
        var user = User()
        TT_GetUser(ttInst, userid, &user)
        
        kick_cmdid = TT_DoKickUser(ttInst, userid, user.nChannelID)
    }
    
    override func numberOfSections(in tableView: UITableView) -> Int {
        return SECTION_COUNT
    }
    
    func titleForUserDetailSection(_ section: Int) -> String? {
        switch section {
        case SECTION_GENERAL :
            return NSLocalizedString("General", comment: "user detail")
        case SECTION_ACTIONS :
            return NSLocalizedString("Actions", comment: "user detail")
        case SECTION_VOLUME :
            return showsConnectionSections ? NSLocalizedString("Volume Controls", comment: "user detail") : nil
        case SECTION_SUBSCRIPTIONS :
            return showsConnectionSections ? NSLocalizedString("Subscriptions", comment: "user detail") : nil
        case SECTION_INTERCEPT :
            return intercept_items.isEmpty || !showsConnectionSections ? nil : NSLocalizedString("Intercept", comment: "user detail")
        default :
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return nil
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let title = titleForUserDetailSection(section) else {
            return nil
        }

        if #available(iOS 14.0, *) {
            if let existingHost = sectionHeaderHosts[section] {
                existingHost.willMove(toParent: nil)
                existingHost.view.removeFromSuperview()
                existingHost.removeFromParent()
            }

            let headerView = NativeDisclosureHeader(title: title, subtitle: nil, isExpanded: expandedSections.contains(section), leadingPadding: 16) { [weak self] in
                self?.toggleUserDetailSection(section)
            }
            let host = UIHostingController(rootView: headerView)
            host.view.backgroundColor = CompactUI.secondaryBackgroundColor
            addChild(host)
            host.didMove(toParent: self)
            sectionHeaderHosts[section] = host
            return host.view
        }

        let header = SettingsSectionHeaderView(reuseIdentifier: nil)
        header.tag = section
        header.configure(title: title, isExpanded: expandedSections.contains(section))
        header.accessibilityActivationHandler = { [weak self] in
            self?.toggleUserDetailSection(section)
            return true
        }
        header.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(userDetailSectionHeaderTapped(_:))))
        return header
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return titleForUserDetailSection(section) == nil ? 0 : UITableView.automaticDimension
    }

    override func tableView(_ tableView: UITableView, estimatedHeightForHeaderInSection section: Int) -> CGFloat {
        return titleForUserDetailSection(section) == nil ? 0 : 44
    }

    @objc func userDetailSectionHeaderTapped(_ sender: UITapGestureRecognizer) {
        guard let section = sender.view?.tag else { return }
        toggleUserDetailSection(section)
    }

    func toggleUserDetailSection(_ section: Int) {
        if expandedSections.contains(section) {
            expandedSections.remove(section)
        }
        else {
            expandedSections.insert(section)
        }
        tableView.reloadSections(IndexSet(integer: section), with: .automatic)
    }
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard titleForUserDetailSection(section) != nil && expandedSections.contains(section) else {
            return 0
        }

        switch section {
        case SECTION_GENERAL :
            return general_items.count
        case SECTION_ACTIONS :
            return action_items.count
        case SECTION_VOLUME :
            return volume_items.count
        case SECTION_SUBSCRIPTIONS :
            return subscription_items.count
        case SECTION_INTERCEPT :
            return intercept_items.count
        default : return 0
        }
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch indexPath.section {
        case SECTION_GENERAL :
            return general_items[indexPath.row]
        case SECTION_ACTIONS :
            return action_items[indexPath.row]
        case SECTION_VOLUME :
            return volume_items[indexPath.row]
        case SECTION_SUBSCRIPTIONS :
            return subscription_items[indexPath.row]
        case SECTION_INTERCEPT :
            return intercept_items[indexPath.row]
        default : return UITableViewCell()
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        guard indexPath.section == SECTION_GENERAL else {
            return
        }

        let cell = general_items[indexPath.row]
        guard let value = cell.accessibilityValue, value.isEmpty == false else {
            return
        }

        UIPasteboard.general.string = value
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            UIAccessibility.post(notification: .announcement,
                                 argument: NSLocalizedString("Copied to clipboard.", comment: "user detail"))
        }
    }

    func handleTTMessage(_ m: TTMessage) {
        switch m.nClientEvent {
            
        case CLIENTEVENT_CMD_SUCCESS :
            
            if m.nSource == kickban_cmdid {
                TT_DoBanUser(ttInst, userid, 0)
            }
            
        case CLIENTEVENT_CMD_ERROR :
            
            if m.nSource == kick_cmdid || m.nSource == kickban_cmdid {
                let errmsg = getClientErrorMsg(m.clienterrormsg, strprop: ERRMESSAGE)
                if #available(iOS 8.0, *) {
                    let alert = UIAlertController(title: NSLocalizedString("Error", comment: "user detail"), message: errmsg, preferredStyle: UIAlertController.Style.alert)
                    alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "user detail"), style: UIAlertAction.Style.default, handler: nil))
                    self.present(alert, animated: true, completion: nil)
                    
                } else {
                    // Fallback on earlier versions
                }
            }
        default :
            break
        }
    }
    
}
