/*
 * AudioNet in TeamTalk NG: send what one of your AudioNet devices is
 * sharing (its microphone, or the sound playing on it) into the current
 * TeamTalk channel as your voice.
 *
 * TeamTalk NG signs in to the AudioNet account as a visitor, like
 * AudioNet's web client: no device is added to the account. It listens to
 * the chosen device into an AudioTap (AudioNet's engine hands the sound to
 * the app instead of a speaker), and the channel's audio-block streamer
 * reads the tap at the channel's codec format and inserts it with
 * TT_InsertAudioBlock. AudioNet's engine and its Swift interface
 * (audionet_ffi.swift) are built by AudioNet/build-audionet-core.sh.
 */

import Foundation
import Security
import UIKit

extension Notification.Name {
    /// Anything about AudioNet changed (sign-in, devices, the stream).
    static let audioNetChanged = Notification.Name("AudioNetChanged")
    /// The AudioNet stream being sent to a channel ended; `userInfo["reason"]`
    /// says why, in words.
    static let audioNetStreamEnded = Notification.Name("AudioNetStreamEnded")
}

/// The AudioNet sign-in, devices and stream. Used on the main thread; the
/// engine's events are moved there.
final class AudioNetBridge {
    static let shared = AudioNetBridge()

    enum Connection {
        case signedOut
        case connecting
        case connected
        case disconnected(String)
    }

    struct Sending {
        let sessionID: String
        let deviceName: String
        let sourceName: String
        let tap: AudioTap
        var active: Bool
    }

    private(set) var login: VisitorLogin?
    private(set) var connection = Connection.signedOut
    private(set) var devices: [Device] = []
    private(set) var sending: Sending?
    /// The engine's latest status line.
    private(set) var status = ""
    private(set) var busy = false

    private var client: Client?
    /// Which client's events count: a stopped client's late events are
    /// ignored.
    private var generation = 0

    private init() {
        login = Keychain.load()
    }

    var lastServer: String {
        login?.serverUrl ?? UserDefaults.standard.string(forKey: "AudioNetServer") ?? ""
    }

    var lastUsername: String {
        login?.username ?? UserDefaults.standard.string(forKey: "AudioNetUsername") ?? ""
    }

    /// Connects with the saved sign-in, if any (when the AudioNet screen
    /// opens; the connection then stays while the app runs).
    func connectIfSignedIn() {
        guard let login, client == nil else { return }
        generation += 1
        let client = Client.visitor(login: login, appName: "TeamTalk NG",
                                    listener: Events(owner: self, generation: generation))
        self.client = client
        connection = .connecting
        client.start()
        changed()
    }

