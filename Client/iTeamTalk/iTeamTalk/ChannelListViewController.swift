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
import AVFoundation
import SwiftUI

class ChannelListViewController :
    UIViewController, UITableViewDataSource,
    UITableViewDelegate, MyTextMessageDelegate, TeamTalkEvent  {

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard UIAccessibility.isVoiceOverRunning,
              let mainController = tabBarController as? MainTabBarController else {
            return super.accessibilityScroll(direction)
        }
        switch direction {
        case .left:
            return mainController.switchServer(offset: 1, announceForVoiceOver: true)
        case .right:
            return mainController.switchServer(offset: -1, announceForVoiceOver: true)
        default:
            return super.accessibilityScroll(direction)
        }
    }

    enum ChannelListRow {
        case channel(Channel, level: Int)
        case user(User, level: Int)
    }

    // all channels on server
    var channels = [INT32 : Channel]()
    // channel passwords
    var chanpasswds = [INT32 : String]()
    // the channel being displayed (not nescessarily the same channel as we're in)
    var curchannel = Channel()
    // joined channel (the channel we're in)
    var mychannel = Channel()
    // channel to join if connection is lost
    var rejoinchannel = Channel()
    var pendingNewChannelParentID: INT32?
    var pendingEditChannelID: INT32?
    // all users on server
    var users = [INT32 : User]()
    var peerSubscriptionsByUserID = [INT32 : Subscriptions]()
    // users which should be moved
    var moveusers = [INT32]()
    // the ID of the command for which we're expecting a result
    var cmdid : INT32 = 0
    // the command ID which is currently processing
    var currentCmdId : INT32 = 0
    // the commands awaiting reponse
    var activeCommands = [INT32: Command]()
    // properties of connected server
    var srvprop = ServerProperties()
    // local instance's user account
    var myuseraccount = UserAccount()
    // user to user text messages
    var textmessages = [INT32 : [MyTextMessage] ]()
    // timer for blinking unread messages
    var unreadTimer : Timer?
    // list of channels and users
    @IBOutlet weak var tableView: UITableView!
    // users being displayed in table-view
    var displayUsers = [User]()
    // channels (subchannels) being displayed in table-view
    var displayChans = [Channel]()
    // flattened, Windows-style channel tree shown in the table-view
    var displayRows = [ChannelListRow]()
    var expandedChannelIDs = Set<INT32>()
    // PTT button
    @IBOutlet weak var txButton: UIButton!
    // timeout for PTT lock
    var pttLockTimeout = Date()
    
    @IBOutlet weak var txButtonConstraint: NSLayoutConstraint!
    
    override func viewDidLoad() {
        super.viewDidLoad()

        tableView.dataSource = self
        tableView.delegate = self
        CompactUI.apply(to: self, title: NSLocalizedString("Channels", comment: "channel list"))
        CompactUI.apply(to: tableView)
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 44, bottom: 0, right: 12)
        configureBottomControls()
        if #available(iOS 13.0, *) {
        }
        else {
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(channelRowLongPressed(_:)))
            tableView.addGestureRecognizer(longPress)
        }
    
        updateTX()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        updateTX()

        // Height of bottom tab-controller changes depending on resolution
        if let tc = self.tabBarController {
            txButtonConstraint.constant = tc.tabBar.frame.size.height
        }
    }

    func configureBottomControls() {
        // Voice transmission is controlled from MainTabBarController's toolbar.
        // Keep the storyboard outlet available for the existing touch handlers,
        // but do not expose the old floating button on the channel list.
        txButton.isHidden = true
        txButton.isAccessibilityElement = false
        CompactUI.applyPrimaryButton(txButton, title: "")
        txButton.setTitle("", for: UIControl.State())
        txButton.tintColor = .white
        txButton.imageView?.contentMode = .scaleAspectFit
        txButton.layer.cornerRadius = 12
        txButton.clipsToBounds = true
        txButton.translatesAutoresizingMaskIntoConstraints = false

        let horizontalTXConstraints = view.constraints.filter { constraint in
            let firstMatches = constraint.firstItem === txButton && (constraint.firstAttribute == .leading || constraint.firstAttribute == .trailing)
            let secondMatches = constraint.secondItem === txButton && (constraint.secondAttribute == .leading || constraint.secondAttribute == .trailing)
            return firstMatches || secondMatches
        }
        NSLayoutConstraint.deactivate(horizontalTXConstraints)

        NSLayoutConstraint.activate([
            txButton.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            txButton.widthAnchor.constraint(equalToConstant: 56)
        ])
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
    }
    
    deinit {
        for (_, user) in users {
            syncToUserCache(user: user)
        }
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

    func clearServerState(reloadTable: Bool = true, preserveReconnectState: Bool = false) {
        channels.removeAll()
        users.removeAll()
        peerSubscriptionsByUserID.removeAll()
        moveusers.removeAll()
        displayUsers.removeAll()
        displayChans.removeAll()
        displayRows.removeAll()
        expandedChannelIDs.removeAll()
        curchannel = Channel()
        mychannel = Channel()
        pendingNewChannelParentID = nil
        pendingEditChannelID = nil
        cmdid = 0
        currentCmdId = 0
        activeCommands.removeAll()
        srvprop = ServerProperties()
        myuseraccount = UserAccount()
        if preserveReconnectState == false {
            rejoinchannel = Channel()
            chanpasswds.removeAll()
            textmessages.removeAll()
        }
        tabBarController?.navigationItem.title = NSLocalizedString("Channels", comment: "channel list")
        updateTX()

        if reloadTable {
            tableView.reloadData()
        }
    }
    
    @IBAction func joinChannel(_ sender: UIButton) {
        joinNewChannel(curchannel)
    }
    
    func joinNewChannel(_ channel: Channel) {
        if channel.bPassword == TRUE {
            
            var passwdField : UITextField?
            
            let passwdAlert = UIAlertController(title: NSLocalizedString("Enter Password", comment: "Dialog message"),
                                                message: NSLocalizedString("Password", comment: "Dialog message"),
                                                preferredStyle: .alert)
            passwdAlert.addTextField {(textField) in
                passwdField = textField
                passwdField?.autocorrectionType = .no
                passwdField?.spellCheckingType = .no
                passwdField?.autocapitalizationType = .none
                passwdField?.text = getChannel(channel, strprop: PASSWORD)
            }
            
            passwdAlert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "Dialog message"), style: .cancel, handler: { (pAction) in
                passwdAlert.dismiss(animated: true, completion: nil)
            }))
            
            passwdAlert.addAction(UIAlertAction(title: NSLocalizedString("Join", comment: "Dialog message"),
                                                style: .default, handler: { (pAction) in

                                                    let passwd = passwdField?.text
                                                    self.chanpasswds[channel.nChannelID] = passwd
                                                    self.expandChannelAndParents(channel.nChannelID)
                                                    self.cmdid = TT_DoJoinChannelByID(ttInst, channel.nChannelID, passwd)
                                                    self.activeCommands[self.cmdid] = .joinCmd

                                                    passwdAlert.dismiss(animated: true, completion: nil)
            }))
            
            self.present(passwdAlert, animated: true, completion: nil)
        }
        else {
            expandChannelAndParents(channel.nChannelID)
            cmdid = TT_DoJoinChannelByID(ttInst, channel.nChannelID, "")
            activeCommands[cmdid] = .joinCmd
        }
        
    }
    
    func appendTextMessage(_ userid: INT32, txtmsg: MyTextMessage) {
        
        if textmessages[userid] == nil {
            textmessages[userid] = [MyTextMessage]()
        }
        textmessages[userid]!.append(txtmsg)
        
        if textmessages[userid]!.count > MAX_TEXTMESSAGES {
            textmessages[userid]!.removeFirst()
        }
    }

    func clearTextMessages(_ userid: INT32) {
        textmessages.removeValue(forKey: userid)
        unreadmessages.remove(userid)
    }
    
    // MARK: Hooks
    // The monitor's channel list (MonitorChannelListViewController) shows
    // a server it does not hold a live connection to, so these ask about
    // "me" and permissions through methods it overrides.

    /// This client's own user ID on the server.
    func localUserID() -> INT32 {
        return TT_GetMyUserID(ttInst)
    }

    /// Whether a user is operator of a channel.
    func isChannelOperator(_ userID: INT32, channelID: INT32) -> Bool {
        return TT_IsChannelOperator(ttInst, userID, channelID) == TRUE
    }

    /// Whether this client is sending voice now.
    func isLocallyTransmittingVoice() -> Bool {
        guard let instance = ttInst else { return false }
        return isTransmitting(instance, stream: STREAMTYPE_VOICE)
    }

    /// Muting someone locally needs a live connection.
    var allowsLocalMute: Bool { true }

    /// Whether this client's own row shows the gender in Settings (a live
    /// connection's) rather than the one the server reports.
    var showsLocalGenderPreference: Bool { true }

    /// Creating and editing channels needs a live connection.
    var allowsChannelEditing: Bool { true }

    func getUsersCount(_ chanid: INT32) -> Int {
        
        var count = users.values.filter({$0.nChannelID == chanid}).count
        
        for c in channels.values.filter({$0.nParentID == chanid}) {
            count += getUsersCount(c.nChannelID)
        }
        
        return count
    }
    
    func updateDisplayItems()  {
        displayRows.removeAll()

        for user in sortedUsers(0) {
            displayRows.append(.user(user, level: 0))
        }

        let rootChannels = sortedChannels(channels.values.filter({$0.nParentID == 0}))
        for channel in rootChannels {
            appendChannelTree(channel, level: 0)
        }

        if displayRows.isEmpty {
            CompactUI.setEmptyState(on: tableView,
                                    title: NSLocalizedString("No channels yet", comment: "channel list"),
                                    message: NSLocalizedString("Connect to a server to see channels and users here.", comment: "channel list"))
        }
        else {
            CompactUI.clearEmptyState(on: tableView)
        }
    }

    func sortedChannels(_ chans: [Channel]) -> [Channel] {
        let settings = UserDefaults.standard
        let chansort = settings.object(forKey: PREF_DISPLAY_SORTCHANNELS) == nil ? ChanSort.ASCENDING.rawValue : settings.integer(forKey: PREF_DISPLAY_SORTCHANNELS)
        switch chansort {
        case ChanSort.POPULARITY.rawValue :
            return chans.sorted() {
                let aid = $0.nChannelID
                let bid = $1.nChannelID
                let au = users.values.filter({$0.nChannelID == aid})
                let bu = users.values.filter({$0.nChannelID == bid})
                let aname = getChannel($0, strprop: NAME)
                let bname = getChannel($1, strprop: NAME)
                return au.count == bu.count ?
                    aname.caseInsensitiveCompare(bname) == ComparisonResult.orderedAscending : au.count > bu.count
            }
        case ChanSort.ASCENDING.rawValue :
            fallthrough
        default :
            return chans.sorted() {
                let aname = getChannel($0, strprop: NAME)
                let bname = getChannel($1, strprop: NAME)
                return aname.caseInsensitiveCompare(bname) == ComparisonResult.orderedAscending
            }
        }
    }

    func sortedUsers(_ chanid: INT32) -> [User] {
        return users.values.filter({$0.nChannelID == chanid}).sorted() {
            getDisplayName($0).caseInsensitiveCompare(getDisplayName($1)) == ComparisonResult.orderedAscending
        }
    }

    func channelHasExpandableRows(_ channel: Channel) -> Bool {
        return users.values.contains(where: {$0.nChannelID == channel.nChannelID}) ||
            channels.values.contains(where: {$0.nParentID == channel.nChannelID})
    }

    func configureChannelDisclosureImage(_ imageView: UIImageView, channel: Channel, isExpanded: Bool) {
        imageView.contentMode = .center
        imageView.tintColor = CompactUI.secondaryTextColor
        imageView.isAccessibilityElement = false

        guard channelHasExpandableRows(channel) else {
            imageView.image = nil
            return
        }

        if #available(iOS 13.0, *) {
            let imageName = isExpanded ? "chevron.down" : "chevron.right"
            imageView.image = UIImage(systemName: imageName)
        }
        else {
            imageView.image = nil
        }
    }

    @available(iOS 14.0, *)
    func configureNativeChannelDisclosureCell(_ cell: ChannelTableCell, title: String, subtitle: String?, channelID: INT32, level: Int, isExpanded: Bool,
                                              actions: [(String, () -> Void)] = []) {
        cell.disclosureHostingController?.willMove(toParent: nil)
        cell.disclosureHostingController?.view.removeFromSuperview()
        cell.disclosureHostingController?.removeFromParent()

        let headerView = NativeDisclosureHeader(title: title, subtitle: subtitle, isExpanded: isExpanded, leadingPadding: CGFloat(16 + (level * 20)),
                                                actions: actions) { [weak self] in
            self?.toggleChannelExpanded(channelID)
        }
        let host = UIHostingController(rootView: headerView)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = CompactUI.secondaryBackgroundColor

        addChild(host)
        cell.contentView.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor)
        ])
        host.didMove(toParent: self)

        cell.disclosureHostingController = host
        cell.channame.isHidden = true
        cell.chanimage.isHidden = true
        cell.chantopicLabel.isHidden = true
        cell.isAccessibilityElement = false
        cell.accessibilityActivationHandler = nil
        cell.accessibilityCustomActions = nil
    }

    func expandChannelAndParents(_ channelID: INT32) {
        var currentChannelID = channelID
        while let channel = channels[currentChannelID] {
            expandedChannelIDs.insert(channel.nChannelID)
            if channel.nParentID == 0 {
                break
            }
            currentChannelID = channel.nParentID
        }
    }

    func appendChannelTree(_ channel: Channel, level: Int) {
        displayRows.append(.channel(channel, level: level))

        if expandedChannelIDs.contains(channel.nChannelID) == false {
            return
        }

        for user in sortedUsers(channel.nChannelID) {
            displayRows.append(.user(user, level: level + 1))
        }

        let childChannels = sortedChannels(channels.values.filter({$0.nParentID == channel.nChannelID}))
        for childChannel in childChannels {
            appendChannelTree(childChannel, level: level + 1)
        }
    }

    func configureUserName(_ label: UILabel, name: String, isAdmin: Bool) {
        guard isAdmin else {
            label.attributedText = nil
            label.text = name
            return
        }

        let text = NSMutableAttributedString(string: "\(name) ")
        if #available(iOS 13.0, *), let star = UIImage(systemName: "star.fill") {
            let attachment = NSTextAttachment()
            attachment.image = star.withTintColor(CompactUI.accentColor, renderingMode: .alwaysOriginal)
            attachment.bounds = CGRect(x: 0, y: -1.5, width: 13, height: 13)
            text.append(NSAttributedString(attachment: attachment))
        }
        else {
            text.append(NSAttributedString(string: "★"))
        }
        label.attributedText = text
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        
        updateDisplayItems()
        return displayRows.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {

        if indexPath.row >= displayRows.count {
            return UITableViewCell(style: .default, reuseIdentifier: nil)
        }

        switch displayRows[indexPath.row] {
        case .user(let user, let level):
            
            let cellIdentifier = "UserTableCell"
            let cell = tableView.dequeueReusableCell(withIdentifier: cellIdentifier, for: indexPath) as! UserTableCell
            let name = getDisplayName(user)
            let statusmsg = getUser(user, strprop: STATUSMSG)
            
            cell.indentationLevel = level
            cell.backgroundColor = CompactUI.secondaryBackgroundColor
            cell.selectedBackgroundView = UIView()
            cell.selectedBackgroundView?.backgroundColor = CompactUI.accentColor.withAlphaComponent(0.12)
            CompactUI.stylePrimaryLabel(cell.nicknameLabel)
            CompactUI.styleSecondaryLabel(cell.statusmsgLabel)
            cell.statusmsgLabel.text = statusmsg.isEmpty ? NSLocalizedString("Available", comment: "channel list") : statusmsg
            
            let female = (UInt(user.nStatusMode) & StatusMode.STATUSMODE_FEMALE.rawValue) != 0
            let neutral = (UInt(user.nStatusMode) & StatusMode.STATUSMODE_NEUTRAL.rawValue) != 0
            let isAdmin = (user.uUserType & USERTYPE_ADMIN.rawValue) != 0
            let isMe = localUserID() == user.nUserID
            let talking = user.uUserState & USERSTATE_VOICE.rawValue != 0 ||
                (isMe && isLocallyTransmittingVoice())
            let useLocalGender = isMe && showsLocalGenderPreference
            let useLocalMaleIcon = useLocalGender && preferredGenderIndex() == 0
            let useLocalNeutralIcon = useLocalGender && preferredGenderIndex() == 2
            let genderAccessibilityLabel: String
            if female {
                genderAccessibilityLabel = NSLocalizedString("Female", comment: "channel list")
            }
            else if neutral || useLocalNeutralIcon {
                genderAccessibilityLabel = NSLocalizedString("Neutral", comment: "channel list")
            }
            else {
                genderAccessibilityLabel = NSLocalizedString("Male", comment: "channel list")
            }
            configureUserName(cell.nicknameLabel, name: name, isAdmin: isAdmin)
            let adminAccessibilityLabel = isAdmin ? NSLocalizedString("Administrator", comment: "channel list") : ""
            cell.userImage.tintColor = nil

            if female || (neutral == false && useLocalNeutralIcon == false) || useLocalMaleIcon {
                cell.userImage.image = UIImage(named: female ? (talking ? "woman_green.png" : "woman_blue.png") : (talking ? "man_green.png" : "man_blue.png"))
            }
            else if #available(iOS 13.0, *) {
                cell.userImage.image = UIImage(systemName: "person.fill")
                cell.userImage.tintColor = talking ? UIColor.systemGreen : CompactUI.accentColor
            }
            else {
                cell.userImage.image = UIImage(named: talking ? "man_green.png" : "man_blue.png")
            }

            var voiceStateAccessibilityLabel = ""
            if talking {
                voiceStateAccessibilityLabel = NSLocalizedString("Speaking", comment: "channel list")
            }
            cell.userImage.accessibilityLabel = [genderAccessibilityLabel, adminAccessibilityLabel, voiceStateAccessibilityLabel]
                .filter({$0.isEmpty == false})
                .joined(separator: ", ")

            cell.isAccessibilityElement = true
            cell.nicknameLabel.isAccessibilityElement = false
            cell.statusmsgLabel.isAccessibilityElement = false
            cell.userImage.isAccessibilityElement = false
            cell.messageBtn.isAccessibilityElement = false
            cell.accessibilityTraits = [.button]
            cell.accessibilityLabel = [name, voiceStateAccessibilityLabel, statusmsg, genderAccessibilityLabel, adminAccessibilityLabel]
                .compactMap({$0})
                .filter({$0.isEmpty == false})
                .joined(separator: ", ")
            
            cell.messageBtn.tag = Int(user.nUserID)
            cell.tag = Int(user.nUserID)
            
            if #available(iOS 8.0, *) {
                let action_msg = MyCustomAction(name: NSLocalizedString("Send private message", comment: "channel list"), target: self, selector: #selector(ChannelListViewController.messageUser(_:)), tag: cell.tag)
                let mutedVoice = (user.uUserState & USERSTATE_MUTE_VOICE.rawValue) != 0
                let action_mute = MyCustomAction(name: mutedVoice ? NSLocalizedString("Unmute", comment: "channel list") : NSLocalizedString("Mute", comment: "channel list"),
                                                 target: self, selector: #selector(ChannelListViewController.muteUser(_:)), tag: cell.tag)

                var actions = [MyCustomAction]()
                actions.append(action_msg)
                if allowsLocalMute {
                    actions.append(action_mute)
                }
                
                if (myuseraccount.uUserRights & USERRIGHT_MOVE_USERS.rawValue) != 0 {
                    let action_move = MyCustomAction(name: NSLocalizedString("Move user", comment: "channel list"), target: self, selector: #selector(ChannelListViewController.moveUser(_:)), tag: cell.tag)
                    actions.append(action_move)
                }
                
                let op = isChannelOperator(localUserID(), channelID: user.nChannelID)
                if (myuseraccount.uUserRights & USERRIGHT_KICK_USERS.rawValue) != 0 || op {
                    let action_kick = MyCustomAction(name: NSLocalizedString("Kick user", comment: "channel list"), target: self, selector: #selector(ChannelListViewController.kickUser(_:)), tag: cell.tag)
                    actions.append(action_kick)
                }
                
                if (myuseraccount.uUserRights & USERRIGHT_BAN_USERS.rawValue) != 0 || op {
                    let action_ban = MyCustomAction(name: NSLocalizedString("Ban user", comment: "channel list"), target: self, selector: #selector(ChannelListViewController.banUser(_:)), tag: cell.tag)
                    actions.append(action_ban)
                }

                cell.accessibilityCustomActions = actions
            } else {
                // Fallback on earlier versions
            }
            
            return cell
        case .channel(let channel, let level):
        let cellIdentifier = "ChannelTableCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: cellIdentifier, for: indexPath) as! ChannelTableCell
        
        let textcolor : UIColor? = nil
        var title : String?, subtitle : String?
        let isExpanded = expandedChannelIDs.contains(channel.nChannelID)

        configureChannelDisclosureImage(cell.chanimage, channel: channel, isExpanded: isExpanded)

        if channel.nParentID == 0 {
            title = String(cString: getServerPropertiesString(SERVERNAME, &srvprop))
            subtitle = getChannel(channel, strprop: TOPIC)
        }
        else {
            let user_count = getUsersCount(channel.nChannelID)
            title = getChannel(channel, strprop: NAME) + " (\(user_count))"
            subtitle = getChannel(channel, strprop: TOPIC)
        }
        
        cell.indentationLevel = level
        cell.backgroundColor = CompactUI.secondaryBackgroundColor
        cell.selectedBackgroundView = UIView()
        cell.selectedBackgroundView?.backgroundColor = CompactUI.accentColor.withAlphaComponent(0.12)
        CompactUI.stylePrimaryLabel(cell.channame)
        CompactUI.styleSecondaryLabel(cell.chantopicLabel)
        cell.channame.textColor = textcolor
        cell.chantopicLabel.textColor = textcolor
        cell.editBtn.isHidden = true
        cell.editBtn.isEnabled = false
        
        cell.channame.text = limitText(title!)
        cell.chantopicLabel.text = subtitle
        
        cell.editBtn.tag = Int(channel.nChannelID)
        cell.tag = Int(channel.nChannelID)

        if #available(iOS 14.0, *) {
            configureNativeChannelDisclosureCell(cell, title: limitText(title!), subtitle: subtitle, channelID: channel.nChannelID, level: level, isExpanded: isExpanded)
        }
        else {
            cell.isAccessibilityElement = true
            cell.channame.isAccessibilityElement = false
            cell.chantopicLabel.isAccessibilityElement = false
            cell.chanimage.isAccessibilityElement = false
            cell.editBtn.isAccessibilityElement = false
            cell.accessibilityTraits = [.button, .header]
            cell.accessibilityValue = nil
            cell.accessibilityActivationHandler = { [weak self] in
                self?.toggleChannelExpanded(channel.nChannelID)
                return true
            }
            cell.accessibilityLabel = [title, subtitle]
                .compactMap({$0})
                .filter({$0.isEmpty == false})
                .joined(separator: ", ")
        }
        
        if #available(iOS 8.0, *) {
            
            var actions = [MyCustomAction]()

            if moveusers.count > 0 {
                let action_move = MyCustomAction(name: NSLocalizedString("Move users here", comment: "channel list"), target: self, selector: #selector(ChannelListViewController.moveIntoChannel(_:)), tag: cell.tag)
                actions.append(action_move)
            }
            
            if channel.nChannelID == mychannel.nChannelID {
                let action_leave = MyCustomAction(name: NSLocalizedString("Leave channel", comment: "channel list"), target: self, selector: #selector(ChannelListViewController.leaveCurrentChannel(_:)), tag: cell.tag)
                actions.append(action_leave)
            }
            else {
                let action_join = MyCustomAction(name: NSLocalizedString("Join channel", comment: "channel list"), target: self, selector: #selector(ChannelListViewController.joinThisChannel(_:)), tag: cell.tag)
                actions.append(action_join)
            }

            if allowsChannelEditing {
                let action_create = MyCustomAction(name: NSLocalizedString("Create Channel", comment: "channel list"), target: self, selector: #selector(ChannelListViewController.createChannelInChannel(_:)), tag: cell.tag)
                actions.append(action_create)

                let editTitle = channelEditActionTitle(channel)
                let action_edit = MyCustomAction(name: editTitle, target: self, selector: #selector(ChannelListViewController.editChannel(_:)), tag: cell.tag)
                actions.append(action_edit)
            }
            
            cell.accessibilityCustomActions = actions
            // The header (SwiftUI) is what VoiceOver reads, so the actions go
            // on it: Edit, Create Channel, Join or Leave, Move users here.
            if #available(iOS 14.0, *) {
                let headerActions: [(String, () -> Void)] = actions.reversed().map { action in
                    (action.name, { [weak self] in _ = self?.perform(action.selector, with: action) })
                }
                configureNativeChannelDisclosureCell(cell, title: limitText(title!), subtitle: subtitle, channelID: channel.nChannelID,
                                                     level: level, isExpanded: isExpanded, actions: headerActions)
            }
        } else {
            // Fallback on earlier versions
        }
        return cell
        }
    }
    
    func canEditChannel(_ channel: Channel) -> Bool {
        let op = isChannelOperator(localUserID(), channelID: channel.nChannelID)
        return (myuseraccount.uUserRights & USERRIGHT_MODIFY_CHANNELS.rawValue) != 0 || op
    }

    func channelEditActionTitle(_ channel: Channel) -> String {
        return canEditChannel(channel) ?
            NSLocalizedString("Edit properties", comment: "channel list") :
            NSLocalizedString("View properties", comment: "channel list")
    }

    func configureChannelActionsButton(_ button: UIButton, channel: Channel) {
        button.tag = Int(channel.nChannelID)
        button.tintColor = CompactUI.accentColor
        if #available(iOS 13.0, *) {
            button.setTitle("", for: UIControl.State())
            button.setImage(UIImage(systemName: "line.3.horizontal"), for: UIControl.State())
        }
        else {
            button.setImage(nil, for: UIControl.State())
            button.setTitle(NSLocalizedString("Actions", comment: "channel list"), for: UIControl.State())
        }
        button.accessibilityLabel = NSLocalizedString("Actions", comment: "channel list")
        button.removeTarget(nil, action: nil, for: .allEvents)

        if #available(iOS 14.0, *) {
            let joinLeaveAction: UIAction
            if channel.nChannelID == mychannel.nChannelID {
                joinLeaveAction = UIAction(title: NSLocalizedString("Leave channel", comment: "channel list"), image: UIImage(systemName: "rectangle.portrait.and.arrow.right")) { [weak self] _ in
                    self?.leaveCurrentChannel()
                }
            }
            else {
                joinLeaveAction = UIAction(title: NSLocalizedString("Join channel", comment: "channel list"), image: UIImage(systemName: "rectangle.portrait.and.arrow.forward")) { [weak self] _ in
                    self?.joinChannelWithID(channel.nChannelID)
                }
            }
            let createAction = UIAction(title: NSLocalizedString("Create Channel", comment: "channel list"), image: UIImage(systemName: "plus.square")) { [weak self] _ in
                self?.createChannelInside(channel.nChannelID)
            }
            let editAction = UIAction(title: channelEditActionTitle(channel), image: UIImage(systemName: "square.and.pencil")) { [weak self] _ in
                self?.editChannelWithID(channel.nChannelID)
            }
            button.menu = UIMenu(title: "", children: allowsChannelEditing ? [joinLeaveAction, createAction, editAction] : [joinLeaveAction])
            button.showsMenuAsPrimaryAction = true
        }
        else {
            button.addTarget(self, action: #selector(showChannelActions(_:)), for: .touchUpInside)
        }
    }

    func joinChannelWithID(_ channelID: INT32) {
        if let channel = channels[channelID] {
            joinNewChannel(channel)
        }
    }

    func leaveCurrentChannel() {
        if mychannel.nChannelID > 0 {
            cmdid = TT_DoLeaveChannel(ttInst)
            activeCommands[cmdid] = .leaveCmd
        }
    }

    func createChannelInside(_ channelID: INT32) {
        guard let chanDetail = storyboard?.instantiateViewController(withIdentifier: "EditChannel") as? ChannelDetailViewController else {
            return
        }

        var parentID = channelID
        if parentID == 0 {
            let rootChannels = channels.values.filter({$0.nParentID == 0})
            if let root = rootChannels.first {
                parentID = root.nChannelID
            }
        }

        chanDetail.channel.nParentID = parentID
        navigationController?.pushViewController(chanDetail, animated: true)
    }

    func editChannelWithID(_ channelID: INT32) {
        guard let channel = channels[channelID],
              let chanDetail = storyboard?.instantiateViewController(withIdentifier: "EditChannel") as? ChannelDetailViewController else {
            return
        }

        chanDetail.channel = channel
        if getChannel(channel, strprop: PASSWORD).isEmpty, let passwd = chanpasswds[channelID] {
            setChannelString(PASSWORD, &chanDetail.channel, passwd)
        }

        if let nav = navigationController {
            nav.pushViewController(chanDetail, animated: true)
        }
        else {
            tabBarController?.navigationController?.pushViewController(chanDetail, animated: true)
        }
    }

    @objc func channelRowLongPressed(_ sender: UILongPressGestureRecognizer) {
        guard sender.state == .began else { return }

        let point = sender.location(in: tableView)
        guard let indexPath = tableView.indexPathForRow(at: point),
              case .channel(let channel, _) = displayRows[indexPath.row] else {
            return
        }

        if let cell = tableView.cellForRow(at: indexPath) {
            showChannelActions(channelID: channel.nChannelID, sourceView: cell, sourceRect: cell.bounds)
        }
    }

    func showChannelActions(channelID: INT32, sourceView: UIView, sourceRect: CGRect) {
        guard let channel = channels[channelID] else {
            return
        }

        let title = channel.nParentID == 0 ? NSLocalizedString("root", comment: "channel list") : getChannel(channel, strprop: NAME)
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        if channelID == mychannel.nChannelID {
            alert.addAction(UIAlertAction(title: NSLocalizedString("Leave channel", comment: "channel list"), style: .default) { _ in
                self.leaveCurrentChannel()
            })
        }
        else {
            alert.addAction(UIAlertAction(title: NSLocalizedString("Join channel", comment: "channel list"), style: .default) { _ in
                self.joinChannelWithID(channelID)
            })
        }
        if allowsChannelEditing {
            alert.addAction(UIAlertAction(title: NSLocalizedString("Create Channel", comment: "channel list"), style: .default) { _ in
                self.createChannelInside(channelID)
            })
            alert.addAction(UIAlertAction(title: self.channelEditActionTitle(channel), style: .default) { _ in
                self.editChannelWithID(channelID)
            })
        }
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "Dialog message"), style: .cancel, handler: nil))
        alert.popoverPresentationController?.sourceView = sourceView
        alert.popoverPresentationController?.sourceRect = sourceRect
        present(alert, animated: true, completion: nil)
    }

    @objc func showChannelActions(_ sender: UIButton) {
        showChannelActions(channelID: INT32(sender.tag), sourceView: sender, sourceRect: sender.bounds)
    }

    @available(iOS 13.0, *)
    func tableView(_ tableView: UITableView,
                   contextMenuConfigurationForRowAt indexPath: IndexPath,
                   point: CGPoint) -> UIContextMenuConfiguration? {
        guard case .channel(let channel, _) = displayRows[indexPath.row] else {
            return nil
        }

        let channelID = channel.nChannelID
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let joinLeaveAction: UIAction
            if channelID == self.mychannel.nChannelID {
                joinLeaveAction = UIAction(title: NSLocalizedString("Leave channel", comment: "channel list"),
                                           image: UIImage(systemName: "rectangle.portrait.and.arrow.right")) { _ in
                    self.leaveCurrentChannel()
                }
            }
            else {
                joinLeaveAction = UIAction(title: NSLocalizedString("Join channel", comment: "channel list"),
                                           image: UIImage(systemName: "rectangle.portrait.and.arrow.forward")) { _ in
                    self.joinChannelWithID(channelID)
                }
            }
            let createAction = UIAction(title: NSLocalizedString("Create Channel", comment: "channel list"),
                                        image: UIImage(systemName: "plus.square")) { _ in
                self.createChannelInside(channelID)
            }
            let editAction = UIAction(title: self.channelEditActionTitle(channel),
                                      image: UIImage(systemName: "square.and.pencil")) { _ in
                self.editChannelWithID(channelID)
            }
            return UIMenu(title: "", children: self.allowsChannelEditing ? [joinLeaveAction, createAction, editAction] : [joinLeaveAction])
        }
    }

    func toggleChannelExpanded(_ channelID: INT32) {
        if let channel = channels[channelID] {
            curchannel = channel
        }
        if expandedChannelIDs.contains(channelID) {
            expandedChannelIDs.remove(channelID)
        }
        else {
            expandedChannelIDs.insert(channelID)
        }
        tableView.reloadData()
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let cell = self.tableView.cellForRow(at: indexPath)
        if cell is ChannelTableCell {
            toggleChannelExpanded(INT32(cell!.tag))
        }
    }
    
    func updateTitle() {
        (tabBarController as? MainTabBarController)?.updatePublicServerName(currentServerName())
    }
    
    @objc @available(iOS 8.0, *)
    func messageUser(_ action: UIAccessibilityCustomAction) -> Bool {
        if let ac = action as? MyCustomAction {
            performSegue(withIdentifier: "New TextMessage", sender: ac)
        }
        return true
    }

    @objc @available(iOS 8.0, *)
    func muteUser(_ action: UIAccessibilityCustomAction) -> Bool {
        if let ac = action as? MyCustomAction {
            let userid = INT32(ac.tag)
            if let user = users[userid] {
                TT_SetUserMute(ttInst, userid, STREAMTYPE_MEDIAFILE_AUDIO,
                               (user.uUserState & USERSTATE_MUTE_MEDIAFILE.rawValue) == 0 ? TRUE : FALSE )
                TT_SetUserMute(ttInst, userid, STREAMTYPE_VOICE,
                               (user.uUserState & USERSTATE_MUTE_VOICE.rawValue) == 0 ? TRUE : FALSE )
                // tell TeamTalk event loop to send us an updated User-struct
                TT_PumpMessage(ttInst, CLIENTEVENT_USER_STATECHANGE, userid)
            }
            
        }
        return true
    }

    @objc @available(iOS 8.0, *)
    func moveUser(_ action: UIAccessibilityCustomAction) -> Bool {
        if let ac = action as? MyCustomAction {
            moveusers.append(INT32(ac.tag))
            self.tableView.reloadData() //need to update accessible actions on channels
        }
        return true
    }

    @objc @available(iOS 8.0, *)
    func kickUser(_ action: UIAccessibilityCustomAction) -> Bool {
        if let ac = action as? MyCustomAction {
            
            cmdid = TT_DoKickUser(ttInst, INT32(ac.tag), curchannel.nChannelID)
            activeCommands[cmdid] = .kickCmd
        }
        return true
    }

    @objc @available(iOS 8.0, *)
    func banUser(_ action: UIAccessibilityCustomAction) -> Bool {
        if let ac = action as? MyCustomAction {
            
            cmdid = TT_DoBanUser(ttInst, INT32(ac.tag), curchannel.nChannelID)
            activeCommands[cmdid] = .banCmd
            cmdid = TT_DoKickUser(ttInst, INT32(ac.tag), curchannel.nChannelID)
            activeCommands[cmdid] = .kickCmd
        }
        return true
    }

    @objc @available(iOS 8.0, *)
    func joinThisChannel(_ action: UIAccessibilityCustomAction) -> Bool {
        if let ac = action as? MyCustomAction {
            joinChannelWithID(INT32(ac.tag))
        }
        return true
    }

    @objc @available(iOS 8.0, *)
    func leaveCurrentChannel(_ action: UIAccessibilityCustomAction) -> Bool {
        leaveCurrentChannel()
        return true
    }

    @objc @available(iOS 8.0, *)
    func createChannelInChannel(_ action: UIAccessibilityCustomAction) -> Bool {
        if let ac = action as? MyCustomAction {
            createChannelInside(INT32(ac.tag))
        }
        return true
    }

    @objc @available(iOS 8.0, *)
    func editChannel(_ action: UIAccessibilityCustomAction) -> Bool {
        if let ac = action as? MyCustomAction {
            editChannelWithID(INT32(ac.tag))
        }
        return true
    }
    
    @objc @available(iOS 8.0, *)
    func moveIntoChannel(_ action: UIAccessibilityCustomAction) -> Bool {
        if let ac = action as? MyCustomAction {
            for userid in moveusers {
                cmdid = TT_DoMoveUser(ttInst, userid, INT32(ac.tag))
                activeCommands[cmdid] = .moveCmd
            }
            moveusers.removeAll()
        }
        return true
    }
    
    func commandComplete(_ active_cmdid : INT32) {

        let cmd = activeCommands[active_cmdid]
        
        if cmd == nil {
            return
        }
        
        switch cmd! {
            
        case .loginCmd :
            let flags = TT_GetFlags(ttInst)

            if (flags & CLIENT_AUTHORIZED.rawValue) != 0 {
                
                if rejoinchannel.nChannelID > 0 {
                    // if we were previously in a channel then rejoin
                    let passwd = chanpasswds[rejoinchannel.nChannelID] != nil ? chanpasswds[rejoinchannel.nChannelID] : getChannel(rejoinchannel, strprop: PASSWORD)
                    if chanpasswds[rejoinchannel.nChannelID] == nil {
                        // if channel password is from initial login (Server-struct) then we need to store it
                       chanpasswds[rejoinchannel.nChannelID] = getChannel(rejoinchannel, strprop: PASSWORD)
                    }
                    setChannelString(PASSWORD, &rejoinchannel, passwd!)
                    cmdid = TT_DoJoinChannel(ttInst, &rejoinchannel)
                    activeCommands[cmdid] = .joinCmd
                }
                else if getChannel(rejoinchannel, strprop: NAME).isEmpty == false {
                    // join from initial login
                    let passwd = getChannel(rejoinchannel, strprop: PASSWORD)
                    setChannelString(PASSWORD, &rejoinchannel, passwd)
                    cmdid = TT_DoJoinChannel(ttInst, &rejoinchannel)
                    activeCommands[cmdid] = .joinCmd
                }
                else if UserDefaults.standard.object(forKey: PREF_JOINROOTCHANNEL) == nil ||
                    UserDefaults.standard.bool(forKey: PREF_JOINROOTCHANNEL) {
                    //join root channel automatically (if enabled)
                    cmdid = TT_DoJoinChannelByID(ttInst, TT_GetRootChannelID(ttInst), "")
                    activeCommands[cmdid] = .joinCmd
                }
            }
        case .kickCmd :
            fallthrough
        case .joinCmd :
            fallthrough
        case .leaveCmd :
            fallthrough
        case .banCmd :
            fallthrough
        case .moveCmd :
            break
//        default :
//            print("Command #\(active_cmdid) is not a completion command")
        }

        activeCommands.removeValue(forKey: active_cmdid)
        
        self.tableView.reloadData()
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {

        if segue.identifier == "Show User" {
            let index = self.tableView.indexPathForSelectedRow
            let cell = self.tableView.cellForRow(at: index!)

            let userDetail = segue.destination as! UserDetailViewController
            userDetail.userid = INT32(cell!.tag)
        }
        else if segue.identifier == "New Channel" {
            let chanDetail = segue.destination as! ChannelDetailViewController
            chanDetail.channel.nParentID = pendingNewChannelParentID ?? curchannel.nChannelID
            pendingNewChannelParentID = nil
            
            if chanDetail.channel.nParentID == 0 {
                let subchans = channels.values.filter({$0.nParentID == 0})
                if let root = subchans.first {
                    chanDetail.channel.nParentID = root.nChannelID
                }
            }
        }
        else if segue.identifier == "Edit Channel" {
            
            var chanid : INT32 = pendingEditChannelID ?? 0
            pendingEditChannelID = nil
            
            if let btn = sender as? UIButton {
                chanid = INT32(btn.tag)
            }
            if #available(iOS 8.0, *) {
                if let ac = sender as? MyCustomAction {
                    chanid = INT32(ac.tag)
                }
            } else {
                // Fallback on earlier versions
            }

            if let channel = channels[chanid] {
                
                let chanDetail = segue.destination as! ChannelDetailViewController
                
                chanDetail.channel = channel
                
                if getChannel(channel, strprop: PASSWORD).isEmpty {
                    if let passwd = self.chanpasswds[chanid] {
                        setChannelString(PASSWORD, &chanDetail.channel, passwd)
                    }
                }
            }
        }
        else if segue.identifier == "New TextMessage" {

            var userid : INT32 = -1
            if let btn = sender as? UIButton {
                userid = INT32(btn.tag)
            }
            if #available(iOS 8.0, *) {
                if let action = sender as? MyCustomAction {
                    userid = INT32(action.tag)
                }
            } else {
                // Fallback on earlier versions
            }
            
            let txtmsgView = segue.destination as! TextMessageViewController
            openTextMessages(txtmsgView, userid: userid)
        }
    }
    
    @IBAction func openTextMessages(_ segue:UIStoryboardSegue) {

        let src_vc = segue.source as! UserDetailViewController
        
        let vc = self.storyboard?.instantiateViewController(withIdentifier: "Text Message") as! TextMessageViewController
        openTextMessages(vc, userid: src_vc.userid)
        self.navigationController?.pushViewController(vc, animated: true)

    }

    func openTextMessages(_ sender: TextMessageViewController, userid: INT32) {
        sender.userid = userid
        if let user = users[userid] {
            sender.conversationTitle = getDisplayName(user)
        }
        sender.delegate = self
        addToTTMessages(sender)
        if let msgs = self.textmessages[userid] {
            for m in msgs {
                sender.appendEventMessage(m)
            }
        }
    }
    
    @IBAction func closeTextMessages(_ segue:UIStoryboardSegue) {
        
        print("Closed messages")
        
    }

    func currentServerName() -> String {
        var properties = srvprop
        var serverName = String(cString: getServerPropertiesString(SERVERNAME, &properties))
        if serverName.isEmpty {
            var liveProperties = ServerProperties()
            if TT_GetServerProperties(ttInst, &liveProperties) == TRUE {
                serverName = String(cString: getServerPropertiesString(SERVERNAME, &liveProperties))
            }
        }
        return serverName.isEmpty ? NSLocalizedString("server", comment: "TTS EVENT") : serverName
    }

    func channelDisplayName(_ channel: Channel) -> String {
        if channel.nParentID == 0 {
            return NSLocalizedString("root", comment: "TTS EVENT")
        }

        let name = getChannel(channel, strprop: NAME)
        return name.isEmpty ? NSLocalizedString("channel", comment: "TTS EVENT") : name
    }

    func channelSupportsAudio(_ channel: Channel) -> Bool {
        return channel.nChannelID > 0 && channel.audiocodec.nCodec != NO_CODEC
    }

    func canUseVoiceTx() -> Bool {
        return channelSupportsAudio(mychannel) && canConfigureSoundDevicesForConnectedServer()
    }

    func isInChannel() -> Bool {
        return mychannel.nChannelID > 0
    }
    
    @IBAction func txBtnDown(_ sender: UIButton) {
        enableVoiceTx(!isTransmitting(ttInst!, stream: STREAMTYPE_VOICE))
    }
    
    func enableVoiceTx(_ enable: Bool, playToggleSound: Bool = true) {
        let wasTransmitting = isTransmitting(ttInst!, stream: STREAMTYPE_VOICE)

        if enable {
            if canUseVoiceTx() == false {
                updateTX()
                return
            }
            setupSoundDevices(enableInput: true)
            updateAudioConfig()
        }
        else if wasTransmitting == false {
            updateTX()
            return
        }

        TT_EnableVoiceTransmission(ttInst, enable ? TRUE : FALSE)
        if enable == false && canReconfigureInitializedSoundDevices() {
            // Voice-Processing I/O is a coupled input/output unit. Reopen the
            // output-only path on Remote I/O so preprocessing is completely
            // inactive while the microphone is muted.
            setupSoundDevices(enableInput: false)
        }
        if playToggleSound {
            playSound(enable ? .tx_ON : .tx_OFF)
        }
        updateTX()

    }
    
    func txBtnUp() {
    }
    
    @IBAction func txBtnUpInside(_ sender: UIButton) {
        txBtnUp()
    }
    
    @IBAction func txBtnUpOutside(_ sender: UIButton) {
        txBtnUp()
    }

    func updateTXButtonImage(isTransmitting: Bool) {
        if #available(iOS 13.0, *) {
            let imageName = isTransmitting ? "mic.fill" : "mic.slash.fill"
            let configuration = UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
            txButton.setImage(UIImage(systemName: imageName, withConfiguration: configuration), for: UIControl.State())
            txButton.setTitle("", for: UIControl.State())
        }
        else {
            txButton.setImage(nil, for: UIControl.State())
            txButton.setTitle(isTransmitting ? NSLocalizedString("Mute", comment: "channel list") : NSLocalizedString("Unmute", comment: "channel list"), for: UIControl.State())
        }
    }
    
    func updateTX() {
        // Refresh the main toolbar for every channel-state change, including
        // joining/leaving channels that do not support audio.
        (tabBarController as? MainTabBarController)?.updateBottomToolbar()

        let canTransmitVoice = canUseVoiceTx()
        txButton.isHidden = true
        txButton.isAccessibilityElement = false
        if canTransmitVoice == false {
            txButton.accessibilityValue = NSLocalizedString("Unavailable", comment: "channel list")
            tableView.reloadData()
            return
        }
        
        let flags = TT_GetFlags(ttInst)
        
        switch flags & CLIENT_TX_VOICE.rawValue {
        case CLIENT_TX_VOICE.rawValue :
            txButton.backgroundColor = UIColor.red
            updateTXButtonImage(isTransmitting: true)
            txButton.accessibilityLabel = NSLocalizedString("Mute", comment: "channel list")
            txButton.accessibilityValue = nil
        default :
            txButton.backgroundColor = UIColor.green
            updateTXButtonImage(isTransmitting: false)
            txButton.accessibilityLabel = NSLocalizedString("Unmute", comment: "channel list")
            txButton.accessibilityValue = nil
        }
        
        tableView.reloadData()
        
    }
    
    @objc func timerUnreadBlinker(_ timer: Timer) {
        let cells = tableView.visibleCells
        for c in cells {
            if c.reuseIdentifier == "UserTableCell"  {
                let cell = c as! UserTableCell
                if unreadmessages.contains(INT32(c.tag)) {
                    let time = Int(Date().timeIntervalSince1970)
                    if time % 2 == 0 {
                        cell.messageBtn.setImage(UIImage(named: "message_red"), for: UIControl.State())
                    }
                    else {
                        cell.messageBtn.setImage(UIImage(named: "message_blue"), for: UIControl.State())
                    }
                }
                else {
                    cell.messageBtn.setImage(UIImage(named: "message_blue"), for: UIControl.State())
                }
            }
        }
        if unreadmessages.isEmpty {
            unreadTimer?.invalidate()
        }
    }
    
    func handleTTMessage(_ m: TTMessage) {
        var m = m
        
        switch(m.nClientEvent) {

        case CLIENTEVENT_CON_LOST :
            clearServerState(preserveReconnectState: true)
            break
            
        case CLIENTEVENT_CMD_PROCESSING :
            if getTTBOOL(&m) == TRUE {
                // command active
                self.currentCmdId = m.nSource
            }
            else {
                // command complete
                self.currentCmdId = 0
                
                commandComplete(m.nSource)
            }
        case CLIENTEVENT_CMD_ERROR :
            if activeCommands[m.nSource] != nil {
                let errmsg = getClientErrorMsg(m.clienterrormsg, strprop: ERRMESSAGE)
                if #available(iOS 8.0, *) {
                    let alert = UIAlertController(title: NSLocalizedString("Error", comment: "Dialog"), message: errmsg, preferredStyle: UIAlertController.Style.alert)
                    alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Dialog"), style: UIAlertAction.Style.default, handler: nil))
                    self.present(alert, animated: true, completion: nil)
                } else {
                    // Fallback on earlier versions
                }
            }
        case CLIENTEVENT_CMD_SERVER_UPDATE :
            srvprop = getServerProperties(&m).pointee
            updateTitle()
            tableView.reloadData()
            
        case CLIENTEVENT_CMD_MYSELF_LOGGEDIN :
            myuseraccount = getUserAccount(&m).pointee
            if (myuseraccount.uUserType & USERTYPE_ADMIN.rawValue) != 0 {
                // an admin user type can do everything
                myuseraccount.uUserRights = 0xFFFFFFFF
            }
            
        case CLIENTEVENT_CMD_CHANNEL_NEW :
            let channel = getChannel(&m).pointee
            
            channels[channel.nChannelID] = channel
            
            // initial title will be server name
            if channel.nParentID == 0 {
                updateTitle()
            }
            
            if currentCmdId == 0 {
                self.tableView.reloadData()
            }
            
        case CLIENTEVENT_CMD_CHANNEL_UPDATE :
            let channel = getChannel(&m).pointee
            channels[channel.nChannelID] = channel
            
            if mychannel.nChannelID == channel.nChannelID {
                
                let myuserid = TT_GetMyUserID(ttInst)
                if channel.transmitUsersQueue.0 == myuserid &&
                    mychannel.transmitUsersQueue.0 != myuserid {
                    playSound(.transmit_ON)
                }
                
                if mychannel.transmitUsersQueue.0 == myuserid &&
                    channel.transmitUsersQueue.0 != myuserid {
                    playSound(.transmit_OFF)
                }
                
                mychannel = channel
                
                updateAudioConfig()
                updateTX()
            }
            
            if currentCmdId == 0 {
                self.tableView.reloadData()
            }
            
        case CLIENTEVENT_CMD_CHANNEL_REMOVE :
            let channel = getChannel(&m).pointee
            channels.removeValue(forKey: channel.nChannelID)
            
            if currentCmdId == 0 {
                self.tableView.reloadData()
            }
            
        case CLIENTEVENT_CMD_USER_LOGGEDIN :
            
            let user = getUser(&m).pointee
            users[user.nUserID] = user
            peerSubscriptionsByUserID[user.nUserID] = user.uPeerSubscriptions

            let defaults = UserDefaults.standard
            if TT_GetMyUserID(ttInst) == user.nUserID {
                if defaults.object(forKey: PREF_TTSEVENT_USERLOGIN) == nil || defaults.bool(forKey: PREF_TTSEVENT_USERLOGIN) {
                    let message = String(format: NSLocalizedString("Logged in to %@", comment: "TTS EVENT"), currentServerName())
                    newUtterance(message)
                }
            }
            else if currentCmdId == 0 {
                playSound(.logged_IN)

                if defaults.object(forKey: PREF_TTSEVENT_USERLOGIN) == nil || defaults.bool(forKey: PREF_TTSEVENT_USERLOGIN) {
                    let name = getDisplayName(user)
                    if ConnectedServerManager.shared.sessions.count >= 2 {
                        let message = String(format: NSLocalizedString("%@ has logged in to %@", comment: "TTS EVENT"),
                                             name,
                                             currentServerName())
                        newUtterance(message)
                    }
                    else {
                        newUtterance(name + " " + NSLocalizedString("has logged in", comment: "TTS EVENT"))
                    }
                }
            }

            if currentCmdId == 0 {
                self.tableView.reloadData()
            }
            
        case CLIENTEVENT_CMD_USER_LOGGEDOUT :
            
            let user = getUser(&m).pointee
            users.removeValue(forKey: user.nUserID)
            peerSubscriptionsByUserID.removeValue(forKey: user.nUserID)

            if currentCmdId == 0 {
                self.tableView.reloadData()
                if TT_GetMyUserID(ttInst) != user.nUserID {
                    playSound(.logged_OUT)

                    let defaults = UserDefaults.standard
                    
                    if defaults.object(forKey: PREF_TTSEVENT_USERLOGOUT) == nil || defaults.bool(forKey: PREF_TTSEVENT_USERLOGOUT) {
                        let name = getDisplayName(user)
                        if ConnectedServerManager.shared.sessions.count >= 2 {
                            let message = String(format: NSLocalizedString("%@ has logged out of %@", comment: "TTS EVENT"),
                                                 name,
                                                 currentServerName())
                            newUtterance(message)
                        }
                        else {
                            newUtterance(name + " " + NSLocalizedString("has logged out", comment: "TTS EVENT"))
                        }
                    }
                }
            }
            
        case CLIENTEVENT_CMD_USER_JOINED :
            let user = getUser(&m).pointee
            users[user.nUserID] = user
            peerSubscriptionsByUserID[user.nUserID] = user.uPeerSubscriptions
            
            // we joined a new channel so update table view
            if user.nUserID == TT_GetMyUserID(ttInst) {
                curchannel = channels[user.nChannelID]!
                mychannel = channels[user.nChannelID]!
                expandChannelAndParents(user.nChannelID)

                //store password if it's from initial login (Server-struct)
                if rejoinchannel.nChannelID == 0 && chanpasswds[user.nChannelID] == nil {
                   chanpasswds[user.nChannelID] = getChannel(rejoinchannel, strprop: PASSWORD)
                }
                rejoinchannel = channels[user.nChannelID]! //join this on connection lost

                updateTitle()
                if TT_GetFlags(ttInst) & CLIENT_TX_VOICE.rawValue != 0 {
                    enableVoiceTx(true, playToggleSound: false)
                }
                else if shouldUnmuteByDefault() && canUseVoiceTx() {
                    enableVoiceTx(true, playToggleSound: false)
                }
                else {
                    updateAudioConfig()
                    updateTX()
                }

                let defaults = UserDefaults.standard
                if defaults.object(forKey: PREF_TTSEVENT_JOINEDCHAN) == nil || defaults.bool(forKey: PREF_TTSEVENT_JOINEDCHAN) {
                    let message = String(format: NSLocalizedString("Joined channel %@", comment: "TTS EVENT"), channelDisplayName(mychannel))
                    newUtterance(message)
                }
            }
            else if user.nChannelID == mychannel.nChannelID && mychannel.nChannelID > 0 {
                if currentCmdId == 0 {
                    playSound(.joined_CHAN)
                }
                let defaults = UserDefaults.standard

                if currentCmdId == 0 &&
                    (defaults.object(forKey: PREF_TTSEVENT_JOINEDCHAN) == nil || defaults.bool(forKey: PREF_TTSEVENT_JOINEDCHAN)) {
                    let name = getDisplayName(user)
                    let message = String(format: NSLocalizedString("%@ joined channel", comment: "TTS EVENT"), name)
                    newUtterance(message)
                }
            }
            else if let channel = channels[user.nChannelID] {
                let defaults = UserDefaults.standard
                
                if currentCmdId == 0 &&
                    (defaults.object(forKey: PREF_TTSEVENT_JOINEDCHAN) == nil || defaults.bool(forKey: PREF_TTSEVENT_JOINEDCHAN)) {
                    let name = getDisplayName(user)
                    let channelName = channelDisplayName(channel)
                    let message = String(format: NSLocalizedString("%@ joined channel %@", comment: "TTS EVENT"), name, channelName)
                    newUtterance(message)
                }
            }

            if currentCmdId == 0 {
                self.tableView.reloadData()
            }
        case CLIENTEVENT_CMD_USER_UPDATE :
            let user = getUser(&m).pointee
            if user.nUserID != TT_GetMyUserID(ttInst),
               let previousPeerSubscriptions = peerSubscriptionsByUserID[user.nUserID],
               previousPeerSubscriptions != user.uPeerSubscriptions {
                speakSubscriptionChanges(for: user,
                                         previous: previousPeerSubscriptions,
                                         current: user.uPeerSubscriptions)
                notifyInterceptionChanges(for: user,
                                          previous: previousPeerSubscriptions,
                                          current: user.uPeerSubscriptions)
            }
            peerSubscriptionsByUserID[user.nUserID] = user.uPeerSubscriptions
            users[user.nUserID] = user
            
            if currentCmdId == 0 {
                self.tableView.reloadData()
            }
            
        case CLIENTEVENT_CMD_USER_LEFT :
            let user = getUser(&m).pointee
            users[user.nUserID] = user
            
            if myuseraccount.uUserRights & USERRIGHT_VIEW_ALL_USERS.rawValue == 0 {
                users.removeValue(forKey: user.nUserID)
            }
            else {
                users[user.nUserID] = user
            }
    
            if user.nUserID == TT_GetMyUserID(ttInst) {
                let leftChannelID = user.nChannelID > 0 ? user.nChannelID : m.nSource
                let leftChannel = channels[leftChannelID]
                expandedChannelIDs.remove(leftChannelID)
                curchannel = Channel()
                mychannel = Channel()
                rejoinchannel = Channel()
                updateTitle()
                updateTX()

                let defaults = UserDefaults.standard
                if defaults.object(forKey: PREF_TTSEVENT_LEFTCHAN) == nil || defaults.bool(forKey: PREF_TTSEVENT_LEFTCHAN),
                   let leftChannel = leftChannel {
                    let message = String(format: NSLocalizedString("Left channel %@", comment: "TTS EVENT"), channelDisplayName(leftChannel))
                    newUtterance(message)
                }
            }
            else if m.nSource == mychannel.nChannelID && mychannel.nChannelID > 0 {
                if currentCmdId == 0 {
                    playSound(.left_CHAN)
                }
                let defaults = UserDefaults.standard
                if currentCmdId == 0 &&
                    (defaults.object(forKey: PREF_TTSEVENT_LEFTCHAN) == nil || defaults.bool(forKey: PREF_TTSEVENT_LEFTCHAN)) {
                    let name = getDisplayName(user)
                    let message = String(format: NSLocalizedString("%@ left channel", comment: "TTS EVENT"), name)
                    newUtterance(message)
                }
            }
            else if let channel = channels[m.nSource] {
                let defaults = UserDefaults.standard
                if currentCmdId == 0 &&
                    (defaults.object(forKey: PREF_TTSEVENT_LEFTCHAN) == nil || defaults.bool(forKey: PREF_TTSEVENT_LEFTCHAN)) {
                    let name = getDisplayName(user)
                    let channelName = channelDisplayName(channel)
                    let message = String(format: NSLocalizedString("%@ left channel %@", comment: "TTS EVENT"), name, channelName)
                    newUtterance(message)
                }
            }
            
            if currentCmdId == 0 {
                self.tableView.reloadData()
            }
            
        case CLIENTEVENT_CMD_USER_TEXTMSG :
            let txtmsg = getTextMessage(&m).pointee
            
            if txtmsg.nMsgType == MSGTYPE_USER {
                
                let settings = UserDefaults.standard
                if let user = users[txtmsg.nFromUserID] {
                    let name = getDisplayName(user)
                    let newmsg = MyTextMessage(m: txtmsg, nickname: name,
                        msgtype: TT_GetMyUserID(ttInst) == txtmsg.nFromUserID ? .PRIV_IM_MYSELF : .PRIV_IM)
                    appendTextMessage(txtmsg.nFromUserID, txtmsg: newmsg)
                    
                    if unreadmessages.count == 0 {
                        if #available(iOS 10.0, *) {
                            self.unreadTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true, block: {s in self.timerUnreadBlinker(s)})
                        } else {
                            self.unreadTimer = Timer(timeInterval: 1.0, target: self,
                                                     selector: #selector(ChannelListViewController.timerUnreadBlinker(_:)),
                                                     userInfo: nil, repeats: true)
                        }
                    }
                    unreadmessages.insert(txtmsg.nFromUserID)                    
                }
                
                //ignore incoming message if text message view controller is already open
                if self.navigationController?.topViewController is TextMessageViewController {
                    let vc = self.navigationController?.topViewController as! TextMessageViewController
                    if vc.userid == txtmsg.nFromUserID {
                        break
                    }
                }
                
                if settings.object(forKey: PREF_DISPLAY_POPUPTXTMSG) == nil || settings.bool(forKey: PREF_DISPLAY_POPUPTXTMSG) {
                    let vc = self.storyboard?.instantiateViewController(withIdentifier: "Text Message") as! TextMessageViewController
                    openTextMessages(vc, userid: txtmsg.nFromUserID)
                    self.navigationController?.pushViewController(vc, animated: true)
                    if let m = vc.getLastEventMessage() {
                        speakTextMessage(txtmsg.nMsgType, mymsg: m)
                    }
                }
            }
            
        case CLIENTEVENT_CMD_ERROR :
            if m.nSource == cmdid {
                let errmsg = getClientErrorMsg(m.clienterrormsg, strprop: ERRMESSAGE)
                if #available(iOS 8.0, *) {
                    let alert = UIAlertController(title: NSLocalizedString("Error", comment: "Dialog message"), message: errmsg, preferredStyle: UIAlertController.Style.alert)
                    alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Dialog message"), style: UIAlertAction.Style.default, handler: nil))
                    self.present(alert, animated: true, completion: nil)
                } else {
                    // Fallback on earlier versions
                }
            }

        case CLIENTEVENT_USER_STATECHANGE :
            let user = getUser(&m).pointee
            users[user.nUserID] = user
            self.tableView.reloadData()
        
        default :
            //print("Unhandled message \(m.nClientEvent.rawValue)")
            break
        }
    }

    func updateAudioConfig() {
        if mychannel.audiocfg.bEnableAGC == TRUE {
            TT_SetSoundInputGainLevel(ttInst, INT32(SOUND_GAIN_DEFAULT.rawValue))
            var ap = newAudioPreprocessor(preprocessor: WEBRTC_AUDIOPREPROCESSOR)
            let gain = Float(mychannel.audiocfg.nGainLevel) / Float(CHANNEL_AUDIOCONFIG_MAX)
            ap.webrtc.gaincontroller2.fixeddigital.fGainDB = WEBRTC_GAINCONTROLLER2_FIXEDGAIN_MAX * gain
            ap.webrtc.gaincontroller2.bEnable = TRUE
            TT_SetSoundInputPreprocessEx(ttInst, &ap)
        }
        else {
            var ap = newAudioPreprocessor(preprocessor: TEAMTALK_AUDIOPREPROCESSOR)
            TT_SetSoundInputPreprocessEx(ttInst, &ap)
            
            // With one connection this is the persisted preference. With multiple
            // connections each TeamTalk instance keeps its temporary gain value.
            if ConnectedServerManager.shared.sessions.count <= 1 {
                let defaults = UserDefaults.standard
                let volumePercent = defaults.object(forKey: PREF_MICROPHONE_GAIN) == nil
                    ? DEFAULT_AUDIO_LEVEL_PERCENT
                    : defaults.integer(forKey: PREF_MICROPHONE_GAIN)
                TT_SetSoundInputGainLevel(ttInst, INT32(refVolume(Double(volumePercent))))
            }
        }
    }
}
