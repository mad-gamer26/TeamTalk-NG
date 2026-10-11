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

enum TTSEvents : Int {
    case USERLOGIN,
    USERLOGOUT,
    USERJOINED,
    USERLEFT,
    USERTEXTMSG,
    USERCHANMSG,
    USERBROADCASTMSG,
    SUBSCRIPTIONS,
    INTERCEPTIONSTART,
    INTERCEPTIONEND,
    FILEUPDATE,
    CONLOST
    
}

class TextToSpeechViewController : UITableViewController {
    
    var ttsevents_items = [UITableViewCell]()
    private var ttsEventRows = [TTSEventRow]()

    private struct TTSEventRow {
        let event: TTSEvents
        let title: String
        let detail: String
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "", style: .plain, target: self, action: #selector(TextToSpeechViewController.toggleAllAnnouncements))

        addTTSEvent(.USERLOGIN,
                    title: NSLocalizedString("User logged in", comment: "preferences"),
                    detail: NSLocalizedString("Announce user logged onto server", comment: "preferences"))
        addTTSEvent(.USERLOGOUT,
                    title: NSLocalizedString("User logged out", comment: "preferences"),
                    detail: NSLocalizedString("Announce user logged out of server", comment: "preferences"))
        addTTSEvent(.USERJOINED,
                    title: NSLocalizedString("User joins channel", comment: "preferences"),
                    detail: NSLocalizedString("Announce user joining channel", comment: "preferences"))
        addTTSEvent(.USERLEFT,
                    title: NSLocalizedString("User leaves channel", comment: "preferences"),
                    detail: NSLocalizedString("Announce user leaving channel", comment: "preferences"))
        addTTSEvent(.CONLOST,
                    title: NSLocalizedString("Connection lost", comment: "preferences"),
                    detail: NSLocalizedString("Announce lost server connection", comment: "preferences"))
        addTTSEvent(.USERTEXTMSG,
                    title: NSLocalizedString("Private Text Message", comment: "preferences"),
                    detail: NSLocalizedString("Announce content of text message", comment: "preferences"))
        addTTSEvent(.USERCHANMSG,
                    title: NSLocalizedString("Channel Text Message", comment: "preferences"),
                    detail: NSLocalizedString("Announce content of text message", comment: "preferences"))
        addTTSEvent(.USERBROADCASTMSG,
                    title: NSLocalizedString("Broadcast Text Message", comment: "preferences"),
                    detail: NSLocalizedString("Announce content of broadcast message", comment: "preferences"))
        addTTSEvent(.SUBSCRIPTIONS,
                    title: NSLocalizedString("Subscription Changes", comment: "preferences"),
                    detail: NSLocalizedString("Announce when users change subscriptions for you", comment: "preferences"))
        addTTSEvent(.INTERCEPTIONSTART,
                    title: NSLocalizedString("Interception Started", comment: "preferences"),
                    detail: NSLocalizedString("Announce when a user starts intercepting you", comment: "preferences"))
        addTTSEvent(.INTERCEPTIONEND,
                    title: NSLocalizedString("Interception Ended", comment: "preferences"),
                    detail: NSLocalizedString("Announce when a user stops intercepting you", comment: "preferences"))
        addTTSEvent(.FILEUPDATE,
                    title: NSLocalizedString("Channel File Updates", comment: "preferences"),
                    detail: NSLocalizedString("Announce when a file is added to or removed from your channel", comment: "preferences"))
        
        updateAnnouncementsBulkButton()

    }
    
