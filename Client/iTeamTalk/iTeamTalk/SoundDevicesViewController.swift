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
import Foundation
import AVFoundation

class SoundDevicesViewController : UITableViewController, TeamTalkEvent {

    let SECTION_GENERAL = 0

    var sound_items = [UITableViewCell]()
    private var perServerAudioItems = [UITableViewCell]()
    var userIDs = Set<INT32>()
    private let showsAudioControls: Bool
    private var initializedSoundDevicesForSetup = false
    private var mastervolcell: UITableViewCell?
    private var microphonecell: UITableViewCell?
    private var allowBluetoothMicrophonesSwitch: UISwitch?
    private var shouldRefreshPreferredMicFromRoute = false
    private let sessionInstance: UnsafeMutableRawPointer?

    private var globalSettingsSection: Int { showsAudioControls ? 1 : 0 }
    private var audioInputSectionOffset: Int { showsAudioControls ? 2 : 1 }

    init(audioControls: Bool = false) {
        showsAudioControls = audioControls
        sessionInstance = ttInst
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) {
        showsAudioControls = false
        sessionInstance = ttInst
        super.init(coder: coder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        if showsAudioControls {
            title = NSLocalizedString("Audio Controls", comment: "Sound Devices")
            navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done,
                                                                target: self,
                                                                action: #selector(done(_:)))
            buildAudioControlItems()
        }
        
        let settings = UserDefaults.standard

        let speakercell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let speakerswitch = newTableCellSwitch(speakercell, label: NSLocalizedString("Speaker Output", comment: "preferences"),
            initial: settings.object(forKey: PREF_SPEAKER_OUTPUT) != nil && settings.bool(forKey: PREF_SPEAKER_OUTPUT))
        speakerswitch.addTarget(self, action: #selector(SoundDevicesViewController.speakeroutputChanged(_:)), for: .valueChanged)
        sound_items.append(speakercell)

        let voiceprocessingcell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let voiceprocessingswitch = newTableCellSwitch(voiceprocessingcell,
                                                       label: NSLocalizedString("Voice Preprocessing", comment: "Sound Devices"),
                                                       initial: isVoiceProcessingEnabled())
        voiceprocessingswitch.addTarget(self, action: #selector(SoundDevicesViewController.voiceProcessingChanged(_:)), for: .valueChanged)
        sound_items.append(voiceprocessingcell)

        let bluetoothmiccell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        allowBluetoothMicrophonesSwitch = newTableCellSwitch(bluetoothmiccell,
                                                             label: NSLocalizedString("Allow Bluetooth Microphones", comment: "Sound Devices"),
                                                             initial: settings.object(forKey: PREF_ALLOW_BLUETOOTH_MICROPHONES) != nil && settings.bool(forKey: PREF_ALLOW_BLUETOOTH_MICROPHONES))
        allowBluetoothMicrophonesSwitch?.addTarget(self, action: #selector(SoundDevicesViewController.allowBluetoothMicrophonesChanged(_:)), for: .valueChanged)
        sound_items.append(bluetoothmiccell)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        if showsAudioControls {
            addToTTMessages(self)
        }

        if showsAudioControls == false && initializedSoundDevicesForSetup == false && soundDevicesInitializedForConnection == false {
            let enableInput = ttInst != nil && isTransmitting(ttInst!, stream: STREAMTYPE_VOICE)
            initializedSoundDevicesForSetup = setupSoundDevices(enableInput: enableInput, allowWithoutConnection: true)
        }

        if soundDevicesInitializedForConnection {
            let center = NotificationCenter.default
            center.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
            center.addObserver(self, selector: #selector(SoundDevicesViewController.audioRouteChange(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
        }

        tableView.reloadData()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        if showsAudioControls {
            removeTTMessageHandler(self)
        }

        if isMovingFromParent || navigationController?.isBeingDismissed == true {
            NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
            if initializedSoundDevicesForSetup {
                teardownInitializedSoundDevices()
                initializedSoundDevicesForSetup = false
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        removeTTMessageHandler(self)
    }

    func buildAudioControlItems() {
        let settings = UserDefaults.standard

        mastervolcell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let outputPct: Int
        if ConnectedServerManager.shared.sessions.count > 1, let sessionInstance {
            outputPct = refVolumeToPercent(Int(TT_GetSoundOutputVolume(sessionInstance)))
        }
        else {
            outputPct = settings.object(forKey: PREF_MASTER_VOLUME) == nil ? DEFAULT_AUDIO_LEVEL_PERCENT : settings.integer(forKey: PREF_MASTER_VOLUME)
        }
        let mastervolslider = newTableCellSlider(mastervolcell!,
                                                 label: NSLocalizedString("Master Volume", comment: "preferences"),
                                                 min: 0,
                                                 max: 1,
                                                 initial: Float(outputPct) / 100)
        mastervolslider.addTarget(self, action: #selector(masterVolumeChanged(_:)), for: .valueChanged)
        mastervolcell?.detailTextLabel?.text = "\(outputPct) %"
        perServerAudioItems.append(mastervolcell!)

        microphonecell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let inputPct: Int
        if ConnectedServerManager.shared.sessions.count > 1, let sessionInstance {
            inputPct = refVolumeToPercent(Int(TT_GetSoundInputGainLevel(sessionInstance)))
        }
        else {
            inputPct = settings.object(forKey: PREF_MICROPHONE_GAIN) == nil ? DEFAULT_AUDIO_LEVEL_PERCENT : settings.integer(forKey: PREF_MICROPHONE_GAIN)
        }
        let microphoneslider = newTableCellSlider(microphonecell!,
                                                  label: NSLocalizedString("Input Gain", comment: "preferences"),
                                                  min: 0,
                                                  max: 1,
                                                  initial: Float(inputPct) / 100)
        microphoneslider.addTarget(self, action: #selector(microphoneGainChanged(_:)), for: .valueChanged)
        microphonecell?.detailTextLabel?.text = "\(inputPct) %"
        perServerAudioItems.append(microphonecell!)

        perServerAudioItems.append(newMediaFileVolumeCell())

    }
    
    override func numberOfSections(in tableView: UITableView) -> Int {
        guard soundDevicesInitializedForConnection else {
            return audioInputSectionOffset
        }

        return availableAudioInputs().count + audioInputSectionOffset
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        
        if showsAudioControls && section == 0 {
            return nil
        }
        if section == globalSettingsSection {
            if showsAudioControls {
                return ConnectedServerManager.shared.sessions.count > 1
                    ? NSLocalizedString("Global Settings", comment: "Sound Devices")
                    : nil
            }
            return nil
        }
        else {
            guard soundDevicesInitializedForConnection else {
                return ""
            }

            let audioPortIndex = section - audioInputSectionOffset
            let inputs = availableAudioInputs()
            if audioPortIndex < inputs.count {
                return inputs[audioPortIndex].portName
            }
        }
        return ""
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if showsAudioControls && section == 0 {
            return perServerAudioItems.count
        }
        if section == globalSettingsSection {
            return sound_items.count
        }
        else {
            let audioPortIndex = section - audioInputSectionOffset
            return getAudioInputDataSourcesCount(audioPortIndex: audioPortIndex)
        }
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if showsAudioControls && indexPath.section == 0 {
            return perServerAudioItems[indexPath.row]
        }
        if indexPath.section == globalSettingsSection {
            return sound_items[indexPath.row]
        }
        else {
            let audioPortIndex = indexPath.section - audioInputSectionOffset
            return createAudioInputTableCell(audioPortIndex: audioPortIndex, dataSourceIndex: indexPath.row)
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if indexPath.section < audioInputSectionOffset {
            return
        }
        else {
            guard soundDevicesInitializedForConnection else {
                return
            }

            let audioPortIndex = indexPath.section - audioInputSectionOffset
            
            do {
                let session = AVAudioSession.sharedInstance()
                let inputs = availableAudioInputs()
                if audioPortIndex < inputs.count {
                        
                    let audioinput = inputs[audioPortIndex]
                    UserDefaults.standard.set(audioinput.uid, forKey: PREF_SNDINPUT_DEVICE)
                    print ("UID of \(audioinput.portName): \(audioinput.uid)");
                    if let datasources = audioinput.dataSources {
                        if indexPath.row < datasources.count {
                            let audiodatasource = datasources[indexPath.row]
                            print ("Data source ID: \(audiodatasource.dataSourceID)")
                            try applyPreferredAudioInput(audioinput, dataSource: audiodatasource, session: session)
                            setAudioPortDataSource(descr: audioinput, dsrc: audiodatasource)
                        }
                        else {
                            try applyPreferredAudioInput(audioinput, dataSource: nil, session: session)
                            removeAudioPortDataSource(descr: audioinput)
                        }
                    } // datasources
                    else {
                        try applyPreferredAudioInput(audioinput, dataSource: nil, session: session)
                        print ("\(audioinput.portName) has no audio sources; using the port directly")
                    }

                    tableView.reloadData()
                }
                print (session.currentRoute)
            }
            catch {
                print("Failed to select data source")
            }
        }
    }

    func isSelectedAudioInput(_ audioinput: AVAudioSessionPortDescription, session: AVAudioSession) -> Bool {
        if let savedInputUID = UserDefaults.standard.string(forKey: PREF_SNDINPUT_DEVICE) {
            return savedInputUID == audioinput.uid
        }

        return session.preferredInput?.uid == audioinput.uid ||
            session.currentRoute.inputs.contains(where: { $0.uid == audioinput.uid })
    }

    func isSelectedAudioDataSource(_ audiodatasource: AVAudioSessionDataSourceDescription,
                                   for audioinput: AVAudioSessionPortDescription,
                                   dataSourceIndex: Int,
                                   session: AVAudioSession) -> Bool {
        guard isSelectedAudioInput(audioinput, session: session) else {
            return false
        }

        if let savedInputUID = UserDefaults.standard.string(forKey: PREF_SNDINPUT_DEVICE),
           savedInputUID == audioinput.uid {
            if let savedDataSourceID = getAudioPortDataSource(descr: audioinput) {
                return savedDataSourceID == audiodatasource.dataSourceID
            }
        }

        if let activeDataSourceID = session.inputDataSource?.dataSourceID {
            return activeDataSourceID == audiodatasource.dataSourceID
        }

        return dataSourceIndex == 0
    }
    
    func createAudioInputTableCell(audioPortIndex: Int, dataSourceIndex: Int) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SoundDevices") ?? UITableViewCell(style: .default, reuseIdentifier: "SoundDevices")
        guard soundDevicesInitializedForConnection else {
            cell.textLabel?.text = NSLocalizedString("No active sound devices", comment: "Sound Devices")
            return cell
        }

        let session = AVAudioSession.sharedInstance()
        cell.accessoryType = .none
        cell.accessibilityTraits.remove(.selected)
        let inputs = availableAudioInputs()
        if audioPortIndex < inputs.count {
            let audioinput = inputs[audioPortIndex]
            if let datasources = audioinput.dataSources {
                if dataSourceIndex < datasources.count {
                    let audiodatasource = datasources[dataSourceIndex]
                    var srcName = audiodatasource.dataSourceName
                    if #available(iOS 14.0, *) {
                        if audiodatasource.supportedPolarPatterns != nil && audiodatasource.supportedPolarPatterns!.contains(.stereo) {
                            srcName += " (" + NSLocalizedString("Stereo", comment: "Sound Devices") + ")"
                        }
                    }

                    cell.textLabel?.text = srcName
                    let selected = isSelectedAudioDataSource(audiodatasource,
                                                             for: audioinput,
                                                             dataSourceIndex: dataSourceIndex,
                                                             session: session)
                    cell.accessoryType = selected ? .checkmark : .none
                    if selected {
                        cell.accessibilityTraits.insert(.selected)
                    }
                }
                else {
                    cell.textLabel?.text = NSLocalizedString("Default", comment: "Sound Devices")
                    let selected = isSelectedAudioInput(audioinput, session: session) && getAudioPortDataSource(descr: audioinput) == nil
                    cell.accessoryType = selected ? .checkmark : .none
                    if selected {
                        cell.accessibilityTraits.insert(.selected)
                    }
                }
            }
            else {
                cell.textLabel?.text = NSLocalizedString("Default", comment: "Sound Devices")
                let selected = isSelectedAudioInput(audioinput, session: session) && getAudioPortDataSource(descr: audioinput) == nil
                cell.accessoryType = selected ? .checkmark : .none
                if selected {
                    cell.accessibilityTraits.insert(.selected)
                }
            }
        }
        return cell
    }
    
    func getAudioInputDataSourcesCount(audioPortIndex: Int) -> Int {
        guard soundDevicesInitializedForConnection else {
            return 0
        }

        let inputs = availableAudioInputs()
        if audioPortIndex < inputs.count {
            if let datasources = inputs[audioPortIndex].dataSources {
                return max(datasources.count, 1)
            }
            return 1
        }
        return 0
    }

    func availableAudioInputs() -> [AVAudioSessionPortDescription] {
        return availableSelectableAudioInputs()
    }

    @objc func audioRouteChange(_ notification: Notification) {
        print("Audio Route changed in Sound Devices table")
        if shouldRefreshPreferredMicFromRoute {
            refreshPreferredMicFromCurrentRoute()
            shouldRefreshPreferredMicFromRoute = false
        }
        tableView.reloadData()
    }

    func refreshPreferredMicFromCurrentRoute() {
        let session = AVAudioSession.sharedInstance()
        let selectableInputs = availableAudioInputs()
        let activeInput = session.currentRoute.inputs.first.flatMap { activeRouteInput in
            selectableInputs.first(where: { $0.uid == activeRouteInput.uid })
        } ?? session.preferredInput.flatMap { preferredInput in
            selectableInputs.first(where: { $0.uid == preferredInput.uid })
        }

        guard let audioinput = activeInput else {
            return
        }

        let defaults = UserDefaults.standard
        let previousInputUID = defaults.string(forKey: PREF_SNDINPUT_DEVICE)
        defaults.set(audioinput.uid, forKey: PREF_SNDINPUT_DEVICE)
        if previousInputUID != audioinput.uid {
            removeAudioPortDataSource(descr: audioinput)
        }
    }

    func reconfigureSoundDevicesIfActive() {
        guard soundDevicesInitializedForConnection else { return }

        let sessions = ConnectedServerManager.shared.sessions
        if sessions.isEmpty {
            let enableInput = ttInst != nil && isTransmitting(ttInst!, stream: STREAMTYPE_VOICE)
            setupSoundDevices(enableInput: enableInput, allowWithoutConnection: true)
        }
        else if let activeInstance = ConnectedServerManager.shared.activeSession?.teamTalkInstance {
            _ = withTeamTalkInstance(activeInstance) {
                setupSoundDevices(enableInput: isTransmitting(activeInstance, stream: STREAMTYPE_VOICE),
                                  allowWithoutConnection: true)
            }
        }
        tableView.reloadData()
    }
    
    @objc func speakeroutputChanged(_ sender: UISwitch) {
        let defaults = UserDefaults.standard
        defaults.set(sender.isOn, forKey: PREF_SPEAKER_OUTPUT)
        reconfigureSoundDevicesIfActive()
    }

    @objc func voiceProcessingChanged(_ sender: UISwitch) {
        UserDefaults.standard.set(sender.isOn, forKey: PREF_VOICE_PROCESSING)
        // Switching between the Remote I/O and Voice-Processing I/O units requires
        // reinitializing the sound devices, which reconfigureSoundDevicesIfActive()
        // does by closing and reopening them.
        reconfigureSoundDevicesIfActive()
    }

    @objc func allowBluetoothMicrophonesChanged(_ sender: UISwitch) {
        UserDefaults.standard.set(sender.isOn, forKey: PREF_ALLOW_BLUETOOTH_MICROPHONES)
        shouldRefreshPreferredMicFromRoute = true
        reconfigureSoundDevicesIfActive()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self, self.shouldRefreshPreferredMicFromRoute else {
                return
            }
            self.refreshPreferredMicFromCurrentRoute()
            self.shouldRefreshPreferredMicFromRoute = false
            self.tableView.reloadData()
        }
    }

    @objc func done(_ sender: UIBarButtonItem) {
        dismiss(animated: true, completion: nil)
    }

    @objc func masterVolumeChanged(_ sender: UISlider) {
        let percent = Int(sender.value * 10.0) * 10
        let vol = refVolume(Double(percent))
        if let sessionInstance {
            TT_SetSoundOutputVolume(sessionInstance, INT32(vol))
        }

        mastervolcell?.detailTextLabel?.text = "\(percent) %"

        if ConnectedServerManager.shared.sessions.count <= 1 {
            UserDefaults.standard.set(percent, forKey: PREF_MASTER_VOLUME)
        }
    }

    @objc func microphoneGainChanged(_ sender: UISlider) {
        let volPct = Int(sender.value * 10.0) * 10
        let vol = refVolume(Double(volPct))
        if let sessionInstance {
            TT_SetSoundInputGainLevel(sessionInstance, INT32(vol))
        }

        microphonecell?.detailTextLabel?.text = "\(volPct) %"

        if ConnectedServerManager.shared.sessions.count <= 1 {
            UserDefaults.standard.set(volPct, forKey: PREF_MICROPHONE_GAIN)
        }
    }

    func handleTTMessage(_ m: TTMessage) {
        var m = m

        switch m.nClientEvent {
        case CLIENTEVENT_CMD_USER_JOINED:
            let user = getUser(&m).pointee
            userIDs.insert(user.nUserID)
        case CLIENTEVENT_CMD_USER_LEFT:
            let user = getUser(&m).pointee
            userIDs.remove(user.nUserID)
        default:
            break
        }
    }

}