    func signIn(server: String, username: String, password: String, done: @escaping (String?) -> Void) {
        let server = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(server, forKey: "AudioNetServer")
        UserDefaults.standard.set(username, forKey: "AudioNetUsername")
        busy = true
        changed()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try visitorSignIn(serverUrl: server, username: username, password: password) }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let login):
                    Keychain.save(login)
                    self.login = login
                    self.connectIfSignedIn()
                    done(nil)
                case .failure(let error):
                    self.changed()
                    done(Self.message(error))
                }
            }
        }
    }

    func signOut() {
        stopSending()
        generation += 1
        let old = client
        client = nil
        DispatchQueue.global(qos: .utility).async {
            old?.stop()
        }
        if let login {
            // Ends the visitor's session on the server; nothing else is left
            // behind (no device was added).
            DispatchQueue.global(qos: .utility).async {
                _ = try? visitorSignOut(login: login)
            }
        }
        Keychain.delete()
        login = nil
        devices = []
        connection = .signedOut
        status = ""
        changed()
    }

    /// Starts listening to `source` of `device` into a new tap with the
    /// channel's format. The caller sends the tap's sound to the channel.
    func startSending(device: Device, source: Source, sampleRate: UInt32, channels: UInt32) throws -> AudioTap {
        guard let client, case .connected = connection else {
            throw AudioNetError.Failed(message: NSLocalizedString("AudioNet is not connected yet. Try again in a moment.", comment: "audionet"))
        }
        stopSending()
        let tap = AudioTap(name: NSLocalizedString("TeamTalk channel", comment: "audionet"),
                           sampleRate: sampleRate, channels: channels)
        let session = try client.listen(nodeId: device.nodeId, sourceId: source.id, outputId: tap.destinationId())
        sending = Sending(sessionID: session, deviceName: device.name, sourceName: source.name, tap: tap, active: false)
        changed()
        return tap
    }

    func stopSending() {
        guard let sending else { return }
        self.sending = nil
        client?.stopStream(sessionId: sending.sessionID)
        changed()
    }

    static func message(_ error: Error) -> String {
        if case AudioNetError.Failed(let message) = error {
            return message
        }
        return error.localizedDescription
    }

    private func changed() {
        NotificationCenter.default.post(name: .audioNetChanged, object: self)
    }

    private func ended(_ sessionID: String, reason: String) {
        guard sending?.sessionID == sessionID else { return }
        sending = nil
        changed()
        NotificationCenter.default.post(name: .audioNetStreamEnded, object: self, userInfo: ["reason": reason])
    }

    fileprivate func handle(_ event: Event, generation: Int) {
        guard generation == self.generation else { return }
        switch event {
        case .connected:
            connection = .connected
            client?.refreshDevices()
        case .disconnected(let reason):
            connection = .disconnected(reason)
        case .status(let text):
            status = text
        case .devices(let list):
            devices = list
        case .deviceChanged(let device):
            if let i = devices.firstIndex(where: { $0.nodeId == device.nodeId }) {
                devices[i] = device
            } else {
                devices.append(device)
            }
        case .stream(let sessionID, let state, let detail):
            switch state {
            case .active:
                if sending?.sessionID == sessionID, sending?.active == false {
                    sending?.active = true
                    UIAccessibility.post(notification: .announcement,
                                         argument: NSLocalizedString("AudioNet sound is being sent to the channel.", comment: "audionet"))
                }
            case .failed, .ended:
                ended(sessionID, reason: detail)
            case .starting:
                break
            }
        case .streamEnded(let sessionID, let reason):
            ended(sessionID, reason: reason)
        case .serverProblem(let message):
            status = message
        case .stopped(let error):
            // The sign-in ended for good (it expired, or was ended elsewhere).
            client = nil
            sending = nil
            devices = []
            if let error {
                Keychain.delete()
                login = nil
                connection = .signedOut
                status = error
            } else {
                connection = .disconnected("")
            }
        case .diagnostics:
            return
        }
        changed()
    }

    /// Receives the engine's events (on an engine thread).
    private final class Events: EventListener, @unchecked Sendable {
        weak var owner: AudioNetBridge?
        let generation: Int

        init(owner: AudioNetBridge, generation: Int) {
            self.owner = owner
            self.generation = generation
        }

        func onEvent(event: Event) {
            let generation = generation
            DispatchQueue.main.async { [weak owner] in
                owner?.handle(event, generation: generation)
            }
        }
    }
}