    override func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return NSLocalizedString("Announcements", comment:"text to speech")
    }
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return ttsevents_items.count
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        
        return ttsevents_items[indexPath.row]
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        toggleTTSEvent(at: indexPath)
    }

    private func addTTSEvent(_ event: TTSEvents, title: String, detail: String) {
        let row = TTSEventRow(event: event, title: title, detail: detail)
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = title
        cell.detailTextLabel?.text = nil
        cell.selectionStyle = .default
        ttsEventRows.append(row)
        ttsevents_items.append(cell)
        configureTTSEventCell(cell, event: event)
    }

    private func configureTTSEventCell(_ cell: UITableViewCell, event: TTSEvents) {
        if isTTSEventEnabled(event) {
            cell.accessoryType = .checkmark
            cell.accessibilityTraits = [.button, .selected]
        }
        else {
            cell.accessoryType = .none
            cell.accessibilityTraits = [.button]
        }
    }

    private func toggleTTSEvent(at indexPath: IndexPath) {
        let event = ttsEventRows[indexPath.row].event
        setTTSEvent(event, enabled: isTTSEventEnabled(event) == false)
        configureTTSEventCell(ttsevents_items[indexPath.row], event: event)
        updateAnnouncementsBulkButton()
    }

    private func allAnnouncementsEnabled() -> Bool {
        return ttsEventRows.allSatisfy({isTTSEventEnabled($0.event)})
    }

    private func updateAnnouncementsBulkButton() {
        navigationItem.rightBarButtonItem?.title = allAnnouncementsEnabled() ?
            NSLocalizedString("Disable All", comment: "preferences") :
            NSLocalizedString("Enable All", comment: "preferences")
    }

    @objc private func toggleAllAnnouncements() {
        let enable = allAnnouncementsEnabled() == false
        for (index, row) in ttsEventRows.enumerated() {
            setTTSEvent(row.event, enabled: enable)
            configureTTSEventCell(ttsevents_items[index], event: row.event)
        }
        updateAnnouncementsBulkButton()
    }

    private func isTTSEventEnabled(_ event: TTSEvents) -> Bool {
        let defaults = UserDefaults.standard
        switch event {
        case .USERLOGIN:
            return defaults.object(forKey: PREF_TTSEVENT_USERLOGIN) == nil || defaults.bool(forKey: PREF_TTSEVENT_USERLOGIN)
        case .USERLOGOUT:
            return defaults.object(forKey: PREF_TTSEVENT_USERLOGOUT) == nil || defaults.bool(forKey: PREF_TTSEVENT_USERLOGOUT)
        case .USERJOINED:
            return defaults.object(forKey: PREF_TTSEVENT_JOINEDCHAN) == nil || defaults.bool(forKey: PREF_TTSEVENT_JOINEDCHAN)
        case .USERLEFT:
            return defaults.object(forKey: PREF_TTSEVENT_LEFTCHAN) == nil || defaults.bool(forKey: PREF_TTSEVENT_LEFTCHAN)
        case .USERTEXTMSG:
            return defaults.object(forKey: PREF_TTSEVENT_TEXTMSG) == nil || defaults.bool(forKey: PREF_TTSEVENT_TEXTMSG)
        case .USERCHANMSG:
            return defaults.object(forKey: PREF_TTSEVENT_CHANTEXTMSG) == nil || defaults.bool(forKey: PREF_TTSEVENT_CHANTEXTMSG)
        case .USERBROADCASTMSG:
            return defaults.object(forKey: PREF_TTSEVENT_BROADCASTMSG) == nil || defaults.bool(forKey: PREF_TTSEVENT_BROADCASTMSG)
        case .SUBSCRIPTIONS:
            return defaults.object(forKey: PREF_TTSEVENT_SUBSCRIPTIONS) == nil || defaults.bool(forKey: PREF_TTSEVENT_SUBSCRIPTIONS)
        case .INTERCEPTIONSTART:
            return isTTSEventPreferenceEnabled(PREF_TTSEVENT_INTERCEPTION_START, legacyKey: PREF_TTSEVENT_INTERCEPTION)
        case .INTERCEPTIONEND:
            return isTTSEventPreferenceEnabled(PREF_TTSEVENT_INTERCEPTION_END, legacyKey: PREF_TTSEVENT_INTERCEPTION)
        case .FILEUPDATE:
            return defaults.object(forKey: PREF_TTSEVENT_FILEUPDATE) == nil || defaults.bool(forKey: PREF_TTSEVENT_FILEUPDATE)
        case .CONLOST:
            return defaults.object(forKey: PREF_TTSEVENT_CONLOST) == nil || defaults.bool(forKey: PREF_TTSEVENT_CONLOST)
        }
    }

    private func setTTSEvent(_ event: TTSEvents, enabled: Bool) {
        let defaults = UserDefaults.standard
        switch event {
        case .USERLOGIN :
            defaults.set(enabled, forKey: PREF_TTSEVENT_USERLOGIN)
        case .USERLOGOUT :
            defaults.set(enabled, forKey: PREF_TTSEVENT_USERLOGOUT)
        case .USERJOINED :
            defaults.set(enabled, forKey: PREF_TTSEVENT_JOINEDCHAN)
        case .USERLEFT :
            defaults.set(enabled, forKey: PREF_TTSEVENT_LEFTCHAN)
        case .USERTEXTMSG :
            defaults.set(enabled, forKey: PREF_TTSEVENT_TEXTMSG)
        case .USERCHANMSG :
            defaults.set(enabled, forKey: PREF_TTSEVENT_CHANTEXTMSG)
        case .USERBROADCASTMSG :
            defaults.set(enabled, forKey: PREF_TTSEVENT_BROADCASTMSG)
        case .SUBSCRIPTIONS :
            defaults.set(enabled, forKey: PREF_TTSEVENT_SUBSCRIPTIONS)
        case .INTERCEPTIONSTART:
            defaults.set(enabled, forKey: PREF_TTSEVENT_INTERCEPTION_START)
        case .INTERCEPTIONEND:
            defaults.set(enabled, forKey: PREF_TTSEVENT_INTERCEPTION_END)
        case .FILEUPDATE:
            defaults.set(enabled, forKey: PREF_TTSEVENT_FILEUPDATE)
        case .CONLOST :
            defaults.set(enabled, forKey: PREF_TTSEVENT_CONLOST)
        }
    }
}
