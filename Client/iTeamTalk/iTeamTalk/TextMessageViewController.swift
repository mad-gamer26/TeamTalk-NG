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

class TextMessageViewController :
    UIViewController, UITableViewDataSource,
    UITableViewDelegate, TeamTalkEvent,
    UITextViewDelegate {

    private enum ChannelMessageFilter: Int {
        case userMessages = 0
        case serverEvents = 1
    }
    
    @IBOutlet weak var tableView: UITableView!
    @IBOutlet weak var msgTextView: UITextView!
    @IBOutlet weak var sendButton: UIButton!
    
    @IBOutlet weak var msgTextViewBottomConstraint: NSLayoutConstraint!
    @IBOutlet weak var sendButtonBottomConstraint: NSLayoutConstraint!
    
    // userid > 0 means private message session, i.e. MSGTYPE_USER
    var userid : INT32 = 0
    
    var delegate : MyTextMessageDelegate?
    var conversationTitle = ""

    var messages = [MyTextMessage]()
    private var channelMessageFilter = ChannelMessageFilter.userMessages
    private var messageFilterControl: UISegmentedControl?
    private var clearButton: UIButton?
    private var currentCmdId: INT32 = 0
    
    func generateKey(_ msg: TextMessage) -> Int {
        return (Int(msg.nMsgType.rawValue) << 16) | Int(msg.nFromUserID)
    }
    
    var mergemessages = [Int : [TextMessage] ]()
    
    func getTextMessageContent(_ msg: TextMessage) -> String? {
        var msg = msg
        let key = generateKey(msg)
        if msg.bMore == TRUE {
            if mergemessages[key] == nil {
                mergemessages[key] = [TextMessage]()
            }
            mergemessages[key]!.append(msg)
            
            // prevent out-of-memory
            if mergemessages[key]!.count > 1000 {
                mergemessages.removeValue(forKey: key)
            }
        }
        else if mergemessages[key] != nil {
            var content = ""
            for m in mergemessages[key]! {
                var m = m
                content += String(cString: getTextMessageString(MESSAGE, &m))
            }
            mergemessages.removeValue(forKey: key)
            return content + String(cString: getTextMessageString(MESSAGE, &msg))
        }
        else {
            return String(cString: getTextMessageString(MESSAGE, &msg))
        }
        return nil
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let def = NotificationCenter.default
        def.addObserver(self, selector: #selector(TextMessageViewController.keyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        def.addObserver(self, selector: #selector(TextMessageViewController.keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        
        resetText()
        
        tableView.dataSource = self
        tableView.delegate = self
        CompactUI.apply(to: self, title: viewTitle())
        CompactUI.apply(to: tableView)
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        
        msgTextView.delegate = self
        msgTextView.layer.cornerRadius = 8
        msgTextView.layer.borderWidth = 1
        msgTextView.layer.borderColor = CompactUI.secondaryTextColor.withAlphaComponent(0.25).cgColor
        msgTextView.font = UIFont.preferredFont(forTextStyle: .body)
        msgTextView.adjustsFontForContentSizeCategory = true
        CompactUI.applyPrimaryButton(sendButton, title: NSLocalizedString("Send", comment: "text message"))
        
        msgTextView.accessibilityLabel = NSLocalizedString("Message text", comment: "text message")
        configureMessageControls()
        updateEmptyState()
    }

    func viewTitle() -> String {
        if userid > 0 {
            if conversationTitle.isEmpty == false {
                return conversationTitle
            }

            var user = User()
            if TT_GetUser(ttInst, userid, &user) == TRUE {
                return getDisplayName(user)
            }
        }
        return NSLocalizedString("Messages", comment: "text message")
    }

    func updateEmptyState() {
        if visibleMessages().isEmpty {
            let message: String
            if userid == 0 {
                switch channelMessageFilter {
                case .userMessages:
                    message = NSLocalizedString("Channel messages will appear here.", comment: "text message")
                case .serverEvents:
                    message = NSLocalizedString("Server events will appear here.", comment: "text message")
                }
            }
            else {
                message = NSLocalizedString("Private messages will appear here.", comment: "text message")
            }
            CompactUI.setEmptyState(on: tableView,
                                    title: NSLocalizedString("No messages", comment: "text message"),
                                    message: message)
        }
        else {
            CompactUI.clearEmptyState(on: tableView)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        if self.isMovingFromParent {
            unreadmessages.remove(userid)
            if userid == 0 {
                resetChannelMessageScreenState()
            }
        }
    }

    func showLogMessages() -> Bool {
        return userid == 0
    }

    func channelLogDisplayName(_ channelID: INT32) -> String {
        var channel = Channel()
        guard TT_GetChannel(ttInst, channelID, &channel) == TRUE else {
            return NSLocalizedString("channel", comment: "log entry")
        }

        if channel.nParentID == 0 {
            return NSLocalizedString("root", comment: "log entry")
        }

        let name = getChannel(channel, strprop: NAME)
        return name.isEmpty ? NSLocalizedString("channel", comment: "log entry") : name
    }

    func appendLogMessage(_ text: String) {
        guard showLogMessages() else { return }

        let logmsg = MyTextMessage(logmsg: text)
        appendEventMessage(logmsg)
        
        if tableView != nil {
            updateTableView()
        }
    }

    func configureMessageControls() {
        guard userid == 0 else {
            tableView.tableHeaderView = nil
            updateClearButtonVisibility()
            return
        }

        let filterControl = UISegmentedControl(items: [
            NSLocalizedString("User Messages", comment: "text message"),
            NSLocalizedString("Server Events", comment: "text message")
        ])
        filterControl.selectedSegmentIndex = channelMessageFilter.rawValue
        filterControl.addTarget(self, action: #selector(channelMessageFilterChanged(_:)), for: .valueChanged)
        messageFilterControl = filterControl

        let clearButton = UIButton(type: .system)
        clearButton.setTitle(NSLocalizedString("Clear", comment: "text message"), for: .normal)
        clearButton.addTarget(self, action: #selector(confirmClearMessages), for: .touchUpInside)
        clearButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .body)
        clearButton.titleLabel?.adjustsFontForContentSizeCategory = true
        clearButton.setContentHuggingPriority(.required, for: .horizontal)
        self.clearButton = clearButton

        let container = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 52))
        let stack = UIStackView(arrangedSubviews: [filterControl, clearButton])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ])
        tableView.tableHeaderView = container
        updateClearButtonVisibility()
    }

    func updateClearButtonVisibility() {
        let hasMessages = messages.isEmpty == false

        if userid == 0 {
            navigationItem.rightBarButtonItem = nil
            clearButton?.isHidden = hasMessages == false
            return
        }

        navigationItem.rightBarButtonItem = hasMessages ?
            UIBarButtonItem(title: NSLocalizedString("Clear", comment: "text message"),
                            style: .plain,
                            target: self,
                            action: #selector(confirmClearMessages)) :
            nil
    }

    @objc func channelMessageFilterChanged(_ sender: UISegmentedControl) {
        channelMessageFilter = ChannelMessageFilter(rawValue: sender.selectedSegmentIndex) ?? .userMessages
        updateTableView(animated: false)
    }

    @objc func confirmClearMessages() {
        let title = userid == 0 ?
            NSLocalizedString("Clear Messages?", comment: "text message") :
            NSLocalizedString("Clear Conversation?", comment: "text message")
        let message = userid == 0 ?
            NSLocalizedString("This clears all messages and server events from this screen.", comment: "text message") :
            NSLocalizedString("This clears all messages from this private conversation screen.", comment: "text message")
        let alert = UIAlertController(title: title,
                                      message: message,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "message dialog"), style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: NSLocalizedString("Clear", comment: "message dialog"), style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            self.messages.removeAll()
            self.updateTableView(animated: false)
            if self.userid > 0 {
                self.delegate?.clearTextMessages(self.userid)
            }
        })
        present(alert, animated: true, completion: nil)
    }
    
    func appendEventMessage(_ m : MyTextMessage) {
        messages.append(m)

        if messages.count > MAX_TEXTMESSAGES {
            messages.removeFirst(messages.count - MAX_TEXTMESSAGES)
        }
    }
    
    func getEventMessage(_ indexPath : IndexPath) -> MyTextMessage {
        return visibleMessages()[indexPath.row]
    }
    
    func getLastEventMessage() -> MyTextMessage? {
        return messages.last
    }

    func visibleMessages() -> [MyTextMessage] {
        guard userid == 0 else { return messages }

        switch channelMessageFilter {
        case .userMessages:
            return messages.filter { $0.msgtype != .LOGMSG }
        case .serverEvents:
            return messages.filter { $0.msgtype == .LOGMSG }
        }
    }
    
    func dismissKeyboard() {
        if msgTextView.isFirstResponder {
           msgTextView.resignFirstResponder()
        }
    }
    
    func resetText() {
        msgTextView.text = ""
        if #available(iOS 13, *) {
            msgTextView.textColor = .label
        } else {
            msgTextView.textColor = .black
        }
    }

    func resetChannelMessageScreenState() {
        dismissKeyboard()
        resetText()
        channelMessageFilter = .userMessages
        messageFilterControl?.selectedSegmentIndex = channelMessageFilter.rawValue
        updateTableView(animated: false)
    }
    
    func updateTableView(animated: Bool = true) {
        
        tableView.reloadData()
        updateEmptyState()
        updateClearButtonVisibility()
        
        let nMessages = visibleMessages().count
        if nMessages > 0 {
            let ip = IndexPath(row: nMessages - 1, section: 0)
            tableView.scrollToRow(at: ip, at: .bottom, animated: animated)
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        repositionControls()
    }
    
    @objc func keyboardWillShow(_ notify: Notification) {
        moveForKeyboard(notify, up: true)
    }
    
    @objc func keyboardWillHide(_ notify: Notification) {
        moveForKeyboard(notify, up: false)
    }
    
    func repositionControls() {
        if let tc = self.tabBarController {
            msgTextViewBottomConstraint.constant = tc.tabBar.frame.size.height
            sendButtonBottomConstraint.constant = tc.tabBar.frame.size.height
        }
        else {
            msgTextViewBottomConstraint.constant = 0
            sendButtonBottomConstraint.constant = 0
        }
    }
    
    func moveForKeyboard(_ notify: Notification, up: Bool) {
        if let userInfo = notify.userInfo {
            if let keyboardFrame = (userInfo[UIResponder.keyboardFrameEndUserInfoKey] as AnyObject).cgRectValue {
                
                if up {
                    msgTextViewBottomConstraint.constant = keyboardFrame.height
                    sendButtonBottomConstraint.constant = keyboardFrame.height
                }
                else {
                    repositionControls()
                }
                
                updateTableView()
            }
        }
    }
    
    @IBAction func sendTextMessage(_ sender: UIButton) {
        
        let content = msgTextView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty {
            msgTextView.text = ""
            msgTextView.resignFirstResponder()
            return
        }
        
        var msg = TextMessage()
        msg.nFromUserID = TT_GetMyUserID(ttInst)
        
        if userid == 0 {
            msg.nMsgType = MSGTYPE_CHANNEL
            msg.nChannelID = TT_GetMyChannelID(ttInst)
        }
        else {
            msg.nMsgType = MSGTYPE_USER
            msg.nToUserID = userid
            
            var user = User()
            TT_GetUser(ttInst, msg.nFromUserID, &user)
            let name = getDisplayName(user)
            let mymsg = MyTextMessage(fromuserid: msg.nFromUserID, nickname: name, msgtype: .PRIV_IM_MYSELF, content: content)

            appendEventMessage(mymsg)

            if delegate != nil {
                delegate!.appendTextMessage(userid, txtmsg: mymsg)
            }
            updateTableView()
        }
        
        if TeamTalk_NG.sendTextMessage(msg: msg, content: content) {
            msgTextView.text = ""
        }
    }
    
    func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {
        return true
    }
    
    // send message on enter
    func textView(_ textView: UITextView,
                  shouldChangeTextIn range: NSRange,
                  replacementText text: String) -> Bool {
        
        let defaults = UserDefaults.standard
        if defaults.object(forKey: PREF_GENERAL_SENDONRETURN) == nil || defaults.bool(forKey: PREF_GENERAL_SENDONRETURN) {
            
            if text.contains("\n") {
                sendTextMessage(sendButton)
                return false
            }
        }
        return true
    }
    
    func handleTTMessage(_ m: TTMessage) {
        var m = m

        switch m.nClientEvent {
            
        case CLIENTEVENT_CMD_USER_TEXTMSG :
            
            let txtmsg = getTextMessage(&m).pointee
            
            if (txtmsg.nMsgType == MSGTYPE_USER && txtmsg.nFromUserID == userid /* private message to this view controller */) ||
                (txtmsg.nMsgType == MSGTYPE_CHANNEL && userid == 0 /* channel message to tab-bar chat */) ||
                (txtmsg.nMsgType == MSGTYPE_BROADCAST && userid == 0 /* broadcast to tab-bar chat */) {
                
                if let content = getTextMessageContent(txtmsg) {
                    var user = User()
                    TT_GetUser(ttInst, txtmsg.nFromUserID, &user)
                    
                    var msgtype = MsgType.PRIV_IM
                    
                    switch txtmsg.nMsgType {
                    case MSGTYPE_USER :
                        msgtype = TT_GetMyUserID(ttInst) == txtmsg.nFromUserID ? .PRIV_IM_MYSELF : .PRIV_IM
                    case MSGTYPE_CHANNEL :
                        msgtype = TT_GetMyUserID(ttInst) == txtmsg.nFromUserID ? .CHAN_IM_MYSELF : .CHAN_IM
                    case MSGTYPE_BROADCAST :
                        msgtype = .BCAST
                    default :
                        break
                    }

                    let name = getDisplayName(user)
                    let mymsg = MyTextMessage(fromuserid: txtmsg.nFromUserID, nickname: name, msgtype: msgtype, content: content)
                    appendEventMessage(mymsg)
                    
                    if tableView != nil {
                        updateTableView()
                    }
                    
                    speakTextMessage(txtmsg.nMsgType, mymsg: mymsg)
                }
            }
        case CLIENTEVENT_CMD_PROCESSING:
            currentCmdId = getTTBOOL(&m) == TRUE ? m.nSource : 0

        case CLIENTEVENT_CMD_USER_LOGGEDIN :
            
            let user = getUser(&m).pointee
            if TT_GetMyUserID(ttInst) == user.nUserID {
                appendLogMessage(NSLocalizedString("Logged in to server", comment: "log entry"))
            }
            else if currentCmdId == 0 {
                let name = getDisplayName(user)
                appendLogMessage(name + " " + NSLocalizedString("has logged in", comment: "log entry"))
            }
            
        case CLIENTEVENT_CMD_USER_LOGGEDOUT :

            if currentCmdId == 0 {
                let user = getUser(&m).pointee
                let name = getDisplayName(user)
                appendLogMessage(name + " " + NSLocalizedString("has logged out", comment: "log entry"))
            }

        case CLIENTEVENT_CMD_USER_JOINED :
            
            let user = getUser(&m).pointee
            let isMe = TT_GetMyUserID(ttInst) == user.nUserID
            if showLogMessages() && (isMe || currentCmdId == 0) {
                let text: String
                if isMe {
                    let channelName = channelLogDisplayName(user.nChannelID)
                    text = String(format: NSLocalizedString("Joined channel %@", comment: "log entry"), channelName)
                }
                else {
                    let name = getDisplayName(user)
                    let channelName = channelLogDisplayName(user.nChannelID)
                    text = String(format: NSLocalizedString("%@ joined channel %@", comment: "log entry"), name, channelName)
                }

                appendLogMessage(text)
            }
        case CLIENTEVENT_CMD_USER_LEFT :
            
            if showLogMessages() && currentCmdId == 0 {
                let user = getUser(&m).pointee
                let isMe = TT_GetMyUserID(ttInst) == user.nUserID
                let name = getDisplayName(user)
                let text: String
                if isMe {
                    let channelName = channelLogDisplayName(m.nSource)
                    text = String(format: NSLocalizedString("Left channel %@", comment: "log entry"), channelName)
                }
                else {
                    let channelName = channelLogDisplayName(m.nSource)
                    text = String(format: NSLocalizedString("%@ left channel %@", comment: "log entry"), name, channelName)
                }

                appendLogMessage(text)
            }
        case CLIENTEVENT_CMD_ERROR :
            if showLogMessages() {
                let errmsg = getClientErrorMsg(m.clienterrormsg, strprop: ERRMESSAGE)
                let txt = String(format: NSLocalizedString("Command failed: %@", comment: "log entry"),  errmsg)
                let logmsg = MyTextMessage(logmsg: txt)
                appendEventMessage(logmsg)
                
                if tableView != nil {
                    updateTableView()
                }
            }
        default : break
        }
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return visibleMessages().count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {

        let cell = tableView.dequeueReusableCell(withIdentifier: "Text Msg Cell") as! TextMsgTableCell
        let message = getEventMessage(indexPath)
        message.drawCell(cell)
        cell.activationHandler = { [weak self] in
            self?.copyToClipboard(message.message)
        }
        
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        copyToClipboard(getEventMessage(indexPath).message)
    }

    private func copyToClipboard(_ message: String) {
        guard message.isEmpty == false else { return }
        UIPasteboard.general.string = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            UIAccessibility.post(notification: .announcement,
                                 argument: NSLocalizedString("Copied to clipboard.", comment: "text message"))
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return nil
    }
}
