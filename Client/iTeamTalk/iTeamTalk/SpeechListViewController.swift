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

class SpeechViewController : UITableViewController {
    
    var sections = [String]()
    var voicesByLanguage = [String: [AVSpeechSynthesisVoice]]()

    private static var cachedSections = [String]()
    private static var cachedVoicesByLanguage = [String: [AVSpeechSynthesisVoice]]()
    private static var isLoadingVoices = false
    private static var pendingLoadHandlers = [() -> Void]()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        tableView.dataSource = self
        tableView.delegate = self

        loadVoices()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        tableView.reloadData()
//        let defaults = NSUserDefaults.standardUserDefaults()
//        var lang = AVSpeechSynthesisVoice.currentLanguageCode()
//        if let voiceid = defaults.stringForKey(PREF_TTSEVENT_VOICEID) {
//            if #available(iOS 9.0, *) {
//                if let voice = AVSpeechSynthesisVoice(identifier: voiceid) {
//                    let voices = getVoices(voice.language)
//                    if let row = voices.indexOf(voice) {
//                        let index = NSIndexPath(forRow: row, inSection: sections.indexOf(voice.language))
//                    }
//                }
//            } else {
//                // Fallback on earlier versions
//            }
//            
//        }
//        else if let voicelang = defaults.stringForKey(PREF_TTSEVENT_VOICELANG) {
//            lang = voicelang
//        }
//        else {
//            let voices = getVoices(lang)
//        }
//        
//        voices.
//        if voiceid != nil {
//            
//        }
//        else {
//            
//            let i = IndexPath(indexPathForRow: 0, inSection
//            tableView.selectRowAtIndexPath(IndexPath(, animated: <#T##Bool#>, scrollPosition: <#T##UITableViewScrollPosition#>)
//        }
        
    }
    
    func loadVoices() {
        if SpeechViewController.cachedSections.isEmpty == false {
            sections = SpeechViewController.cachedSections
            voicesByLanguage = SpeechViewController.cachedVoicesByLanguage
            return
        }

        SpeechViewController.pendingLoadHandlers.append { [weak self] in
            self?.sections = SpeechViewController.cachedSections
            self?.voicesByLanguage = SpeechViewController.cachedVoicesByLanguage
            self?.tableView.reloadData()
        }

        if SpeechViewController.isLoadingVoices {
            return
        }

        SpeechViewController.isLoadingVoices = true
        DispatchQueue.global(qos: .userInitiated).async {
            let currentLanguage = AVSpeechSynthesisVoice.currentLanguageCode()
            let voices = AVSpeechSynthesisVoice.speechVoices()
            var groupedVoices = [String: [AVSpeechSynthesisVoice]]()
            var loadedSections = [String]()

            loadedSections.append(currentLanguage)
            for voice in voices {
                if groupedVoices[voice.language] == nil {
                    groupedVoices[voice.language] = [AVSpeechSynthesisVoice]()
                }
                groupedVoices[voice.language]?.append(voice)

                if loadedSections.contains(voice.language) == false {
                    loadedSections.append(voice.language)
                }
            }

            DispatchQueue.main.async {
                SpeechViewController.cachedSections = loadedSections
                SpeechViewController.cachedVoicesByLanguage = groupedVoices
                SpeechViewController.isLoadingVoices = false
                let handlers = SpeechViewController.pendingLoadHandlers
                SpeechViewController.pendingLoadHandlers.removeAll()
                handlers.forEach({$0()})
            }
        }
    }

    func getVoices(_ language: String) -> [AVSpeechSynthesisVoice] {
        return voicesByLanguage[language] ?? []
    }
    
    override func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }
    
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return sections[section]
    }
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return getVoices(sections[section]).count
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let language = sections[indexPath.section]
        let localname = (Locale.current as NSLocale).displayName(forKey: NSLocale.Key.identifier, value: language)
        let voices = getVoices(language)
        let cell = tableView.dequeueReusableCell(withIdentifier: "Voice Cell")
        cell?.accessoryType = .none
        cell?.accessibilityTraits.remove(.selected)
        if #available(iOS 9.0, *) {
            cell?.textLabel?.text = voices[indexPath.row].name
        } else {
            cell?.textLabel?.text = localname
        }
        let selectedVoiceID = UserDefaults.standard.string(forKey: PREF_TTSEVENT_VOICEID)
        if selectedVoiceID == voices[indexPath.row].identifier {
            cell?.accessoryType = .checkmark
            cell?.accessibilityTraits.insert(.selected)
        }
        cell?.detailTextLabel?.text = nil
        return cell!
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let voices = getVoices(sections[indexPath.section])
        let voice = voices[indexPath.row]
        let defaults = UserDefaults.standard
        
        if #available(iOS 9.0, *) {
            defaults.setValue(voice.identifier, forKey: PREF_TTSEVENT_VOICEID)
            defaults.synchronize()
            
            let utterance = String(format: NSLocalizedString("You have selected %@" , comment: "speech"), voice.name)
            newUtterance(utterance, allowVoiceOver: false)

        } else {
            defaults.setValue(voice.language, forKey: PREF_TTSEVENT_VOICELANG)
            defaults.synchronize()
            
            if let localname = (Locale.current as NSLocale).displayName(forKey: NSLocale.Key.identifier, value: voice.language) {
                let utterance = String(format: NSLocalizedString("You have selected %@" , comment: "speech"), localname)
                newUtterance(utterance, allowVoiceOver: false)
            }
        }

        // Rebuild every visible row so the previous voice loses its checkmark
        // before the newly selected voice receives one.
        tableView.reloadData()
        NotificationCenter.default.post(name: .ttsVoiceDidChange, object: nil)

    }


}
