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

import Foundation
import AVFoundation
import UIKit

// initialize TTS values globally
let synth = AVSpeechSynthesizer()
var myUtterance = AVSpeechUtterance(string: "")

let DEFAULT_TTS_VOL : Float = 1.0

func newUtterance(_ utterance: String, allowVoiceOver: Bool = true) {
    let settings = UserDefaults.standard
    myUtterance = AVSpeechUtterance(string: utterance)
    let useVoiceOver = settings.object(forKey: PREF_TTSEVENT_USE_VOICEOVER) == nil || settings.bool(forKey: PREF_TTSEVENT_USE_VOICEOVER)
    if allowVoiceOver && useVoiceOver && UIAccessibility.isVoiceOverRunning && UIApplication.shared.applicationState == .active {
        UIAccessibility.post(notification: UIAccessibility.Notification.announcement, argument: utterance)
        return
    }
    if let rate = settings.value(forKey: PREF_TTSEVENT_RATE) {
        myUtterance.rate = (rate as AnyObject).floatValue!
    }
    if let vol = settings.value(forKey: PREF_TTSEVENT_VOL) {
        myUtterance.volume = (vol as AnyObject).floatValue!
    }
    else {
        myUtterance.volume = DEFAULT_TTS_VOL
        settings.set(DEFAULT_TTS_VOL, forKey: PREF_TTSEVENT_VOL)
    }
    if let voice = settings.string(forKey: PREF_TTSEVENT_VOICEID) {
        if #available(iOS 9.0, *) {
            myUtterance.voice = AVSpeechSynthesisVoice(identifier: voice)
        } else {
            // Fallback on earlier versions
        }
    }
    else if let lang = settings.string(forKey: PREF_TTSEVENT_VOICELANG) {
        myUtterance.voice = AVSpeechSynthesisVoice(language: lang)
    }
    
    synth.speak(myUtterance)
}

func isTTSEventPreferenceEnabled(_ key: String, legacyKey: String? = nil) -> Bool {
    let settings = UserDefaults.standard
    if settings.object(forKey: key) != nil {
        return settings.bool(forKey: key)
    }
    if let legacyKey = legacyKey, settings.object(forKey: legacyKey) != nil {
        return settings.bool(forKey: legacyKey)
    }
    return true
}

func speakTextMessage(_ msgtype: TextMsgType, mymsg: MyTextMessage) {
    
    let settings = UserDefaults.standard
    let tts_priv = (settings.object(forKey: PREF_TTSEVENT_TEXTMSG) == nil || settings.bool(forKey: PREF_TTSEVENT_TEXTMSG)) && msgtype == MSGTYPE_USER
    let tts_chan = (settings.object(forKey: PREF_TTSEVENT_CHANTEXTMSG) == nil || settings.bool(forKey: PREF_TTSEVENT_CHANTEXTMSG)) && msgtype == MSGTYPE_CHANNEL
    let tts_broadcast = (settings.object(forKey: PREF_TTSEVENT_BROADCASTMSG) == nil || settings.bool(forKey: PREF_TTSEVENT_BROADCASTMSG)) && msgtype == MSGTYPE_BROADCAST
    
    if tts_priv {
        let ttsmsg = String(format: NSLocalizedString("Private text message from %@. %@", comment: "TTS EVENT"),
            limitText(mymsg.nickname), mymsg.message)
        newUtterance(ttsmsg)
    }
    if tts_chan {
        let ttsmsg = String(format: NSLocalizedString("Channel message from %@. %@", comment: "TTS EVENT"),
            limitText(mymsg.nickname), mymsg.message)
        newUtterance(ttsmsg)
    }
    if tts_broadcast {
        let ttsmsg = String(format: NSLocalizedString("Broadcast message from %@: %@", comment: "TTS EVENT"),
            limitText(mymsg.nickname), mymsg.message)
        newUtterance(ttsmsg)
    }
}

func announceChannelFileUpdate(_ remoteFile: RemoteFile, added: Bool) {
    guard remoteFile.nChannelID == TT_GetMyChannelID(ttInst) else {
        return
    }

    let fileName = fromTTString(remoteFile.szFileName)
    let username = fromTTString(remoteFile.szUsername)
    var account = UserAccount()
    let isOwnFile = added &&
        !username.isEmpty &&
        TT_GetMyUserAccount(ttInst, &account) == TRUE &&
        username == fromTTString(account.szUsername)

    playSound(isOwnFile ? .filetx_COMPLETE : .file_UPDATE)

    let settings = UserDefaults.standard
    guard settings.object(forKey: PREF_TTSEVENT_FILEUPDATE) == nil ||
            settings.bool(forKey: PREF_TTSEVENT_FILEUPDATE) else {
        return
    }

    let action = added
        ? NSLocalizedString("added", comment: "TTS EVENT")
        : NSLocalizedString("removed", comment: "TTS EVENT")
    let message = String(format: NSLocalizedString("File %@ %@ by %@.", comment: "TTS EVENT"),
                         fileName,
                         action,
                         username)
    newUtterance(message)
}