/// The visitor sign-in (its token stands in for the password) in the
/// keychain, on this iPhone only.
private enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "AudioNet sign-in",
        kSecAttrAccount as String: "visitor",
    ]

    static func load() -> VisitorLogin? {
        var read = query
        read[kSecReturnData as String] = true
        var found: CFTypeRef?
        guard SecItemCopyMatching(read as CFDictionary, &found) == errSecSuccess,
              let data = found as? Data,
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let server = fields["server_url"], let username = fields["username"], let token = fields["token"]
        else { return nil }
        return VisitorLogin(serverUrl: server, username: username, token: token)
    }

    static func save(_ login: VisitorLogin) {
        let fields = ["server_url": login.serverUrl, "username": login.username, "token": login.token]
        guard let data = try? JSONSerialization.data(withJSONObject: fields) else { return }
        delete()
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

/// The AudioNet screen: sign in, choose a device's sound to send to the
/// channel, see and stop what is being sent.
final class AudioNetViewController: UITableViewController {
    /// Starts sending a device's sound to this server's channel; returns an
    /// error message, or nil when it started.
    var send: (Device, Source) -> String? = { _, _ in nil }
    /// Whether this channel can be sent to (voice allowed, audio codec).
    var canSend: () -> Bool = { false }
    /// Stops sending to the channel.
    var stop: () -> Void = {}
    /// The sound goes out as voice (no right to stream media files), so the
    /// microphone is off meanwhile.
    var sendsAsVoice: () -> Bool = { true }
    /// The sending volume in percent (50: unchanged).
    var volume: () -> Double = { 50 }
    var setVolume: (Double) -> Void = { _ in }
    private let volumeSlider = UISlider()

    private let bridge = AudioNetBridge.shared

    private enum Row {
        case signIn
        case account
        case signOut
        case sending
        case stopSending
        case volume
        case device(Device)
        case noDevices
    }

    private var sections: [(title: String?, footer: String?, rows: [Row])] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "AudioNet"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(done))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "AudioNet")
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .audioNetChanged, object: nil)
        volumeSlider.minimumValue = 0
        volumeSlider.maximumValue = 1
        volumeSlider.value = Float(volume() / 100)
        volumeSlider.accessibilityLabel = NSLocalizedString("Sending Volume", comment: "audionet")
        volumeSlider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            // steps of 10 %, like the other volume sliders
            let percent = (Double(self.volumeSlider.value) * 10).rounded() * 10
            self.volumeSlider.value = Float(percent / 100)
            self.setVolume(percent)
        }, for: .valueChanged)
        bridge.connectIfSignedIn()
        reload()
    }

    @objc private func done() {
        dismiss(animated: true)
    }

    @objc private func reload() {
        var result: [(String?, String?, [Row])] = []
        if bridge.login == nil {
            result.append((nil,
                           NSLocalizedString("Sign in to your AudioNet account to send what one of your devices is sharing into this channel. TeamTalk NG signs in as a visitor: no device is added to your account.", comment: "audionet"),
                           [.signIn]))
        } else {
            result.append((NSLocalizedString("Account", comment: "audionet"), statusFooter(), [.account, .signOut]))
            if bridge.sending != nil {
                result.append((NSLocalizedString("Sending to This Channel", comment: "audionet"), nil, [.sending, .stopSending]))
            }
            result.append((nil,
                           NSLocalizedString("How loud the AudioNet sound is for everyone in the channel, also next to an audio file. 50 % leaves it as it is.", comment: "audionet"),
                           [.volume]))
            let devices = bridge.devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            result.append((NSLocalizedString("Devices", comment: "audionet"),
                           canSend() ? NSLocalizedString("Choose a device to send its sound into this channel.", comment: "audionet")
                                     : NSLocalizedString("You cannot send audio in this channel.", comment: "audionet"),
                           devices.isEmpty ? [.noDevices] : devices.map { .device($0) }))
        }
        sections = result.map { (title: $0.0, footer: $0.1, rows: $0.2) }
        tableView.reloadData()
    }

    private func statusFooter() -> String? {
        bridge.status.isEmpty ? nil : bridge.status
    }

    private func connectionText() -> String {
        switch bridge.connection {
        case .signedOut: return NSLocalizedString("signed out", comment: "audionet")
        case .connecting: return NSLocalizedString("connecting", comment: "audionet")
        case .connected: return NSLocalizedString("connected", comment: "audionet")
        case .disconnected: return NSLocalizedString("reconnecting", comment: "audionet")
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sections[section].footer
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "AudioNet", for: indexPath)
        cell.accessoryView = nil
        cell.textLabel?.accessibilityElementsHidden = false
        var text = ""
        var color = UIColor.label
        var button = false
        var enabled = true
        switch sections[indexPath.section].rows[indexPath.row] {
        case .signIn:
            text = bridge.busy ? NSLocalizedString("Signing In…", comment: "audionet") : NSLocalizedString("Sign In to AudioNet", comment: "audionet")
            color = view.tintColor
            button = true
            enabled = bridge.busy == false
        case .account:
            text = String(format: NSLocalizedString("%@ on %@, %@", comment: "audionet: account, server, connection"),
                          bridge.lastUsername, URL(string: bridge.lastServer)?.host ?? bridge.lastServer, connectionText())
        case .signOut:
            text = NSLocalizedString("Sign Out of AudioNet", comment: "audionet")
            color = .systemRed
            button = true
        case .sending:
            if let s = bridge.sending {
                text = String(format: NSLocalizedString("%@ from %@, %@", comment: "audionet: sound, device, state"),
                              s.sourceName, s.deviceName,
                              s.active ? NSLocalizedString("sending", comment: "audionet") : NSLocalizedString("starting", comment: "audionet"))
            }
        case .stopSending:
            text = NSLocalizedString("Stop Sending", comment: "audionet")
            color = .systemRed
            button = true
        case .device(let d):
            let state: String
            if d.online == false {
                state = NSLocalizedString("offline", comment: "audionet")
            } else if d.sharing == false || d.sources.isEmpty {
                state = NSLocalizedString("not sharing", comment: "audionet")
            } else {
                state = d.sources.count == 1 ? NSLocalizedString("1 sound", comment: "audionet")
                    : String(format: NSLocalizedString("%d sounds", comment: "audionet"), d.sources.count)
            }
            text = "\(d.name), \(state)"
            enabled = d.online && d.sharing && d.sources.isEmpty == false && canSend()
            color = enabled ? view.tintColor : .secondaryLabel
            button = true
        case .volume:
            // A cell of its own: a reused button row would leave a stale
            // button for VoiceOver next to the slider.
            let volumeCell = UITableViewCell(style: .default, reuseIdentifier: nil)
            volumeCell.textLabel?.text = NSLocalizedString("Sending Volume", comment: "audionet")
            volumeCell.selectionStyle = .none
            volumeSlider.frame = CGRect(x: 0, y: 0, width: 160, height: 31)
            volumeCell.accessoryView = volumeSlider
            volumeCell.isAccessibilityElement = false
            volumeCell.textLabel?.isAccessibilityElement = false
            volumeCell.textLabel?.accessibilityElementsHidden = true
            return volumeCell
        case .noDevices:
            text = bridge.connection.isConnected ? NSLocalizedString("No other devices in this account.", comment: "audionet")
                                                 : NSLocalizedString("Connecting to AudioNet…", comment: "audionet")
        }
        cell.textLabel?.text = text
        cell.textLabel?.textColor = color
        cell.textLabel?.numberOfLines = 0
        cell.selectionStyle = button && enabled ? .default : .none
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = text
        cell.accessibilityTraits = button ? (enabled ? .button : [.button, .notEnabled]) : .staticText
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let cell = tableView.cellForRow(at: indexPath)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .signIn:
            if bridge.busy == false { askToSignIn() }
        case .signOut:
            confirmSignOut(from: cell)
        case .stopSending:
            stop()
        case .device(let d):
            guard d.online, d.sharing, d.sources.isEmpty == false, canSend() else { return }
            chooseSource(of: d, from: cell)
        default:
            break
        }
    }

    private func askToSignIn() {
        let alert = UIAlertController(title: NSLocalizedString("Sign In to AudioNet", comment: "audionet"),
                                      message: NSLocalizedString("Your AudioNet server's address, account name and password.", comment: "audionet"),
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = NSLocalizedString("Server address", comment: "audionet")
            field.accessibilityLabel = NSLocalizedString("Server address", comment: "audionet")
            field.text = self.bridge.lastServer
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addTextField { field in
            field.placeholder = NSLocalizedString("Account name", comment: "audionet")
            field.accessibilityLabel = NSLocalizedString("Account name", comment: "audionet")
            field.text = self.bridge.lastUsername
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.textContentType = .username
        }
        alert.addTextField { field in
            field.placeholder = NSLocalizedString("Password", comment: "audionet")
            field.accessibilityLabel = NSLocalizedString("Password", comment: "audionet")
            field.isSecureTextEntry = true
            field.textContentType = .password
        }
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "audionet"), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("Sign In", comment: "audionet"), style: .default) { [weak self] _ in
            let fields = alert.textFields ?? []
            guard fields.count == 3 else { return }
            self?.bridge.signIn(server: fields[0].text ?? "", username: fields[1].text ?? "", password: fields[2].text ?? "") { error in
                if let error {
                    self?.showError(error)
                } else {
                    UIAccessibility.post(notification: .announcement,
                                         argument: NSLocalizedString("Signed in to AudioNet.", comment: "audionet"))
                }
            }
        })
        present(alert, animated: true)
    }

    private func confirmSignOut(from cell: UITableViewCell?) {
        let sheet = UIAlertController(title: NSLocalizedString("Sign out of AudioNet?", comment: "audionet"),
                                      message: bridge.sending != nil ? NSLocalizedString("Sending to the channel stops.", comment: "audionet") : nil,
                                      preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Sign Out", comment: "audionet"), style: .destructive) { [weak self] _ in
            self?.stop()
            self?.bridge.signOut()
        })
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "audionet"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = cell ?? view
        present(sheet, animated: true)
    }

    private func chooseSource(of device: Device, from cell: UITableViewCell?) {
        let sheet = UIAlertController(title: String(format: NSLocalizedString("Send from %@", comment: "audionet"), device.name),
                                      message: sendsAsVoice()
                                        ? NSLocalizedString("Its sound goes into this channel as your voice. Your microphone is off meanwhile.", comment: "audionet")
                                        : NSLocalizedString("Its sound goes into this channel as a media file stream, mixed with any audio file you stream. Your microphone stays on.", comment: "audionet"),
                                      preferredStyle: .actionSheet)
        let sources = device.sources.sorted { $0.isDefault && $1.isDefault == false }
        for source in sources {
            sheet.addAction(UIAlertAction(title: source.name, style: .default) { [weak self] _ in
                guard let self else { return }
                if let error = self.send(device, source) {
                    self.showError(error)
                }
            })
        }
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "audionet"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = cell ?? view
        present(sheet, animated: true)
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "AudioNet", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "message dialog"), style: .default))
        present(alert, animated: true)
    }
}

private extension AudioNetBridge.Connection {
    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// The tap the channel streamer reads, swapped when another sound is
/// chosen while sending. Read on the streamer's thread.
final class AudioNetTapReader: @unchecked Sendable {
    private let lock = NSLock()
    private var current: AudioTap?

    var tap: AudioTap? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    /// `frames` frames of interleaved 16-bit samples; silence without a tap.
    func read(frames: Int, channels: Int) -> [Int16] {
        guard let tap else { return [Int16](repeating: 0, count: frames * channels) }
        return tap.read(frames: UInt32(frames))
    }
}