func speakSubscriptionChanges(for user: User, previous: Subscriptions, current: Subscriptions) {
    let settings = UserDefaults.standard
    guard settings.object(forKey: PREF_TTSEVENT_SUBSCRIPTIONS) == nil || settings.bool(forKey: PREF_TTSEVENT_SUBSCRIPTIONS) else {
        return
    }

    let changed = previous ^ current
    guard changed != 0 else {
        return
    }

    let userName = getDisplayName(user)
    for item in subscriptionAnnouncementItems() where (changed & item.subscription) != 0 {
        let enabled = (current & item.subscription) != 0
        let state = enabled ? NSLocalizedString("on", comment: "TTS EVENT") : NSLocalizedString("off", comment: "TTS EVENT")
        let message = String(format: NSLocalizedString("%@ changed subscription %@ to: %@", comment: "TTS EVENT"),
                             userName,
                             item.name,
                             state)
        newUtterance(message)
    }
}

func notifyInterceptionChanges(for user: User, previous: Subscriptions, current: Subscriptions) {
    let changed = previous ^ current
    guard changed != 0 else {
        return
    }

    let userName = getDisplayName(user)
    for item in interceptionAnnouncementItems() where (changed & item.subscription) != 0 {
        let enabled = (current & item.subscription) != 0
        playSound(enabled ? .intercept_START : .intercept_END)

        let ttsEnabled = enabled
            ? isTTSEventPreferenceEnabled(PREF_TTSEVENT_INTERCEPTION_START, legacyKey: PREF_TTSEVENT_INTERCEPTION)
            : isTTSEventPreferenceEnabled(PREF_TTSEVENT_INTERCEPTION_END, legacyKey: PREF_TTSEVENT_INTERCEPTION)
        if ttsEnabled {
            let state = enabled ? NSLocalizedString("on", comment: "TTS EVENT") : NSLocalizedString("off", comment: "TTS EVENT")
            let message = String(format: NSLocalizedString("%@ changed subscription intercept %@ to: %@", comment: "TTS EVENT"),
                                 userName,
                                 item.name,
                                 state)
            newUtterance(message)
        }
    }
}

private func subscriptionAnnouncementItems() -> [(subscription: Subscriptions, name: String)] {
    return [
        (SUBSCRIBE_USER_MSG.rawValue, NSLocalizedString("user messages", comment: "TTS EVENT")),
        (SUBSCRIBE_CHANNEL_MSG.rawValue, NSLocalizedString("channel messages", comment: "TTS EVENT")),
        (SUBSCRIBE_BROADCAST_MSG.rawValue, NSLocalizedString("broadcast messages", comment: "TTS EVENT")),
        (SUBSCRIBE_VOICE.rawValue, NSLocalizedString("voice", comment: "TTS EVENT")),
        (SUBSCRIBE_VIDEOCAPTURE.rawValue, NSLocalizedString("web cam", comment: "TTS EVENT")),
        (SUBSCRIBE_DESKTOP.rawValue, NSLocalizedString("desktop", comment: "TTS EVENT")),
        (SUBSCRIBE_DESKTOPINPUT.rawValue, NSLocalizedString("desktop input", comment: "TTS EVENT")),
        (SUBSCRIBE_MEDIAFILE.rawValue, NSLocalizedString("audio files", comment: "TTS EVENT"))
    ]
}

private func interceptionAnnouncementItems() -> [(subscription: Subscriptions, name: String)] {
    return [
        (SUBSCRIBE_INTERCEPT_USER_MSG.rawValue, NSLocalizedString("user messages", comment: "TTS EVENT")),
        (SUBSCRIBE_INTERCEPT_CHANNEL_MSG.rawValue, NSLocalizedString("channel messages", comment: "TTS EVENT")),
        (SUBSCRIBE_INTERCEPT_VOICE.rawValue, NSLocalizedString("voice", comment: "TTS EVENT")),
        (SUBSCRIBE_INTERCEPT_VIDEOCAPTURE.rawValue, NSLocalizedString("web cam", comment: "TTS EVENT")),
        (SUBSCRIBE_INTERCEPT_DESKTOP.rawValue, NSLocalizedString("desktop", comment: "TTS EVENT")),
        (SUBSCRIBE_INTERCEPT_MEDIAFILE.rawValue, NSLocalizedString("audio files", comment: "TTS EVENT"))
    ]
}
