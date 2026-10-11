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
import OSLog
import UniformTypeIdentifiers
import CryptoKit

private let mediaFileStreamingLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "iTeamTalk",
                                              category: "MediaFileStreaming")

enum MediaFilePreparationError: LocalizedError {
    case invalidOutputFormat
    case converterUnavailable
    case bufferUnavailable
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .invalidOutputFormat:
            return NSLocalizedString("Could not create a compatible WAV output format.", comment: "media-file")
        case .converterUnavailable:
            return NSLocalizedString("Could not create an audio converter for this file.", comment: "media-file")
        case .bufferUnavailable:
            return NSLocalizedString("Could not allocate audio conversion buffers.", comment: "media-file")
        case .conversionFailed:
            return NSLocalizedString("Audio conversion failed.", comment: "media-file")
        }
    }
}

private struct MediaFileAudioBlockFormat {
    let sampleRate: Double
    let channels: AVAudioChannelCount
    let txIntervalMSec: Int
}

private final class AudioBlockMediaStreamer {
    let id: UUID

    private let ttInst: UnsafeMutableRawPointer
    private let url: URL
    /// Live sound (AudioNet) instead of a file: reads the next block.
    private let live: ((Int) -> [Int16])?
    private let format: MediaFileAudioBlockFormat
    private let streamID: INT32
    private let onFinish: (Result<Void, Error>) -> Void
    private let lock = NSLock()
    private var stopped = false
    private var paused = false
    private var thread: Thread?

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped == false
    }

    var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return paused
    }

    init(id: UUID,
         ttInst: UnsafeMutableRawPointer,
         url: URL,
         format: MediaFileAudioBlockFormat,
         onFinish: @escaping (Result<Void, Error>) -> Void) {
        self.id = id
        self.ttInst = ttInst
        self.url = url
        self.live = nil
        self.format = format
        self.streamID = INT32.random(in: 1...INT32.max)
        self.onFinish = onFinish
    }

    /// Streams live sound until stopped: `live` returns the next block of
    /// interleaved samples (the requested frames at `format`).
    init(id: UUID,
         ttInst: UnsafeMutableRawPointer,
         live: @escaping (Int) -> [Int16],
         format: MediaFileAudioBlockFormat,
         onFinish: @escaping (Result<Void, Error>) -> Void) {
        self.id = id
        self.ttInst = ttInst
        self.url = URL(fileURLWithPath: "AudioNet")
        self.live = live
        self.format = format
        self.streamID = INT32.random(in: 1...INT32.max)
        self.onFinish = onFinish
    }

    func start() {
        let thread = Thread { [weak self] in
            self?.run()
        }
        self.thread = thread
        thread.start()
    }

    func stop() {
        setStopped()
        TT_InsertAudioBlock(ttInst, nil)
    }

    func pause() {
        lock.lock()
        paused = true
        lock.unlock()
        TT_InsertAudioBlock(ttInst, nil)
    }

    func resume() {
        lock.lock()
        paused = false
        lock.unlock()
    }

    private func run() {
        do {
            try stream()
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    private func stream() throws {
        defer {
            TT_InsertAudioBlock(ttInst, nil)
        }
        if let live {
            try streamLive(live)
            return
        }

        let decodedSamples = try decodeMediaFile()
        let framesPerBlock = max(1, Int(format.sampleRate * Double(format.txIntervalMSec) / 1000.0))
        let totalFrames = decodedSamples.count / Int(format.channels)
        let intervalNanos = UInt64(max(1, format.txIntervalMSec)) * 1_000_000
        let prebufferBlocks = 3
        var nextSendTime = DispatchTime.now().uptimeNanoseconds + (intervalNanos * UInt64(prebufferBlocks + 1))
        var lastInsertTime: UInt64?
        var blockIndex = 0
        var frameOffset = 0
        var lateWakeCount = 0
        var maxLateMSec = 0.0
        var maxInsertGapMSec = 0.0
        var pacingResyncCount = 0
        var insertRetryCount = 0
        let silence = Array(repeating: Int16(0), count: framesPerBlock * Int(format.channels))

        for _ in 0..<prebufferBlocks where shouldContinue() {
            insertRetryCount += try insert(samples: silence, frameOffset: 0, frameCount: framesPerBlock)
            blockIndex += 1
        }

        while shouldContinue(), frameOffset < totalFrames {
            if waitWhilePaused() {
                nextSendTime = DispatchTime.now().uptimeNanoseconds + intervalNanos
                lastInsertTime = nil
            }
            guard shouldContinue() else { break }

            let now = DispatchTime.now().uptimeNanoseconds
            if nextSendTime > now {
                Thread.sleep(forTimeInterval: Double(nextSendTime - now) / 1_000_000_000.0)
            } else {
                lateWakeCount += 1
                maxLateMSec = max(maxLateMSec, Double(now - nextSendTime) / 1_000_000.0)
            }
            if isPaused {
                continue
            }
            guard shouldContinue() else { break }

            let frameCount = min(framesPerBlock, totalFrames - frameOffset)
            insertRetryCount += try insert(samples: decodedSamples, frameOffset: frameOffset, frameCount: frameCount)
            let insertedAt = DispatchTime.now().uptimeNanoseconds
            if let lastInsertTime {
                maxInsertGapMSec = max(maxInsertGapMSec, Double(insertedAt - lastInsertTime) / 1_000_000.0)
            }
            lastInsertTime = insertedAt
            frameOffset += frameCount
            blockIndex += 1
            nextSendTime += intervalNanos
            if insertedAt > nextSendTime + intervalNanos {
                pacingResyncCount += 1
                nextSendTime = insertedAt + intervalNanos
            }
        }

        let drainDelay = Double(intervalNanos * UInt64(prebufferBlocks + 1)) / 1_000_000_000.0
        if shouldContinue() {
            Thread.sleep(forTimeInterval: drainDelay)
        }
        TT_InsertAudioBlock(ttInst, nil)

        mediaFileStreamingLogger.info("Audio block media streaming completed: name=\(self.url.lastPathComponent, privacy: .public), blocks=\(blockIndex), prebufferBlocks=\(prebufferBlocks), drainDelayMSec=\(drainDelay * 1000.0), lateWakeCount=\(lateWakeCount), maxLateMSec=\(maxLateMSec), maxInsertGapMSec=\(maxInsertGapMSec), pacingResyncCount=\(pacingResyncCount), insertRetryCount=\(insertRetryCount)")
    }

    /// Sends live sound block by block at the channel's transmit interval
    /// until stopped. While paused it keeps reading and drops what it read,
    /// so resuming sends what is live then, not what queued up meanwhile.
    private func streamLive(_ read: (Int) -> [Int16]) throws {
        let framesPerBlock = max(1, Int(format.sampleRate * Double(format.txIntervalMSec) / 1000.0))
        let intervalNanos = UInt64(max(1, format.txIntervalMSec)) * 1_000_000
        let prebufferBlocks = 3
        let silence = Array(repeating: Int16(0), count: framesPerBlock * Int(format.channels))
        for _ in 0..<prebufferBlocks where shouldContinue() {
            _ = try insert(samples: silence, frameOffset: 0, frameCount: framesPerBlock)
        }
        var nextSendTime = DispatchTime.now().uptimeNanoseconds + intervalNanos
        var wasPaused = false
        var resyncCount = 0
        while shouldContinue() {
            let now = DispatchTime.now().uptimeNanoseconds
            if nextSendTime > now {
                Thread.sleep(forTimeInterval: Double(nextSendTime - now) / 1_000_000_000.0)
            }
            guard shouldContinue() else { break }
            let block = read(framesPerBlock)
            if isPaused {
                wasPaused = true
            } else {
                if wasPaused {
                    wasPaused = false
                    for _ in 0..<prebufferBlocks where shouldContinue() {
                        _ = try insert(samples: silence, frameOffset: 0, frameCount: framesPerBlock)
                    }
                }
                _ = try insert(samples: block, frameOffset: 0, frameCount: framesPerBlock)
            }
            nextSendTime += intervalNanos
            let after = DispatchTime.now().uptimeNanoseconds
            if after > nextSendTime + intervalNanos * 4 {
                // A long stall (the app was suspended): start the pace again
                // rather than rushing to catch up.
                resyncCount += 1
                nextSendTime = after + intervalNanos
            }
        }
        mediaFileStreamingLogger.info("Live audio-block streaming ended: resyncs=\(resyncCount)")
    }

    private func decodeMediaFile() throws -> [Int16] {
        let inputFile = try AVAudioFile(forReading: url)
        let inputFormat = inputFile.processingFormat
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: format.sampleRate,
                                               channels: format.channels,
                                               interleaved: true) else {
            throw MediaFilePreparationError.invalidOutputFormat
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw MediaFilePreparationError.converterUnavailable
        }

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                                 frameCapacity: AVAudioFrameCount(inputFile.length)) else {
            throw MediaFilePreparationError.bufferUnavailable
        }
        try inputFile.read(into: inputBuffer)

        let outputFrameCapacity = AVAudioFrameCount(max(1, Int(ceil(Double(inputBuffer.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate)) + 1024))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
            throw MediaFilePreparationError.bufferUnavailable
        }

        var providedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            guard providedInput == false else {
                outStatus.pointee = .endOfStream
                return nil
            }
            providedInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if let conversionError {
            throw conversionError
        }
        if status == .error {
            throw MediaFilePreparationError.conversionFailed
        }

        guard let channelData = outputBuffer.int16ChannelData?[0] else {
            throw MediaFilePreparationError.bufferUnavailable
        }

        let sampleCount = Int(outputBuffer.frameLength) * Int(format.channels)
        let samples = Array(UnsafeBufferPointer(start: channelData, count: sampleCount))
        mediaFileStreamingLogger.info("Audio block audio file decoded: name=\(self.url.lastPathComponent, privacy: .public), inputSampleRate=\(inputFormat.sampleRate), inputChannels=\(inputFormat.channelCount), outputSampleRate=\(outputFormat.sampleRate), outputChannels=\(outputFormat.channelCount), outputFrames=\(outputBuffer.frameLength), txIntervalMSec=\(self.format.txIntervalMSec), streamID=\(self.streamID)")
        return samples
    }

    private func insert(samples: [Int16], frameOffset: Int, frameCount: Int) throws -> Int {
        let sampleOffset = frameOffset * Int(format.channels)
        var retryCount = 0
        while shouldContinue() {
            var block = AudioBlock()
            block.nStreamID = streamID
            block.nSampleRate = INT32(format.sampleRate.rounded())
            block.nChannels = INT32(format.channels)
            block.nSamples = INT32(frameCount)
            block.uSampleIndex = 0
            block.uStreamTypes = STREAMTYPE_VOICE.rawValue

            let inserted = samples.withUnsafeBufferPointer { sampleBuffer -> TTBOOL in
                block.lpRawAudio = UnsafeMutableRawPointer(mutating: sampleBuffer.baseAddress?.advanced(by: sampleOffset))
                return TT_InsertAudioBlock(ttInst, &block)
            }
            if inserted == TRUE {
                return retryCount
            }
            retryCount += 1
            Thread.sleep(forTimeInterval: 0.005)
        }
        return retryCount
    }

    private func shouldContinue() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped == false
    }

    private func waitWhilePaused() -> Bool {
        var didPause = false
        while true {
            lock.lock()
            let shouldWait = paused && stopped == false
            lock.unlock()
            guard shouldWait else { return didPause }
            didPause = true
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func setStopped() {
        lock.lock()
        stopped = true
        paused = false
        lock.unlock()
    }

    private func finish(_ result: Result<Void, Error>) {
        setStopped()
        DispatchQueue.main.async {
            self.onFinish(result)
        }
    }
}

private final class ConnectedServersTabBarDelegate: NSObject, UITabBarDelegate {
    weak var owner: MainTabBarController?

    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        owner?.connectedServerTabSelected(item)
    }
}

private final class AudioFileControlsViewController: UITableViewController {
    var isStreaming: () -> Bool = { false }
    var isPaused: () -> Bool = { false }
    var stream: (UIView) -> Void = { _ in }
    var togglePause: () -> Void = {}
    var stop: () -> Void = {}
    var isLooping: () -> Bool = { false }
    var setLooping: (Bool) -> Void = { _ in }
    /// The streaming volume in percent (50: unchanged).
    var volume: () -> Double = { 50 }
    var setVolume: (Double) -> Void = { _ in }
    private var refreshTimer: Timer?
    private var shownStreaming: Bool?
    private var shownPaused: Bool?
    private let loopSwitch = UISwitch()
    private let volumeSlider = UISlider()

    private let SECTION_CONTROLS = 0, SECTION_LOOP = 1, SECTION_VOLUME = 2

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Audio File", comment: "audio file controls")
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done,
                                                            target: self,
                                                            action: #selector(done))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "AudioFileControl")
        loopSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.setLooping(self.loopSwitch.isOn)
        }, for: .valueChanged)
        loopSwitch.accessibilityLabel = NSLocalizedString("Loop", comment: "audio file controls")
        volumeSlider.minimumValue = 0
        volumeSlider.maximumValue = 1
        volumeSlider.accessibilityLabel = NSLocalizedString("Streaming Volume", comment: "audio file controls")
        volumeSlider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            // steps of 10 %, like the other volume sliders
            let percent = (Double(self.volumeSlider.value) * 10).rounded() * 10
            self.volumeSlider.value = Float(percent / 100)
            self.setVolume(percent)
        }, for: .valueChanged)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loopSwitch.isOn = isLooping()
        volumeSlider.value = Float(volume() / 100)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Follows the stream: when the file ends, Stream Audio File again.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshControls()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refreshControls() {
        let streaming = isStreaming()
        let paused = isPaused()
        guard streaming != shownStreaming || paused != shownPaused else { return }
        tableView.reloadSections(IndexSet(integer: SECTION_CONTROLS), with: .none)
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == SECTION_CONTROLS ? (isStreaming() ? 2 : 1) : 1
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
        case SECTION_LOOP:
            return NSLocalizedString("The audio file starts again from the beginning when it ends, until you stop it.", comment: "audio file controls")
        case SECTION_VOLUME:
            return NSLocalizedString("How loud the audio file is for everyone in the channel. 50 % leaves it as it is.", comment: "audio file controls")
        default:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        switch indexPath.section {
        case SECTION_LOOP:
            cell.textLabel?.text = NSLocalizedString("Loop", comment: "audio file controls")
            cell.selectionStyle = .none
            cell.accessoryView = loopSwitch
            cell.isAccessibilityElement = false
            cell.textLabel?.isAccessibilityElement = false
            return cell
        case SECTION_VOLUME:
            cell.textLabel?.text = NSLocalizedString("Streaming Volume", comment: "audio file controls")
            cell.selectionStyle = .none
            volumeSlider.frame = CGRect(x: 0, y: 0, width: 160, height: 31)
            cell.accessoryView = volumeSlider
            cell.isAccessibilityElement = false
            cell.textLabel?.isAccessibilityElement = false
            cell.textLabel?.accessibilityElementsHidden = true
            return cell
        default:
            break
        }
        let streaming = isStreaming()
        let paused = isPaused()
        shownStreaming = streaming
        shownPaused = paused
        cell.textLabel?.textAlignment = .natural
        if streaming {
            if indexPath.row == 0 {
                cell.textLabel?.text = paused
                    ? NSLocalizedString("Resume Audio File", comment: "audio file controls")
                    : NSLocalizedString("Pause Audio File", comment: "audio file controls")
                cell.textLabel?.textColor = view.tintColor
            } else {
                cell.textLabel?.text = NSLocalizedString("Stop Audio File", comment: "audio file controls")
                cell.textLabel?.textColor = .systemRed
            }
        } else {
            cell.textLabel?.text = NSLocalizedString("Stream Audio File", comment: "audio file controls")
            cell.textLabel?.textColor = view.tintColor
        }
        cell.isAccessibilityElement = true
        cell.contentView.accessibilityElementsHidden = true
        cell.textLabel?.isAccessibilityElement = false
        cell.accessibilityLabel = cell.textLabel?.text
        cell.accessibilityTraits = .button
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == SECTION_CONTROLS else { return }
        let cell = tableView.cellForRow(at: indexPath)
        if isStreaming() {
            indexPath.row == 0 ? togglePause() : stop()
            tableView.reloadSections(IndexSet(integer: SECTION_CONTROLS), with: .none)
        } else if let cell {
            stream(cell)
        }
    }

    @objc private func done() {
        dismiss(animated: true)
    }
}

class MainTabBarController : UITabBarController, UIAlertViewDelegate, TeamTalkEvent, UIDocumentPickerDelegate {

    private(set) var teamTalkInstance: UnsafeMutableRawPointer?
    private var isMinimizing = false
    private let connectedServersScrollView = UIScrollView()
    private let connectedServersTabBar = UITabBar()
    private let connectedServersTabBarDelegate = ConnectedServersTabBarDelegate()
    private var connectedServersTabBarWidthConstraint: NSLayoutConstraint?


    // timer for polling TeamTalk client events
    var polltimer : Timer?
    // reconnect timer
    var reconnecttimer : Timer?
    // ip-addr and login information for current server
    var server = Server()
    private var publicServerName = ""
    // active command
    var cmdid : INT32 = 0
    private var isClosingConnection = false
    private var suppressFileUpdateAnnouncements = false
    private var isAdminUser = false
    private var canBroadcastMessages = false
    private var channelMessagesViewController: TextMessageViewController?
    private var settingsViewController: SettingsViewController?
    private var muteToolbarButton: UIButton?
    private var mediaFileToolbarButton: UIButton?
    private var pauseMediaFileToolbarButton: UIButton?
    /// A file the TeamTalk library streams itself (the official way), a
    /// temporary copy.
    private var officialFileURL: URL?
    private var officialMediaFilePaused = false
    private var officialElapsedMSec: UInt32 = 0
    /// When the library last started streaming the file (events from an
    /// earlier run of a looping file come after it).
    private var officialStartedAt = Date.distantPast
    /// AudioNet and an audio file mixed. It goes out as the media file
    /// stream (a live source of the library, `mixerLivePath`) or, without
    /// the right to stream media files, as voice (`audioBlockMediaStreamer`).
    private var mixer: ChannelMixer?
    private var mixerLiveID: Int?
    private var mixerLivePath = ""
    private var mixSinkPaused = false
    private var audioBlockMediaStreamer: AudioBlockMediaStreamer?
    private var audioBlockMediaStreamerID: UUID?
    private var mediaFileWasVoiceTransmitting = false
    private var mediaFileEnabledOwnVoiceSubscription = false
    private var mediaFileOwnUserID: INT32 = 0
    /// Recording this session's channel to files.
    private lazy var recorder: ChannelRecorder = {
        let recorder = ChannelRecorder(instance: { [weak self] in self?.teamTalkInstance },
                                       serverName: { [weak self] in self?.serverDisplayName ?? "TeamTalk" })
        recorder.changed = { [weak self] in
            self?.avoidRecordingOwnEcho()
            self?.updateRecordToolbarButton()
            (self?.recordingViewController)?.reload()
        }
        return recorder
    }()
    private var recordToolbarButton: UIButton?
    private weak var recordingViewController: RecordingViewController?

    let CHANNELTAB = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        TT_SetLicenseInformation(REGISTRATION_NAME, REGISTRATION_KEY)
        teamTalkInstance = TT_InitTeamTalkPoll()
        ttInst = teamTalkInstance
        // Servers and other users see "TeamTalk NG" and this app's version.
        TTNG_SetClientVersion(teamTalkInstance, AppInfo.getClientVersion())
        NotificationCenter.default.addObserver(self, selector: #selector(audioNetStreamEnded(_:)),
                                               name: .audioNetStreamEnded, object: nil)
        
        addToTTMessages(self)
        
        let initialViewControllers = viewControllers ?? []
        let channelsTab = initialViewControllers[0] as! ChannelListViewController
        let chatTab = initialViewControllers[1] as! TextMessageViewController
        let prefTab = initialViewControllers[2] as! SettingsViewController
        channelMessagesViewController = chatTab
        settingsViewController = prefTab
        viewControllers = [channelsTab]
        tabBar.isHidden = true

        addToTTMessages(channelsTab)
        addToTTMessages(chatTab)
        addToTTMessages(prefTab)
        configureTabs()
        configureBottomToolbar()
        configureConnectedServerNavigation()
        ConnectedServerManager.shared.register(self)
        
        polltimer = Timer.scheduledTimer(timeInterval: 0.1, target: self, selector: #selector(MainTabBarController.timerEvent), userInfo: nil, repeats: true)
        
        connectToServer()
    }

    func matches(server other: Server) -> Bool {
        server.ipaddr.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(other.ipaddr.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
            && server.tcpport == other.tcpport
            && server.udpport == other.udpport
            && server.encrypted == other.encrypted
    }

    private func configureConnectedServerNavigation() {
        refreshServerNavigationButtons()
        navigationItem.title = nil
        connectedServersScrollView.translatesAutoresizingMaskIntoConstraints = false
        connectedServersScrollView.showsHorizontalScrollIndicator = false
        connectedServersScrollView.isAccessibilityElement = false
        connectedServersTabBar.translatesAutoresizingMaskIntoConstraints = false
        connectedServersTabBarDelegate.owner = self
        connectedServersTabBar.delegate = connectedServersTabBarDelegate
        connectedServersTabBar.accessibilityLabel = NSLocalizedString("Connected Servers", comment: "main-tab")
        connectedServersTabBar.accessibilityTraits = .tabBar
        connectedServersScrollView.addSubview(connectedServersTabBar)
        view.addSubview(connectedServersScrollView)
        connectedServersTabBarWidthConstraint = connectedServersTabBar.widthAnchor.constraint(equalToConstant: view.bounds.width)
        connectedServersTabBarWidthConstraint?.isActive = true
        NSLayoutConstraint.activate([
            connectedServersScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            connectedServersScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            connectedServersScrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            connectedServersScrollView.heightAnchor.constraint(equalToConstant: 49),
            connectedServersTabBar.leadingAnchor.constraint(equalTo: connectedServersScrollView.contentLayoutGuide.leadingAnchor),
            connectedServersTabBar.trailingAnchor.constraint(equalTo: connectedServersScrollView.contentLayoutGuide.trailingAnchor),
            connectedServersTabBar.topAnchor.constraint(equalTo: connectedServersScrollView.contentLayoutGuide.topAnchor),
            connectedServersTabBar.bottomAnchor.constraint(equalTo: connectedServersScrollView.contentLayoutGuide.bottomAnchor),
            connectedServersTabBar.heightAnchor.constraint(equalTo: connectedServersScrollView.frameLayoutGuide.heightAnchor)
        ])
        let leftSwipe = UISwipeGestureRecognizer(target: self, action: #selector(switchServerBySwipe(_:)))
        leftSwipe.direction = .left
        let rightSwipe = UISwipeGestureRecognizer(target: self, action: #selector(switchServerBySwipe(_:)))
        rightSwipe.direction = .right
        viewControllers?[CHANNELTAB].view.addGestureRecognizer(leftSwipe)
        viewControllers?[CHANNELTAB].view.addGestureRecognizer(rightSwipe)
        refreshConnectedServerNavigation()
    }

    private func refreshServerNavigationButtons() {
        let minimizeButton = UIBarButtonItem(image: UIImage(systemName: "arrow.down.right.and.arrow.up.left"),
                                             style: .plain,
                                             target: self,
                                             action: #selector(minimizeServer))
        minimizeButton.accessibilityLabel = NSLocalizedString("Minimize", comment: "main-tab")
        var buttons = [minimizeButton]
        if server.servertype == .LOCAL && hasExactSavedServerCredentials == false {
            let saveButton = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.down"),
                                             style: .plain,
                                             target: self,
                                             action: #selector(showSaveServerDialog))
            saveButton.accessibilityLabel = NSLocalizedString("Save Server", comment: "main-tab")
            buttons.append(saveButton)
        }
        navigationItem.rightBarButtonItems = buttons
    }

    private var hasExactSavedServerCredentials: Bool {
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

    func refreshConnectedServerNavigation() {
        guard isViewLoaded else { return }
        let manager = ConnectedServerManager.shared
        connectedServersScrollView.isHidden = !manager.showsSessionTabs
        viewControllers?[CHANNELTAB].additionalSafeAreaInsets.top = manager.showsSessionTabs ? 49 : 0
        let items = manager.sessions.enumerated().map { index, session in
            UITabBarItem(title: session.serverDisplayName, image: UIImage(systemName: "server.rack"), tag: index)
        }
        connectedServersTabBar.setItems(items, animated: false)
        connectedServersTabBarWidthConstraint?.constant = max(view.bounds.width, CGFloat(items.count) * 120)
        if let index = manager.sessions.firstIndex(where: { $0 === self }), items.indices.contains(index) {
            connectedServersTabBar.selectedItem = items[index]
            let itemWidth = connectedServersTabBarWidthConstraint.map { $0.constant / CGFloat(items.count) } ?? 120
            connectedServersScrollView.scrollRectToVisible(CGRect(x: CGFloat(index) * itemWidth,
                                                                   y: 0,
                                                                   width: itemWidth,
                                                                   height: 49),
                                                           animated: false)
        }
        view.bringSubviewToFront(connectedServersScrollView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        connectedServersTabBarWidthConstraint?.constant = max(view.bounds.width,
                                                                CGFloat(connectedServersTabBar.items?.count ?? 0) * 120)
        view.bringSubviewToFront(connectedServersScrollView)
    }

    var serverDisplayName: String {
        if server.name.isEmpty == false {
            return server.name
        }
        if publicServerName.isEmpty == false {
            return publicServerName
        }
        return NSLocalizedString("Server", comment: "unnamed connected server")
    }

    func updatePublicServerName(_ name: String) {
        publicServerName = name
        refreshServerNavigationButtons()
        ConnectedServerManager.shared.sessions.forEach { $0.refreshConnectedServerNavigation() }
    }

    fileprivate func connectedServerTabSelected(_ item: UITabBarItem) {
        guard ConnectedServerManager.shared.sessions.indices.contains(item.tag) else { return }
        let target = ConnectedServerManager.shared.sessions[item.tag]
        // UIKit is still dispatching the tab selection here. Defer replacing the
        // navigation stack so this controller and its tab bar stay alive until
        // the delegate callback has returned.
        DispatchQueue.main.async { [weak self, weak target] in
            guard let self,
                  let target,
                  ConnectedServerManager.shared.sessions.contains(where: { $0 === target }),
                  let navigationController = self.navigationController else { return }
            ConnectedServerManager.shared.show(target, in: navigationController)
        }
    }

    @objc private func minimizeServer() {
        prepareForSessionSwitch()
        navigationController?.popToRootViewController(animated: true)
    }

    func prepareForSessionSwitch() {
        isMinimizing = true
    }

    @objc private func switchServerBySwipe(_ gesture: UISwipeGestureRecognizer) {
        let offset = gesture.direction == .left ? 1 : -1
        _ = switchServer(offset: offset, announceForVoiceOver: false)
    }

    @discardableResult
    func switchServer(offset: Int, announceForVoiceOver: Bool) -> Bool {
        guard let target = ConnectedServerManager.shared.adjacent(to: self, offset: offset),
              let navigationController else { return false }
        ConnectedServerManager.shared.show(target, in: navigationController)
        if announceForVoiceOver {
            UIAccessibility.post(notification: .pageScrolled, argument: target.serverDisplayName)
        }
        return true
    }

    
    func configureTabs() {
        viewControllers?[CHANNELTAB].tabBarItem.title = NSLocalizedString("Channels", comment: "main-tab")

        if #available(iOS 13.0, *) {
            viewControllers?[CHANNELTAB].tabBarItem.image = UIImage(systemName: "list.bullet")
        }
    }

    func configureBottomToolbar() {
        let settingsButton = bottomToolbarButton(imageName: "gearshape",
                                                 accessibilityLabel: NSLocalizedString("App Settings", comment: "main-tab"),
                                                 action: #selector(showSettings))
        settingsButton.accessibilityLabel = NSLocalizedString("App Settings", comment: "main-tab")
        var buttons: [UIButton] = []
        let channelsTab = viewControllers?[CHANNELTAB] as? ChannelListViewController
        let canUseVoice = channelsTab?.canUseVoiceTx() == true
        let isInChannel = channelsTab?.isInChannel() == true
        let channelSupportsAudio = isInChannel && channelsTab?.channelSupportsAudio(channelsTab?.mychannel ?? Channel()) == true
        muteToolbarButton = nil
        mediaFileToolbarButton = nil
        pauseMediaFileToolbarButton = nil

        if canUseVoice && audioBlockStreamingActive() == false {
            let muteButton = bottomToolbarButton(imageName: "mic.slash",
                                                 accessibilityLabel: NSLocalizedString("Unmute", comment: "channel list"),
                                                 action: #selector(toggleVoiceTransmission))
            muteToolbarButton = muteButton
            buttons += [muteButton]
        }

        if canUseVoice {
            let audioButton = bottomToolbarButton(imageName: "speaker.wave.2.fill",
                                                  accessibilityLabel: NSLocalizedString("Audio Controls", comment: "channel list"),
                                                  action: #selector(showAudioControlsFromToolbar))
            buttons += [audioButton]
        }

        buttons += [settingsButton]

        if isInChannel {
            let messagesButton = bottomToolbarButton(imageName: "message",
                                                     accessibilityLabel: NSLocalizedString("Messages", comment: "main-tab"),
                                                     action: #selector(showChannelMessages))
            buttons += [messagesButton]
            if channelSupportsAudio {
                let mediaFileButton = bottomToolbarButton(imageName: "play.rectangle",
                                                          accessibilityLabel: NSLocalizedString("Audio File", comment: "main-tab"),
                                                          action: #selector(showAudioFileControls))
                mediaFileToolbarButton = mediaFileButton
                buttons += [mediaFileButton]
            }
            if channelSupportsAudio {
                let audioNetButton = bottomToolbarButton(imageName: "dot.radiowaves.left.and.right",
                                                         accessibilityLabel: "AudioNet",
                                                         action: #selector(showAudioNet))
                buttons += [audioNetButton]
            }
            // Only where there is audio you may record; while recording (or
            // waiting to) it stays, so it can be stopped.
            recordToolbarButton = nil
            if (channelSupportsAudio && recordingProblem() == nil) || recorder.wanted {
                let recordButton = bottomToolbarButton(imageName: "record.circle",
                                                       accessibilityLabel: NSLocalizedString("Record", comment: "main-tab"),
                                                       action: #selector(showRecording))
                recordToolbarButton = recordButton
                buttons += [recordButton]
            }
            let filesButton = bottomToolbarButton(imageName: "folder",
                                                  accessibilityLabel: NSLocalizedString("Files", comment: "main-tab"),
                                                  action: #selector(showChannelFiles))
            buttons += [filesButton]
        }

        if isAdminUser {
            let manageButton = bottomToolbarButton(imageName: "person.2.badge.gearshape",
                                                   accessibilityLabel: NSLocalizedString("Manage Server", comment: "main-tab"),
                                                   action: #selector(showManageServerActions))
            if #available(iOS 14.0, *) {
                manageButton.menu = manageServerMenu()
                manageButton.showsMenuAsPrimaryAction = true
            }
            buttons += [manageButton]
        } else {
            let myInformationButton = bottomToolbarButton(imageName: "person",
                                                          accessibilityLabel: NSLocalizedString("View My Information", comment: "main-tab"),
                                                          action: #selector(showMyInformation))
            buttons += [myInformationButton]
        }
        if canBroadcastMessages {
            let broadcastButton = bottomToolbarButton(imageName: "star.bubble",
                                                      accessibilityLabel: NSLocalizedString("Broadcast Message", comment: "main-tab"),
                                                      action: #selector(showBroadcastMessageAlert))
            buttons += [broadcastButton]
        }

        toolbarItems = [UIBarButtonItem(customView: bottomToolbarScrollView(buttons: buttons))]
        navigationController?.setToolbarHidden(false, animated: false)
        updateMuteToolbarButton()
        updateMediaFileToolbarButton()
        updatePauseMediaFileToolbarButton()
        updateRecordToolbarButton()
    }

    private func updateRecordToolbarButton() {
        guard let button = recordToolbarButton else { return }
        let on = recorder.isRecording
        button.setImage(UIImage(systemName: on ? "record.circle.fill" : "record.circle"), for: .normal)
        button.tintColor = on ? .systemRed : nil
        button.accessibilityValue = on ? NSLocalizedString("Recording", comment: "main-tab") : nil
    }

    @objc private func showRecording() {
        let controller = RecordingViewController(style: .insetGrouped)
        controller.recorder = recorder
        controller.problem = { [weak self] in self?.recordingProblem() }
        recordingViewController = controller
        present(UINavigationController(rootViewController: controller), animated: true)
    }

    /// Why this channel cannot be recorded by this user, in words.
    private func recordingProblem() -> String? {
        guard let instance = teamTalkInstance else { return nil }
        var channel = Channel()
        guard TT_GetChannel(instance, TT_GetMyChannelID(instance), &channel) == TRUE,
              channel.uChannelType & CHANNEL_NO_RECORDING.rawValue != 0,
              TT_GetMyUserRights(instance) & USERRIGHT_RECORD_VOICE.rawValue == 0,
              TT_GetMyUserType(instance) & USERTYPE_ADMIN.rawValue == 0 else { return nil }
        return NSLocalizedString("This channel does not allow recording.", comment: "recording")
    }

    private func bottomToolbarButton(imageName: String, accessibilityLabel: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: imageName), for: .normal)
        button.accessibilityLabel = accessibilityLabel
        button.addTarget(self, action: action, for: .touchUpInside)
        button.widthAnchor.constraint(equalToConstant: 48).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return button
    }

    private func bottomToolbarScrollView(buttons: [UIButton]) -> UIScrollView {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 44))
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(equalToConstant: 44).isActive = true
        scrollView.widthAnchor.constraint(equalToConstant: view.bounds.width).isActive = true

        let stackView = UIStackView(arrangedSubviews: buttons)
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.distribution = .equalSpacing
        stackView.spacing = 16
        stackView.layoutMargins = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stackView.isLayoutMarginsRelativeArrangement = true
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        return scrollView
    }

    @objc private func toggleVoiceTransmission() {
        guard let channelsTab = viewControllers?[CHANNELTAB] as? ChannelListViewController,
              channelsTab.canUseVoiceTx() else { return }
        let transmitting = TT_GetFlags(ttInst) & CLIENT_TX_VOICE.rawValue == CLIENT_TX_VOICE.rawValue
        channelsTab.enableVoiceTx(!transmitting)
        updateBottomToolbar()
    }

    @objc private func showAudioControlsFromToolbar() {
        guard let channelsTab = viewControllers?[CHANNELTAB] as? ChannelListViewController else { return }
        let controls = SoundDevicesViewController(audioControls: true)
        controls.userIDs = Set(channelsTab.users.keys)
        let navigationController = UINavigationController(rootViewController: controls)
        navigationController.modalPresentationStyle = .formSheet
        present(navigationController, animated: true)
    }

    func updateBottomToolbar() {
        configureBottomToolbar()
    }

    private func updateMuteToolbarButton() {
        guard let muteButton = muteToolbarButton,
              let channelsTab = viewControllers?[CHANNELTAB] as? ChannelListViewController else { return }
        let canTransmit = channelsTab.canUseVoiceTx()
        let transmitting = canTransmit && (TT_GetFlags(ttInst) & CLIENT_TX_VOICE.rawValue == CLIENT_TX_VOICE.rawValue)
        muteButton.isEnabled = canTransmit
        muteButton.setImage(UIImage(systemName: transmitting ? "mic.fill" : "mic.slash"), for: .normal)
        muteButton.accessibilityLabel = NSLocalizedString(transmitting ? "Mute" : "Unmute", comment: "channel list")
    }

    private func updateMediaFileToolbarButton() {
        guard let mediaFileButton = mediaFileToolbarButton else { return }
        let allowed = isStreamingMediaFile() || canStreamAudioFiles()
        mediaFileButton.isEnabled = allowed
        mediaFileButton.setImage(UIImage(systemName: "play.rectangle"), for: .normal)
        mediaFileButton.accessibilityLabel = NSLocalizedString("Audio File", comment: "main-tab")
        mediaFileButton.accessibilityHint = allowed ? nil : NSLocalizedString("You do not have permission to stream audio files on this server.", comment: "main-tab")
    }

    private func updatePauseMediaFileToolbarButton() {
        guard let pauseButton = pauseMediaFileToolbarButton else { return }
        let paused = isMediaFileStreamingPaused()
        pauseButton.setImage(UIImage(systemName: paused ? "play.fill" : "pause.fill"), for: .normal)
        pauseButton.accessibilityLabel = NSLocalizedString(paused ? "Resume Audio File" : "Pause Audio File", comment: "main-tab")
    }

    private var hasMediaFileRight: Bool {
        guard let instance = teamTalkInstance else { return false }
        return TT_GetMyUserRights(instance) & USERRIGHT_TRANSMIT_MEDIAFILE_AUDIO.rawValue != 0
    }

    private func channelHasAudio() -> Bool {
        guard teamTalkInstance != nil,
              let channelsTab = viewControllers?[CHANNELTAB] as? ChannelListViewController else { return false }
        return channelsTab.channelSupportsAudio(channelsTab.mychannel)
    }

    /// Audio files need the server's right to stream media files; they are
    /// never sent as voice, which would get around that.
    private func canStreamAudioFiles() -> Bool {
        channelHasAudio() && hasMediaFileRight
    }

    /// AudioNet can go out as the media file stream or, like a microphone,
    /// as voice.
    private func canSendAudioNet() -> Bool {
        guard channelHasAudio(), let instance = teamTalkInstance else { return false }
        let rights = TT_GetMyUserRights(instance)
        return (rights & USERRIGHT_TRANSMIT_VOICE.rawValue) != 0
            || (rights & USERRIGHT_TRANSMIT_MEDIAFILE_AUDIO.rawValue) != 0
    }

    /// Something goes out as voice instead of the microphone.
    private func audioBlockStreamingActive() -> Bool {
        audioBlockMediaStreamer?.isActive == true
    }

    private func isStreamingMediaFile() -> Bool {
        officialFileURL != nil || mixer?.hasFile == true
    }

    /// The voice stream is carrying the mix (not paused).
    private func isVoiceSinkSending() -> Bool {
        guard let streamer = audioBlockMediaStreamer else { return false }
        return streamer.isActive && streamer.isPaused == false
    }

    private func isMediaFileStreamingPaused() -> Bool {
        if officialFileURL != nil {
            return officialMediaFilePaused
        }
        return mixer?.hasFile == true && mixer?.isFilePaused == true
    }

    @objc private func showAudioFileControls() {
        presentAudioFileControls()
    }

    private func presentAudioFileControls() {
        let controls = AudioFileControlsViewController(style: .insetGrouped)
        controls.isStreaming = { [weak self] in self?.isStreamingMediaFile() == true }
        controls.isPaused = { [weak self] in self?.isMediaFileStreamingPaused() == true }
        controls.stream = { [weak self] sourceView in self?.showMediaFileSourceOptions(sourceView: sourceView) }
        controls.togglePause = { [weak self] in self?.toggleMediaFilePause() }
        controls.stop = { [weak self] in self?.stopMediaFileStreaming() }
        controls.isLooping = { [weak self] in self?.loopsAudioFiles == true }
        controls.setLooping = { [weak self] in self?.setLoopsAudioFiles($0) }
        controls.volume = { streamVolumePercent(PREF_STREAM_FILE_VOLUME) }
        controls.setVolume = { [weak self] in self?.setFileStreamVolume($0) }
        present(UINavigationController(rootViewController: controls), animated: true)
    }

    @objc private func toggleMediaFilePause() {
        if isMediaFileStreamingPaused() {
            resumeMediaFileStreaming()
        } else {
            pauseMediaFileStreaming()
        }
    }

    private var mediaFilePresentationController: UIViewController {
        presentedViewController ?? self
    }

    private func showMediaFilePicker() {
        let picker: UIDocumentPickerViewController
        if #available(iOS 14.0, *) {
            picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio], asCopy: true)
        } else {
            picker = UIDocumentPickerViewController(documentTypes: ["public.audio"], in: .import)
        }
        picker.delegate = self
        picker.allowsMultipleSelection = false
        mediaFilePresentationController.present(picker, animated: true)
    }

    private func showMediaFileSourceOptions(sourceView: UIView) {
        let alert = UIAlertController(title: NSLocalizedString("Stream Audio File", comment: "main-tab"),
                                      message: nil,
                                      preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Select File", comment: "main-tab"), style: .default) { [weak self] _ in
            self?.showMediaFilePicker()
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Detect Clipboard", comment: "main-tab"), style: .default) { [weak self] _ in
            self?.streamAudioFileFromClipboard()
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "button"), style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = sourceView.bounds
        }
        mediaFilePresentationController.present(alert, animated: true)
    }

    private func streamAudioFileFromClipboard() {
        let pasteboard = UIPasteboard.general

        if loadAudioFileFromClipboardItemProviders(pasteboard.itemProviders) {
            return
        }

        for type in pasteboard.types where isAudioPasteboardType(type) {
            guard let data = pasteboard.data(forPasteboardType: type) else { continue }
            do {
                let fileName = clipboardAudioFileName(forPasteboardType: type)
                let mediaURL = try temporaryMediaURL(forClipboardAudioData: data, fileName: fileName)
                mediaFileStreamingLogger.info("Prepared clipboard audio for streaming: type=\(type, privacy: .public), bytes=\(data.count)")
                startMediaFileStreaming(from: mediaURL)
                return
            } catch {
                mediaFileStreamingLogger.error("Failed to prepare clipboard audio data: type=\(type, privacy: .public), error=\(error.localizedDescription, privacy: .public)")
                showMediaFileStreamingError(error.localizedDescription)
                return
            }
        }

        showMediaFileStreamingError(NSLocalizedString("No audio was found on the clipboard.", comment: "main-tab"))
    }

    private func loadAudioFileFromClipboardItemProviders(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            guard let typeIdentifier = provider.registeredTypeIdentifiers.first(where: isAudioPasteboardType) else {
                continue
            }
            loadClipboardAudio(from: provider, typeIdentifier: typeIdentifier)
            return true
        }
        return false
    }

    private func loadClipboardAudio(from provider: NSItemProvider, typeIdentifier: String) {
        mediaFileStreamingLogger.info("Loading clipboard audio item provider: type=\(typeIdentifier, privacy: .public)")
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, fileError in
            guard let self else { return }

            if let url {
                do {
                    let fileName = self.clipboardAudioFileName(forPasteboardType: typeIdentifier, suggestedName: provider.suggestedName ?? url.lastPathComponent)
                    let mediaURL = try self.copyMediaFileToTemporaryLocation(from: url, fileName: fileName)
                    DispatchQueue.main.async {
                        self.startMediaFileStreaming(from: mediaURL)
                    }
                } catch {
                    DispatchQueue.main.async {
                        mediaFileStreamingLogger.error("Failed to prepare clipboard audio file provider: type=\(typeIdentifier, privacy: .public), error=\(error.localizedDescription, privacy: .public)")
                        self.showMediaFileStreamingError(error.localizedDescription)
                    }
                }
                return
            }

            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] data, dataError in
                guard let self else { return }

                guard let data else {
                    DispatchQueue.main.async {
                        let errorDescription = dataError?.localizedDescription ?? fileError?.localizedDescription ?? NSLocalizedString("Could not load audio from the clipboard.", comment: "main-tab")
                        mediaFileStreamingLogger.error("Failed to load clipboard audio provider: type=\(typeIdentifier, privacy: .public), error=\(errorDescription, privacy: .public)")
                        self.showMediaFileStreamingError(errorDescription)
                    }
                    return
                }

                do {
                    let fileName = self.clipboardAudioFileName(forPasteboardType: typeIdentifier, suggestedName: provider.suggestedName)
                    let mediaURL = try self.temporaryMediaURL(forClipboardAudioData: data, fileName: fileName)
                    DispatchQueue.main.async {
                        self.startMediaFileStreaming(from: mediaURL)
                    }
                } catch {
                    DispatchQueue.main.async {
                        mediaFileStreamingLogger.error("Failed to prepare clipboard audio data provider: type=\(typeIdentifier, privacy: .public), error=\(error.localizedDescription, privacy: .public)")
                        self.showMediaFileStreamingError(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func isAudioPasteboardType(_ type: String) -> Bool {
        if #available(iOS 14.0, *), let uniformType = UTType(type) {
            return uniformType.conforms(to: .audio)
        }

        let lowercasedType = type.lowercased()
        return lowercasedType.contains("audio")
            || lowercasedType.contains("mp3")
            || lowercasedType.contains("mpeg-4")
            || lowercasedType.contains("waveform")
            || lowercasedType.contains("wav")
            || lowercasedType.contains("aiff")
            || lowercasedType.contains("caf")
            || lowercasedType.contains("midi")
    }

    private func clipboardAudioFileName(forPasteboardType type: String) -> String {
        clipboardAudioFileName(forPasteboardType: type, suggestedName: nil)
    }

    private func clipboardAudioFileName(forPasteboardType type: String, suggestedName: String?) -> String {
        let fileExtension: String
        if #available(iOS 14.0, *),
           let uniformType = UTType(type),
           let preferredExtension = uniformType.preferredFilenameExtension,
           preferredExtension.isEmpty == false {
            fileExtension = preferredExtension
        } else {
            let lowercasedType = type.lowercased()
            if lowercasedType.contains("waveform") || lowercasedType.contains("wav") {
                fileExtension = "wav"
            } else if lowercasedType.contains("aiff") {
                fileExtension = "aiff"
            } else if lowercasedType.contains("mpeg-4") || lowercasedType.contains("m4a") {
                fileExtension = "m4a"
            } else if lowercasedType.contains("caf") {
                fileExtension = "caf"
            } else if lowercasedType.contains("midi") {
                fileExtension = "mid"
            } else {
                fileExtension = "mp3"
            }
        }

        if let suggestedName = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines),
           suggestedName.isEmpty == false {
            let url = URL(fileURLWithPath: suggestedName)
            if url.pathExtension.isEmpty {
                return "\(suggestedName).\(fileExtension)"
            }
            return suggestedName
        }

        return "Clipboard Audio.\(fileExtension)"
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let sourceURL = urls.first else { return }

        do {
            mediaFileStreamingLogger.info("Selected audio file: name=\(sourceURL.lastPathComponent, privacy: .public), path=\(sourceURL.path, privacy: .private)")
            let mediaURL = try temporaryMediaURL(for: sourceURL)
            controller.dismiss(animated: true) { [weak self] in
                self?.startMediaFileStreaming(from: mediaURL)
            }
        } catch {
            mediaFileStreamingLogger.error("Failed to prepare selected audio file: name=\(sourceURL.lastPathComponent, privacy: .public), error=\(error.localizedDescription, privacy: .public)")
            controller.dismiss(animated: true) { [weak self] in
                self?.showMediaFileStreamingError(error.localizedDescription)
            }
        }
    }

    private func startMediaFileStreaming(from url: URL) {
        guard canStreamAudioFiles() else {
            try? FileManager.default.removeItem(at: url)
            showMediaFileStreamingError(NSLocalizedString("You do not have permission to stream audio files on this server.", comment: "main-tab"))
            return
        }
        if let mixer {
            // AudioNet is going out: the file joins it.
            do {
                let source = try MixerFileSource(url: url, sampleRate: Double(mixer.sampleRate), channels: mixer.channels)
                if let previous = mixer.fileURL {
                    try? FileManager.default.removeItem(at: previous)
                }
                mixer.setFile(source)
                updateMixSink()
                updateBottomToolbar()
            } catch {
                try? FileManager.default.removeItem(at: url)
                showMediaFileStreamingError(error.localizedDescription)
            }
            return
        }
        if startOfficialMediaFileStreaming(from: url) {
            return
        }
        if let error = startMix(file: url, offsetMSec: 0, filePaused: false, tap: nil) {
            try? FileManager.default.removeItem(at: url)
            showMediaFileStreamingError(error)
        }
    }

    /// Streams a file as TeamTalk's media file stream (what TeamTalk for
    /// Windows and macOS do): others see and control it as a media file,
    /// and the microphone stays available. Needs the right to stream media
    /// files and a file the library can open.
    private func startOfficialMediaFileStreaming(from url: URL) -> Bool {
        guard let instance = teamTalkInstance, hasMediaFileRight else { return false }
        var info = MediaFileInfo()
        guard TT_GetMediaFileInfo(url.path, &info) == TRUE else {
            mediaFileStreamingLogger.notice("The TeamTalk library cannot open this file; mixing it instead.")
            return false
        }
        var playback = MediaFilePlayback()
        playback.uOffsetMSec = 0
        playback.bPaused = FALSE
        playback.audioPreprocessor = officialFilePreprocessor()
        var video = VideoCodec()
        video.nCodec = NO_CODEC
        guard TT_StartStreamingMediaFileToChannelEx(instance, url.path, &playback, &video) == TRUE else {
            mediaFileStreamingLogger.error("TT_StartStreamingMediaFileToChannelEx failed; mixing the file instead.")
            return false
        }
        officialMediaFilePaused = false
        officialElapsedMSec = 0
        officialStartedAt = Date()
        officialFileURL = url
        mediaFileStreamingLogger.notice("Started official media file streaming: name=\(url.lastPathComponent, privacy: .public), durationMSec=\(info.uDurationMSec)")
        updateBottomToolbar()
        return true
    }

    private func setOfficialMediaFilePaused(_ paused: Bool) {
        guard updateMediaStream(paused: paused, preprocessor: officialFilePreprocessor()) else {
            showMediaFileStreamingError(paused ? NSLocalizedString("Could not pause the audio file.", comment: "main-tab")
                                               : NSLocalizedString("Could not resume the audio file.", comment: "main-tab"))
            return
        }
        officialMediaFilePaused = paused
        updateBottomToolbar()
    }

    private func updateMediaStream(paused: Bool, preprocessor: AudioPreprocessor = newAudioPreprocessor(preprocessor: NO_AUDIOPREPROCESSOR)) -> Bool {
        var playback = MediaFilePlayback()
        playback.uOffsetMSec = TT_MEDIAPLAYBACK_OFFSET_IGNORE
        playback.bPaused = paused ? TRUE : FALSE
        playback.audioPreprocessor = preprocessor
        return TT_UpdateStreamingMediaFileToChannel(teamTalkInstance, &playback, nil) == TRUE
    }

    /// A file the library streams gets its volume from TeamTalk's own gain
    /// (as in BearWare's clients); in the mix the mixer applies it.
    private func officialFilePreprocessor() -> AudioPreprocessor {
        var preprocessor = newAudioPreprocessor(preprocessor: TEAMTALK_AUDIOPREPROCESSOR)
        preprocessor.ttpreprocessor.nGainLevel = INT32(streamGainLevel(percent: streamVolumePercent(PREF_STREAM_FILE_VOLUME)))
        return preprocessor
    }

    /// How loud the audio file you stream is sent (remembered).
    private func setFileStreamVolume(_ percent: Double) {
        UserDefaults.standard.set(percent, forKey: PREF_STREAM_FILE_VOLUME)
        if officialFileURL != nil {
            _ = updateMediaStream(paused: officialMediaFilePaused, preprocessor: officialFilePreprocessor())
        }
        applyMixGains()
    }

    /// How loud the AudioNet sound you send is (remembered).
    private func setAudioNetStreamVolume(_ percent: Double) {
        UserDefaults.standard.set(percent, forKey: PREF_STREAM_AUDIONET_VOLUME)
        applyMixGains()
    }

    private func applyMixGains() {
        mixer?.setGains(filePercent: streamVolumePercent(PREF_STREAM_FILE_VOLUME),
                        audioNetPercent: streamVolumePercent(PREF_STREAM_AUDIONET_VOLUME))
    }

    /// Audio files start again when they end.
    private var loopsAudioFiles: Bool {
        UserDefaults.standard.bool(forKey: PREF_STREAM_LOOP)
    }

    private func setLoopsAudioFiles(_ loop: Bool) {
        UserDefaults.standard.set(loop, forKey: PREF_STREAM_LOOP)
        mixer?.setLoop(loop)
    }

    private func removeOfficialFile() {
        if let url = officialFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        officialFileURL = nil
        officialMediaFilePaused = false
    }

    private func samePath(_ path: String, _ url: URL) -> Bool {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            == url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Progress and end of the media file stream (the official file or the
    /// mix), told apart by name.
    private func mediaFileStreamEvent(_ info: MediaFileInfo) {
        let name = fromTTString(info.szFileName)
        let ended = [MFS_FINISHED, MFS_ABORTED, MFS_ERROR, MFS_CLOSED].contains(info.nStatus)
        if let url = officialFileURL, samePath(name, url) {
            officialElapsedMSec = info.uElapsedMSec
            // A stream stopped to loop the file can report closing after
            // the new one started: only a stream that is gone has ended.
            let stillStreaming = teamTalkInstance.map { TT_GetFlags($0) & CLIENT_STREAM_AUDIO.rawValue != 0 } ?? false
            let earlierRun = Date().timeIntervalSince(officialStartedAt) < 1
            if ended && earlierRun == false && (info.nStatus == MFS_FINISHED || stillStreaming == false) {
                officialFileEnded(finished: info.nStatus == MFS_FINISHED)
            }
        }
        else if mixerLiveID != nil, name == mixerLivePath, info.nStatus == MFS_ERROR || info.nStatus == MFS_ABORTED {
            if mixer?.hasAudioNet == true {
                AudioNetBridge.shared.stopSending()
            }
            stopMix()
            showMediaFileStreamingError(NSLocalizedString("Sending to the channel stopped because of an error.", comment: "main-tab"))
        }
    }

    /// The library stopped streaming the file (its flag is gone) without an
    /// event this app recognised: tidy up, or play it again when looping.
    private func checkOfficialFileStillStreaming() {
        guard officialFileURL != nil, let instance = teamTalkInstance,
              TT_GetFlags(instance) & CLIENT_STREAM_AUDIO.rawValue == 0 else { return }
        officialFileEnded(finished: true)
    }

    /// A file the library streamed has ended: start it again when looping
    /// (and it played to its end), otherwise remove it.
    private func officialFileEnded(finished: Bool) {
        guard let url = officialFileURL, let instance = teamTalkInstance else { return }
        if finished && loopsAudioFiles {
            TT_StopStreamingMediaFileToChannel(instance)
            var playback = MediaFilePlayback()
            playback.uOffsetMSec = 0
            playback.bPaused = FALSE
            playback.audioPreprocessor = officialFilePreprocessor()
            var video = VideoCodec()
            video.nCodec = NO_CODEC
            if TT_StartStreamingMediaFileToChannelEx(instance, url.path, &playback, &video) == TRUE {
                officialMediaFilePaused = false
                officialElapsedMSec = 0
                officialStartedAt = Date()
                updateBottomToolbar()
                return
            }
            mediaFileStreamingLogger.error("Could not start the audio file again for looping.")
        }
        removeOfficialFile()
        updateBottomToolbar()
    }

    private func setVoiceTx(_ on: Bool) {
        (viewControllers?[CHANNELTAB] as? ChannelListViewController)?.enableVoiceTx(on, playToggleSound: false)
    }

    /// Starts sending a mix of AudioNet (`tap`) and a file. Returns an
    /// error in words, or nil.
    private func startMix(file: URL?, offsetMSec: UInt32, filePaused: Bool, tap: AudioTap?) -> String? {
        guard let instance = teamTalkInstance else { return NSLocalizedString("Not connected.", comment: "main-tab") }
        let format = audioBlockFormatForCurrentChannel()
        let mixer = ChannelMixer(sampleRate: Int(format.sampleRate), channels: Int(format.channels))
        if let file {
            do {
                let source = try MixerFileSource(url: file, sampleRate: format.sampleRate, channels: Int(format.channels),
                                                 offsetMSec: offsetMSec)
                mixer.setFile(source, paused: filePaused)
            } catch {
                return error.localizedDescription
            }
        }
        mixer.setAudioNet(tap)
        mixer.setGains(filePercent: streamVolumePercent(PREF_STREAM_FILE_VOLUME),
                       audioNetPercent: streamVolumePercent(PREF_STREAM_AUDIONET_VOLUME))
        mixer.setLoop(loopsAudioFiles)
        mixer.fileFinished = { [weak self] url in self?.mixedFileFinished(url) }
        self.mixer = mixer
        mixSinkPaused = false

        if hasMediaFileRight {
            let live = LiveMediaSources.add(mixer)
            var playback = MediaFilePlayback()
            playback.uOffsetMSec = 0
            playback.bPaused = FALSE
            playback.audioPreprocessor.nPreprocessor = NO_AUDIOPREPROCESSOR
            var video = VideoCodec()
            video.nCodec = NO_CODEC
            if TT_StartStreamingMediaFileToChannelEx(instance, live.path, &playback, &video) == TRUE {
                mixerLiveID = live.id
                mixerLivePath = live.path
                updateMixSink()
                updateBottomToolbar()
                return nil
            }
            LiveMediaSources.remove(live.id)
            mediaFileStreamingLogger.error("The live media stream could not start; sending the mix as voice.")
        }

        // As voice: the microphone is off meanwhile.
        mediaFileWasVoiceTransmitting = isTransmitting(instance, stream: STREAMTYPE_VOICE)
        configureOwnVoiceSubscriptionForMediaFileStreaming()
        if mediaFileWasVoiceTransmitting {
            setVoiceTx(false)
        }
        let streamerID = UUID()
        let streamer = AudioBlockMediaStreamer(id: streamerID, ttInst: instance,
                                               live: { frames in mixer.pull(frames: frames) },
                                               format: format) { [weak self] result in
            self?.audioBlockMediaFileStreamingFinished(result, streamerID: streamerID)
        }
        audioBlockMediaStreamer = streamer
        audioBlockMediaStreamerID = streamerID
        streamer.start()
        updateMixSink()
        updateBottomToolbar()
        return nil
    }

    /// The mix pauses only when it is a paused file alone.
    private func updateMixSink() {
        guard let mixer else { return }
        let paused = mixer.hasAudioNet == false && mixer.hasFile && mixer.isFilePaused
        guard paused != mixSinkPaused else { return }
        mixSinkPaused = paused
        if mixerLiveID != nil {
            _ = updateMediaStream(paused: paused)
        }
        else if let streamer = audioBlockMediaStreamer, let instance = teamTalkInstance {
            if paused {
                streamer.pause()
                restoreMediaFileAudioState(clearSavedState: false)
            } else {
                configureOwnVoiceSubscriptionForMediaFileStreaming()
                if isTransmitting(instance, stream: STREAMTYPE_VOICE) {
                    setVoiceTx(false)
                }
                streamer.resume()
            }
        }
    }

    private func stopMix() {
        guard let mixer else { return }
        self.mixer = nil
        if let id = mixerLiveID {
            mixerLiveID = nil
            mixerLivePath = ""
            TT_StopStreamingMediaFileToChannel(teamTalkInstance)
            LiveMediaSources.remove(id)
        }
        if let streamer = audioBlockMediaStreamer {
            audioBlockMediaStreamer = nil
            audioBlockMediaStreamerID = nil
            streamer.stop()
            restoreMediaFileAudioState(clearSavedState: true)
        }
        mixer.setAudioNet(nil)
        if let url = mixer.fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        mixSinkPaused = false
        updateBottomToolbar()
    }

    private func mixedFileFinished(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        if let mixer, mixer.hasAudioNet == false {
            stopMix()
        }
        updateBottomToolbar()
    }

    private func pauseMediaFileStreaming() {
        if officialFileURL != nil {
            setOfficialMediaFilePaused(true)
            return
        }
        guard let mixer, mixer.hasFile else { return }
        mixer.setFilePaused(true)
        updateMixSink()
        updateBottomToolbar()
    }

    private func resumeMediaFileStreaming() {
        if officialFileURL != nil {
            setOfficialMediaFilePaused(false)
            return
        }
        guard let mixer, mixer.hasFile else { return }
        mixer.setFilePaused(false)
        updateMixSink()
        updateBottomToolbar()
    }

    private func stopMediaFileStreaming() {
        if officialFileURL != nil {
            guard TT_StopStreamingMediaFileToChannel(teamTalkInstance) == TRUE else {
                showMediaFileStreamingError(NSLocalizedString("Could not stop audio file streaming.", comment: "main-tab"))
                return
            }
            removeOfficialFile()
            updateBottomToolbar()
            return
        }
        guard let mixer, let url = mixer.fileURL else { return }
        mixer.setFile(nil)
        try? FileManager.default.removeItem(at: url)
        if mixer.hasAudioNet == false {
            stopMix()
        } else {
            updateMixSink()
        }
        updateBottomToolbar()
    }

    private func audioBlockMediaFileStreamingFinished(_ result: Result<Void, Error>, streamerID: UUID) {
        guard audioBlockMediaStreamerID == streamerID else { return }
        if mixer?.hasAudioNet == true {
            AudioNetBridge.shared.stopSending()
        }
        stopMix()
        if case .failure(let error) = result {
            showMediaFileStreamingError(error.localizedDescription)
        }
    }

    // MARK: AudioNet

    @objc private func showAudioNet() {
        let controller = AudioNetViewController(style: .insetGrouped)
        controller.canSend = { [weak self] in self?.canSendAudioNet() == true }
        controller.sendsAsVoice = { [weak self] in self?.hasMediaFileRight == false }
        controller.send = { [weak self] device, source in self?.startAudioNetStreaming(device: device, source: source) }
        controller.stop = { [weak self] in self?.stopAudioNetStreaming() }
        controller.volume = { streamVolumePercent(PREF_STREAM_AUDIONET_VOLUME) }
        controller.setVolume = { [weak self] in self?.setAudioNetStreamVolume($0) }
        present(UINavigationController(rootViewController: controller), animated: true)
    }

    /// Sends a device's AudioNet sound into the channel, mixed with an audio
    /// file if one is streaming. With the right to stream media files it
    /// goes out as the media file stream and the microphone stays on;
    /// otherwise as voice. While sending, choosing another sound swaps it.
    private func startAudioNetStreaming(device: Device, source: Source) -> String? {
        guard let instance = teamTalkInstance, canSendAudioNet() else {
            return NSLocalizedString("You do not have permission to transmit voice.", comment: "main-tab")
        }
        let format = audioBlockFormatForCurrentChannel()
        let sampleRate = mixer.map { $0.sampleRate } ?? Int(format.sampleRate)
        let channels = mixer.map { $0.channels } ?? Int(format.channels)
        let tap: AudioTap
        do {
            tap = try AudioNetBridge.shared.startSending(device: device, source: source,
                                                         sampleRate: UInt32(sampleRate), channels: UInt32(channels))
        } catch {
            return AudioNetBridge.message(error)
        }
        if let mixer {
            mixer.setAudioNet(tap)
            updateMixSink()
            updateBottomToolbar()
            return nil
        }
        // A file the library is streaming continues in the mix, from where
        // it is.
        var file: URL?
        var offset: UInt32 = 0
        var paused = false
        if let url = officialFileURL {
            file = url
            offset = officialElapsedMSec
            paused = officialMediaFilePaused
            officialFileURL = nil
            officialMediaFilePaused = false
            TT_StopStreamingMediaFileToChannel(instance)
        }
        if let error = startMix(file: file, offsetMSec: offset, filePaused: paused, tap: tap) {
            AudioNetBridge.shared.stopSending()
            if let file {
                try? FileManager.default.removeItem(at: file)
            }
            return error
        }
        mediaFileStreamingLogger.notice("Started sending AudioNet sound to the channel.")
        return nil
    }

    private func stopAudioNetStreaming() {
        AudioNetBridge.shared.stopSending()
        guard let mixer, mixer.hasAudioNet else { return }
        mixer.setAudioNet(nil)
        if mixer.hasFile {
            updateMixSink()
        } else {
            stopMix()
        }
        updateBottomToolbar()
    }

    /// The AudioNet stream ended (the device stopped sharing or went
    /// offline): stop sending it to the channel.
    @objc private func audioNetStreamEnded(_ notification: Notification) {
        guard mixer?.hasAudioNet == true else { return }
        stopAudioNetStreaming()
        let reason = notification.userInfo?["reason"] as? String ?? ""
        let text = reason.isEmpty
            ? NSLocalizedString("AudioNet stopped sending to the channel.", comment: "audionet")
            : String(format: NSLocalizedString("AudioNet stopped sending to the channel: %@", comment: "audionet"), reason)
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    // MARK: Others' media files and the audio session

    /// The volume of others' media files relative to voice, from Settings,
    /// as BearWare's clients do: applied to each user who joins once set.
    func applyAudioFileVolume(to userid: INT32) {
        guard let percent = preferredAudioFileVolumePercent(), let instance = teamTalkInstance else { return }
        TT_SetUserVolume(instance, userid, STREAMTYPE_MEDIAFILE_AUDIO, INT32(refVolume(percent)))
        TT_PumpMessage(instance, CLIENTEVENT_USER_STATECHANGE, userid)
    }

    func applyAudioFileVolumeToEveryone() {
        guard let instance = teamTalkInstance,
              let channelsTab = viewControllers?[CHANNELTAB] as? ChannelListViewController else { return }
        let me = TT_GetMyUserID(instance)
        for userid in channelsTab.users.keys where userid != me {
            applyAudioFileVolume(to: userid)
        }
    }

    /// Sets the sound devices up again, keeping the microphone as it is.
    /// With several servers connected one of them does it for all.
    func restoreSoundDevices() {
        guard let instance = teamTalkInstance, ConnectedServerManager.shared.sessions.first === self else { return }
        withTeamTalkInstance(instance) {
            if canReconfigureInitializedSoundDevices() {
                setupSoundDevices(enableInput: isTransmitting(instance, stream: STREAMTYPE_VOICE))
            }
        }
    }

    // MARK: Streaming helpers

    private func audioBlockFormatForCurrentChannel() -> MediaFileAudioBlockFormat {
        guard let channelsTab = viewControllers?[CHANNELTAB] as? ChannelListViewController else {
            return MediaFileAudioBlockFormat(sampleRate: 48000, channels: 1, txIntervalMSec: 40)
        }

        var codec = channelsTab.mychannel.audiocodec
        switch codec.nCodec {
        case OPUS_CODEC:
            let opus = getOpusCodec(&codec).pointee
            return MediaFileAudioBlockFormat(sampleRate: Double(opus.nSampleRate),
                                             channels: AVAudioChannelCount(max(1, min(2, Int(opus.nChannels)))),
                                             txIntervalMSec: Int(max(20, opus.nTxIntervalMSec)))
        case SPEEX_CODEC:
            let speex = getSpeexCodec(&codec).pointee
            return MediaFileAudioBlockFormat(sampleRate: sampleRateForSpeexBandmode(speex.nBandmode),
                                             channels: 1,
                                             txIntervalMSec: Int(max(20, speex.nTxIntervalMSec)))
        case SPEEX_VBR_CODEC:
            let speex = getSpeexVBRCodec(&codec).pointee
            return MediaFileAudioBlockFormat(sampleRate: sampleRateForSpeexBandmode(speex.nBandmode),
                                             channels: 1,
                                             txIntervalMSec: Int(max(20, speex.nTxIntervalMSec)))
        default:
            return MediaFileAudioBlockFormat(sampleRate: 48000, channels: 1, txIntervalMSec: 40)
        }
    }

    private func sampleRateForSpeexBandmode(_ bandmode: INT32) -> Double {
        switch bandmode {
        case 0:
            return 8000
        case 2:
            return 32000
        default:
            return 16000
        }
    }

    /// While recording, this user's voice is not sent back by the server
    /// (it would be recorded twice: as sent and as it comes back).
    private func avoidRecordingOwnEcho() {
        guard recorder.wanted, mediaFileEnabledOwnVoiceSubscription, mediaFileOwnUserID > 0 else { return }
        TT_DoUnsubscribe(teamTalkInstance, mediaFileOwnUserID, SUBSCRIBE_VOICE.rawValue)
        mediaFileEnabledOwnVoiceSubscription = false
    }


    private func configureOwnVoiceSubscriptionForMediaFileStreaming() {
        mediaFileOwnUserID = TT_GetMyUserID(teamTalkInstance)
        mediaFileEnabledOwnVoiceSubscription = false
        // Recording: hearing the file come back would record it twice.
        guard recorder.wanted == false, mediaFileOwnUserID > 0 else { return }
        var user = User()
        guard TT_GetUser(teamTalkInstance, mediaFileOwnUserID, &user) == TRUE else { return }
        if (user.uLocalSubscriptions & SUBSCRIBE_VOICE.rawValue) == 0 {
            TT_DoSubscribe(teamTalkInstance, mediaFileOwnUserID, SUBSCRIBE_VOICE.rawValue)
            mediaFileEnabledOwnVoiceSubscription = true
        }
    }

    private func restoreMediaFileAudioState(clearSavedState: Bool) {
        if mediaFileEnabledOwnVoiceSubscription && mediaFileOwnUserID > 0 {
            TT_DoUnsubscribe(teamTalkInstance, mediaFileOwnUserID, SUBSCRIBE_VOICE.rawValue)
        }
        mediaFileEnabledOwnVoiceSubscription = false
        if clearSavedState {
            mediaFileOwnUserID = 0
        }
        let shouldRestoreVoiceTransmission = mediaFileWasVoiceTransmitting
        if clearSavedState {
            mediaFileWasVoiceTransmitting = false
        }
        if shouldRestoreVoiceTransmission {
            restoreVoiceTransmissionAfterMediaFileStreaming(onlyWhilePaused: clearSavedState == false)
        }
    }

    private func restoreVoiceTransmissionAfterMediaFileStreaming(attempt: Int = 0, onlyWhilePaused: Bool = false) {
        guard let instance = teamTalkInstance else { return }
        if onlyWhilePaused && isVoiceSinkSending() {
            return
        }
        setVoiceTx(true)
        if isTransmitting(instance, stream: STREAMTYPE_VOICE) || attempt >= 5 {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.restoreVoiceTransmissionAfterMediaFileStreaming(attempt: attempt + 1, onlyWhilePaused: onlyWhilePaused)
        }
    }

    private func mediaFileVideoCodec(for videoFormat: VideoFormat) -> VideoCodec {
        var codec = VideoCodec()
        codec.nCodec = WEBM_VP8_CODEC
        let width = max(Int(videoFormat.nWidth), 1)
        let height = max(Int(videoFormat.nHeight), 1)
        let fps = videoFormat.nFPS_Denominator > 0 ? max(Int(videoFormat.nFPS_Numerator / videoFormat.nFPS_Denominator), 1) : 15
        codec.webm_vp8.nRcTargetBitrate = INT32(max(256, min(2048, (width * height * fps) / 9000)))
        codec.webm_vp8.nEncodeDeadline = UINT32(WEBM_VPX_DL_REALTIME)
        return codec
    }

    private func temporaryMediaURL(for sourceURL: URL) throws -> URL {
        let access = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if access {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        return try copyMediaFileToTemporaryLocation(from: sourceURL, fileName: sourceURL.lastPathComponent)
    }

    private func temporaryMediaURL(forClipboardAudioData data: Data, fileName: String) throws -> URL {
        let destinationURL = uniqueTemporaryURL(fileName: fileName, fallbackName: "Clipboard Audio")
        try data.write(to: destinationURL, options: .atomic)
        mediaFileStreamingLogger.info("Copied clipboard audio for streaming: name=\(destinationURL.lastPathComponent, privacy: .public), bytes=\(data.count), tempPath=\(destinationURL.path, privacy: .private)")
        return destinationURL
    }

    private func copyMediaFileToTemporaryLocation(from sourceURL: URL, fileName: String) throws -> URL {
        let destinationURL = uniqueTemporaryURL(fileName: fileName, fallbackName: "TeamTalk Audio")
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: destinationURL.path),
           let fileSize = attributes[.size] as? NSNumber {
            mediaFileStreamingLogger.info("Copied audio file for streaming: name=\(destinationURL.lastPathComponent, privacy: .public), bytes=\(fileSize.int64Value), tempPath=\(destinationURL.path, privacy: .private)")
        }
        return destinationURL
    }

    private func uniqueTemporaryURL(fileName: String, fallbackName: String) -> URL {
        let sanitizedName = fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackName : fileName
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent(sanitizedName)
        var candidateURL = baseURL
        var index = 1
        while FileManager.default.fileExists(atPath: candidateURL.path) {
            let name = baseURL.deletingPathExtension().lastPathComponent
            let ext = baseURL.pathExtension
            let indexedName = ext.isEmpty ? "\(name)-\(index)" : "\(name)-\(index).\(ext)"
            candidateURL = baseURL.deletingLastPathComponent().appendingPathComponent(indexedName)
            index += 1
        }
        return candidateURL
    }

    private func showMediaFileStreamingError(_ message: String) {
        let alert = UIAlertController(title: NSLocalizedString("Audio File", comment: "main-tab"),
                                      message: message,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "message dialog"), style: .default))
        present(alert, animated: true)
    }

    @objc func showSettings() {
        guard let settingsViewController = settingsViewController else { return }
        if navigationController?.topViewController === settingsViewController {
            return
        }
        if let existingIndex = navigationController?.viewControllers.firstIndex(where: { $0 === settingsViewController }) {
            navigationController?.popToViewController(navigationController!.viewControllers[existingIndex], animated: true)
            return
        }
        navigationController?.pushViewController(settingsViewController, animated: true)
    }

    @objc func showChannelMessages() {
        guard let channelMessagesViewController = channelMessagesViewController else { return }
        if navigationController?.topViewController === channelMessagesViewController {
            return
        }
        channelMessagesViewController.userid = 0
        channelMessagesViewController.conversationTitle = NSLocalizedString("Messages", comment: "main-tab")
        navigationController?.pushViewController(channelMessagesViewController, animated: true)
    }

    @objc func showChannelFiles() {
        guard let channelsTab = viewControllers?[CHANNELTAB] as? ChannelListViewController,
              channelsTab.isInChannel() else { return }
        let serverIdentifier = "\(server.ipaddr.lowercased()):\(server.tcpport)"
        let filesViewController = ChannelFilesViewController(channelID: TT_GetMyChannelID(ttInst),
                                                             serverIdentifier: serverIdentifier)
        navigationController?.pushViewController(filesViewController, animated: true)
    }

    @objc func createNewChannel() {
        performSegue(withIdentifier: "New Channel", sender: self)
    }

    @objc func showBroadcastMessageAlert() {
        guard canBroadcastMessages else { return }

        let alert = UIAlertController(title: NSLocalizedString("Broadcast Message", comment: "main-tab"),
                                      message: nil,
                                      preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = NSLocalizedString("Message", comment: "main-tab")
        }
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "message dialog"), style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: NSLocalizedString("Send", comment: "message dialog"), style: .default) { [weak alert] _ in
            let content = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard content.isEmpty == false else {
                return
            }

            var message = TextMessage()
            message.nFromUserID = TT_GetMyUserID(ttInst)
            message.nMsgType = MSGTYPE_BROADCAST
            _ = TeamTalk_NG.sendTextMessage(msg: message, content: content)
        })
        present(alert, animated: true, completion: nil)
    }

    @objc func showManageServerActions() {
        guard isAdminUser else { return }

        let alert = UIAlertController(title: NSLocalizedString("Manage Server", comment: "main-tab"),
                                      message: nil,
                                      preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Accounts", comment: "main-tab"), style: .default) { [weak self] _ in
            self?.showAdminAccounts()
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Bans", comment: "main-tab"), style: .default) { [weak self] _ in
            self?.showAdminBans()
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Edit Server Properties", comment: "main-tab"), style: .default) { [weak self] _ in
            self?.showServerProperties()
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "Dialog message"), style: .cancel))
        present(alert, animated: true)
    }

    @available(iOS 14.0, *)
    private func manageServerMenu() -> UIMenu {
        UIMenu(title: NSLocalizedString("Manage Server", comment: "main-tab"), children: [
            UIAction(title: NSLocalizedString("Accounts", comment: "main-tab"), image: UIImage(systemName: "person.2")) { [weak self] _ in
                self?.showAdminAccounts()
            },
            UIAction(title: NSLocalizedString("Bans", comment: "main-tab"), image: UIImage(systemName: "hand.raised")) { [weak self] _ in
                self?.showAdminBans()
            },
            UIAction(title: NSLocalizedString("Edit Server Properties", comment: "main-tab"), image: UIImage(systemName: "slider.horizontal.3")) { [weak self] _ in
                self?.showServerProperties()
            }
        ])
    }

    private func showAdminAccounts() {
        showAdminTools(initialSection: 0)
    }

    private func showAdminBans() {
        showAdminTools(initialSection: 1)
    }

    /// Your own account on this server, view only.
    @objc private func showMyInformation() {
        guard let instance = teamTalkInstance else { return }
        var account = UserAccount()
        guard TT_GetMyUserAccount(instance, &account) == TRUE else { return }
        navigationController?.pushViewController(MyAccountViewController(server: server, account: account), animated: true)
    }

    private func showAdminTools(initialSection: Int) {
        guard isAdminUser else { return }

        if #available(iOS 13.0, *) {
            let adminTools = AdminToolsViewController(server: server, initialSection: initialSection)
            navigationController?.pushViewController(adminTools, animated: true)
        } else {
            let alert = UIAlertController(title: NSLocalizedString("Manage Server", comment: "main-tab"), message: NSLocalizedString("Server management requires iOS 13 or later.", comment: "main-tab"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "message dialog"), style: .default, handler: nil))
            present(alert, animated: true, completion: nil)
        }
    }

    private func showServerProperties() {
        guard isAdminUser else { return }

        if #available(iOS 13.0, *) {
            let serverProperties = ServerPropertiesViewController()
            navigationController?.pushViewController(serverProperties, animated: true)
        } else {
            let alert = UIAlertController(title: NSLocalizedString("Manage Server", comment: "main-tab"), message: NSLocalizedString("Server management requires iOS 13 or later.", comment: "main-tab"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "message dialog"), style: .default, handler: nil))
            present(alert, animated: true, completion: nil)
        }
    }

    deinit {
        closeConnectionResources()
        print("Destroyed main view controller")
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ConnectedServerManager.shared.activate(self)
        navigationController?.setToolbarHidden(false, animated: animated)
        updateBottomToolbar()
        // Headset TX controls are enabled only after a server connection succeeds.
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        if self.isMovingFromParent && !isMinimizing {
            closeConnectionResources()
        }
        isMinimizing = false
        
        UIApplication.shared.endReceivingRemoteControlEvents()
        navigationController?.setToolbarHidden(true, animated: animated)
    }
    
    override func remoteControlReceived(with event: UIEvent?) { // *
        let rc = event!.subtype
        switch rc {
        case .remoteControlPause : fallthrough
        case .remoteControlTogglePlayPause:
            let channelsTab = viewControllers?[CHANNELTAB] as! ChannelListViewController
            channelsTab.enableVoiceTx(false)
        case .remoteControlPreviousTrack:
            fallthrough
        case .remoteControlNextTrack:
            let channelsTab = viewControllers?[CHANNELTAB] as! ChannelListViewController
            channelsTab.enableVoiceTx(true)
        
        default:
            break
        }
    }
    
    func setTeamTalkServer(_ server: Server) {
        self.server = server
    }

    func applyConnectedAudioPreferences() {
        let defaults = UserDefaults.standard
        let masterVolume = defaults.object(forKey: PREF_MASTER_VOLUME) == nil ? DEFAULT_AUDIO_LEVEL_PERCENT : defaults.integer(forKey: PREF_MASTER_VOLUME)
        TT_SetSoundOutputVolume(ttInst, INT32(refVolume(Double(masterVolume))))
        if defaults.object(forKey: PREF_MASTER_VOLUME) == nil {
            defaults.set(masterVolume, forKey: PREF_MASTER_VOLUME)
        }

        let microphoneGain = defaults.object(forKey: PREF_MICROPHONE_GAIN) == nil ? DEFAULT_AUDIO_LEVEL_PERCENT : defaults.integer(forKey: PREF_MICROPHONE_GAIN)
        TT_SetSoundInputGainLevel(ttInst, INT32(refVolume(Double(microphoneGain))))
        if defaults.object(forKey: PREF_MICROPHONE_GAIN) == nil {
            defaults.set(microphoneGain, forKey: PREF_MICROPHONE_GAIN)
        }

    }

    func startAudioRouteMonitoring() {
        let center = NotificationCenter.default
        center.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
        center.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        center.addObserver(self, selector: #selector(MainTabBarController.audioRouteChange(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(MainTabBarController.audioInterruption(_:)), name: AVAudioSession.interruptionNotification, object: nil)
    }

    func stopAudioRouteMonitoring() {
        let center = NotificationCenter.default
        center.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
        center.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
    }

    func resetAudioStateForDisconnect() {
        guard let instance = teamTalkInstance else { return }
        withTeamTalkInstance(instance) {
            if let channelsTab = viewControllers?[CHANNELTAB] as? ChannelListViewController {
                channelsTab.enableVoiceTx(false, playToggleSound: false)
            }
            TT_CloseSoundInputDevice(instance)
            TT_CloseSoundOutputDevice(instance)
            if ConnectedServerManager.shared.sessions.count <= 1 {
                resetSoundDevicesToLaunchState()
            }
        }
    }
    
    func startReconnectTimer() {
        if isClosingConnection {
            return
        }
        reconnecttimer = Timer.scheduledTimer(timeInterval: 5.0, target: self, selector: #selector(MainTabBarController.connectToServer), userInfo: nil, repeats: false)
    }
    
    @objc func connectToServer() {
        if isClosingConnection {
            return
        }
        let previouslyActiveInstance = ConnectedServerManager.shared.activeSession?.teamTalkInstance
        defer { ttInst = previouslyActiveInstance ?? teamTalkInstance }
        ttInst = teamTalkInstance
        ensureTeamTalkInitialized()
        if setupEncryption(ttInst!, server: server) == false {
            let alert = UIAlertController(title: NSLocalizedString("Connect to Server", comment: "connect to a server"),
                                          message: NSLocalizedString("Failed to setup encryption", comment: "connect to a server"),
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                self?.disconnectAndDismissServerSheet()
            })
            self.present(alert, animated: true, completion: nil)
        }
        else {
            if TT_Connect(ttInst, server.ipaddr, INT32(server.tcpport), INT32(server.udpport), 0, 0, server.encrypted ? TRUE : FALSE) == FALSE {
                resetSoundDevicesToLaunchState()
                TT_Disconnect(ttInst)
                startReconnectTimer()
            }
        }
    }
        
    // run the TeamTalk event loop
    @objc func timerEvent() {
        runTeamTalkEventHandler(instance: teamTalkInstance)
        checkOfficialFileStillStreaming()
    }
    
    @objc func audioRouteChange(_ notification: Notification) {
        guard let instance = teamTalkInstance else { return }
        withTeamTalkInstance(instance) {
//        let session = AVAudioSession.sharedInstance()
//        print("Audio route: " + session.currentRoute.debugDescription)
        if let reason = notification.userInfo![AVAudioSessionRouteChangeReasonKey] {
            switch reason as! UInt {
            case AVAudioSession.RouteChangeReason.unknown.rawValue :
                print("AudioRouteChange Unknown")
            case AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue :
                print("AudioRouteChange NewDeviceAvailable")
            case AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue:
                print("AudioRouteChange OldDeviceUnavailable")
                if canReconfigureInitializedSoundDevices() {
                    setupSoundDevices(enableInput: isTransmitting(ttInst!, stream: STREAMTYPE_VOICE))
                }
            case AVAudioSession.RouteChangeReason.categoryChange.rawValue:
                let session = AVAudioSession.sharedInstance()
                print("AudioRouteChange CategoryChange, new category: \(session.category), new mode: \(session.mode)")
                // Something else in the app (Apple's player in QuickLook)
                // changed the shared audio session. Left like that, other
                // apps' audio stops TeamTalk instead of mixing with it.
                if session.category != .playAndRecord || session.categoryOptions.contains(.mixWithOthers) == false {
                    DispatchQueue.main.async { [weak self] in self?.restoreSoundDevices() }
                }
            case AVAudioSession.RouteChangeReason.override.rawValue :
                let session = AVAudioSession.sharedInstance()
                print("AudioRouteChange Override, new route: " + session.currentRoute.description)
            case AVAudioSession.RouteChangeReason.routeConfigurationChange.rawValue :
                print("AudioRouteChange RouteConfigurationChange")
            default :
                break
            }
        }
        }
    }
    
    @objc func audioInterruption(_ notification: Notification) {
        guard let instance = teamTalkInstance else { return }
        withTeamTalkInstance(instance) {
        if let reason = notification.userInfo![AVAudioSessionInterruptionTypeKey] {
            switch reason as! UInt {
            case AVAudioSession.InterruptionType.began.rawValue :
                print("Audio interruption began")
            case AVAudioSession.InterruptionType.ended.rawValue :
                // Set up again whenever an interruption ends, also when iOS
                // does not say playback should resume.
                DispatchQueue.main.async { [weak self] in self?.restoreSoundDevices() }
            default :
                break
            }
        }
        
        if let reason = notification.userInfo![AVAudioSessionInterruptionOptionKey] {
            switch reason as! UInt {
            case AVAudioSession.InterruptionOptions.shouldResume.rawValue :
                if canReconfigureInitializedSoundDevices() {
                    setupSoundDevices(enableInput: isTransmitting(ttInst!, stream: STREAMTYPE_VOICE))
                }
            default :
                break
            }
        }
        }
    }
    
    func handleTTMessage(_ m: TTMessage) {
        if isClosingConnection {
            return
        }

        var m = m
        
        switch(m.nClientEvent) {
            
        case CLIENTEVENT_CON_SUCCESS :
            if #available(iOS 14.0, *) {
                os_log("Connected to \(self.server.ipaddr)")
            }

            login()
            
        case CLIENTEVENT_CON_FAILED :
            
            resetSoundDevicesToLaunchState()
            TT_Disconnect(ttInst)
            startReconnectTimer()
            
            if #available(iOS 14.0, *) {
                os_log("Connect to \(self.server.ipaddr) failed")
            }
            
        case CLIENTEVENT_CON_LOST :
            
            if #available(iOS 14.0, *) {
                os_log("Connection to \(self.server.ipaddr) lost")
            }

            recorder.connectionLost()
            resetSoundDevicesToLaunchState()
            TT_Disconnect(ttInst)
            playSound(.srv_LOST)
            
            let defaults = UserDefaults.standard
            
            if defaults.object(forKey: PREF_TTSEVENT_CONLOST) == nil || defaults.bool(forKey: PREF_TTSEVENT_CONLOST) {
                newUtterance(NSLocalizedString("Connection lost", comment: "tts event"))
            }

            startReconnectTimer()
            
        case CLIENTEVENT_CMD_PROCESSING :
            if getTTBOOL(&m) != 0 {
                let channelsTab = viewControllers?[CHANNELTAB] as? ChannelListViewController
                if let command = channelsTab?.activeCommands[m.nSource] {
                    switch command {
                    case .loginCmd, .joinCmd:
                        suppressFileUpdateAnnouncements = true
                    default:
                        suppressFileUpdateAnnouncements = false
                    }
                } else {
                    suppressFileUpdateAnnouncements = false
                }
            }
            else {
                suppressFileUpdateAnnouncements = false
                commandComplete(m.nSource)
            }
            
        case CLIENTEVENT_CMD_SERVER_UPDATE:
            var properties = getServerProperties(&m).pointee
            updatePublicServerName(String(cString: getServerPropertiesString(SERVERNAME, &properties)))

        case CLIENTEVENT_CMD_MYSELF_LOGGEDIN :
            var account = getUserAccount(&m).pointee
            isAdminUser = (account.uUserType & USERTYPE_ADMIN.rawValue) != 0
            canBroadcastMessages = isAdminUser || (account.uUserRights & USERRIGHT_TEXTMESSAGE_BROADCAST.rawValue) != 0
            configureBottomToolbar()
            // A monitor using this account steps aside while connected.
            MonitorCenter.shared.connectedLive(to: server)
            allowSoundDevicesForConnectedServer()
            applyConnectedAudioPreferences()
            startAudioRouteMonitoring()
            setupSoundDevices(enableInput: false)

            let initchan = String(cString: getUserAccountString(INITCHANNEL, &account))
            if initchan.isEmpty == false {
                server.channel = initchan
            }

        case CLIENTEVENT_CMD_MYSELF_KICKED :
            if m.nSource == 0 {
                disconnectAndDismissServerSheet()
            }

        case CLIENTEVENT_CMD_ERROR :
            if m.nSource == cmdid {
                let errmsg = getClientErrorMsg(m.clienterrormsg, strprop: ERRMESSAGE)
                if #available(iOS 8.0, *) {
                    let alert = UIAlertController(title: NSLocalizedString("Error", comment: "message dialog"), message: errmsg, preferredStyle: UIAlertController.Style.alert)
                    alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "message dialog"), style: UIAlertAction.Style.default) { [weak self] _ in
                        self?.disconnectAndDismissServerSheet()
                    })
                    self.present(alert, animated: true, completion: nil)
                } else {
                    // Fallback on earlier versions
                }
            }
        
        case CLIENTEVENT_CMD_USER_LOGGEDIN :
            let subs = getDefaultSubscriptions()
            let user = getUser(&m).pointee
            if TT_GetMyUserID(ttInst) != user.nUserID && user.uLocalSubscriptions != subs {
                TT_DoUnsubscribe(ttInst, user.nUserID, user.uLocalSubscriptions ^ subs)
            }
            
            // restore from user cache
            syncFromUserCache(user: user)

        case CLIENTEVENT_CMD_USER_LOGGEDOUT :
            // sync user settings to cache
            syncToUserCache(user: getUser(&m).pointee)

        case CLIENTEVENT_CMD_USER_JOINED :
            let user = getUser(&m).pointee
            if user.nUserID == TT_GetMyUserID(teamTalkInstance) {
                recorder.joinedChannel(user.nChannelID)
            } else {
                recorder.userJoined(user)
                applyAudioFileVolume(to: user.nUserID)
            }
            
            // restore from user cache
            if (TT_GetMyUserRights(ttInst) & USERRIGHT_VIEW_ALL_USERS.rawValue) != USERRIGHT_VIEW_ALL_USERS.rawValue {
                syncFromUserCache(user: user)
            }

        case CLIENTEVENT_CMD_USER_LEFT :
            let leaving = getUser(&m).pointee
            if leaving.nUserID == TT_GetMyUserID(teamTalkInstance) {
                recorder.leftChannel()
            } else {
                recorder.userLeft(leaving)
            }

            // sync user settings from cache
            if (TT_GetMyUserRights(ttInst) & USERRIGHT_VIEW_ALL_USERS.rawValue) != USERRIGHT_VIEW_ALL_USERS.rawValue {
                syncToUserCache(user: getUser(&m).pointee)
            }
            
        case CLIENTEVENT_CMD_USER_TEXTMSG :
            let textMessage = getTextMessage(&m).pointee

            // TeamTalk splits long text messages into multiple events. Only the
            // final event represents the completed logical message, so notify
            // once instead of once for every chunk.
            guard textMessage.bMore == FALSE else { break }

            switch textMessage.nMsgType {
            case MSGTYPE_CHANNEL :
                playSound(.chan_MSG)
            case MSGTYPE_USER :
                playSound(.user_MSG)
            case MSGTYPE_BROADCAST :
                playSound(.broadcast_MSG)
            default : break
            }
        case CLIENTEVENT_CMD_FILE_NEW:
            if !suppressFileUpdateAnnouncements {
                announceChannelFileUpdate(m.remotefile, added: true)
            }

        case CLIENTEVENT_CMD_FILE_REMOVE:
            if !suppressFileUpdateAnnouncements {
                announceChannelFileUpdate(m.remotefile, added: false)
            }

        case CLIENTEVENT_CMD_CHANNEL_UPDATE :
            recorder.channelUpdated(getChannel(&m).pointee)

        case CLIENTEVENT_USER_RECORD_MEDIAFILE :
            recorder.recordingEvent(userID: m.nSource, info: m.mediafileinfo)

        case CLIENTEVENT_STREAM_MEDIAFILE :
            mediaFileStreamingLogger.info("Media file stream event: status=\(m.mediafileinfo.nStatus.rawValue), elapsedMSec=\(m.mediafileinfo.uElapsedMSec), durationMSec=\(m.mediafileinfo.uDurationMSec)")
            mediaFileStreamEvent(m.mediafileinfo)
            updateMediaFileToolbarButton()

        default :
            break
        }
    }
    
    func commandComplete(_ active_cmdid : INT32) {
        
        let channelsTab = viewControllers?[CHANNELTAB] as! ChannelListViewController
        let cmd = channelsTab.activeCommands[active_cmdid]
        
        if cmd == nil {
            return
        }
        
        switch cmd! {
            
        case .loginCmd :
            //setup initial channel
            if server.channel.isEmpty == false {
                
                var path = StringWrap();
                toTTString(server.channel, dst: &path.buf)

                var tokens = server.channel.components(separatedBy: "/")
                
                let chanid = TT_GetChannelIDFromPath(ttInst, fromStringWrap(&path))
                if chanid > 0 {
                    //join existing channel
                    channelsTab.rejoinchannel.nChannelID = chanid
                    toTTString(server.chanpasswd, dst: &channelsTab.rejoinchannel.szPassword)
                }
                else if tokens.count > 0 {
                    // extract path of parent channel
                    let channame = tokens.removeLast()
                    var chanpath = ""
                    for c in tokens {
                        chanpath += "/" + c
                    }
                    
                    toTTString(chanpath, dst: &path.buf)
                    let parentid = TT_GetChannelIDFromPath(ttInst, fromStringWrap(&path))
                    if parentid > 0 {
                        channelsTab.rejoinchannel.nParentID = parentid
                        setChannelString(NAME, &channelsTab.rejoinchannel, channame)
                        setChannelString(PASSWORD, &channelsTab.rejoinchannel, server.chanpasswd)
                        channelsTab.rejoinchannel.audiocodec = newAudioCodec(DEFAULT_AUDIOCODEC)
                    }
                }
                
                //only do the initial login once. ChannelListViewController will
                //handle rejoin
                server.channel.removeAll()
                server.chanpasswd.removeAll()
            }
            
            let statusMessage = server.statusmsg.isEmpty ? preferredStatusMessage() : server.statusmsg
            applyPreferredStatus(message: statusMessage)
        default :
            break
        }
    }
    
    func login() {
        
        let channelsTab = viewControllers?[CHANNELTAB] as! ChannelListViewController

        let nickname = server.nickname.isEmpty ? (UserDefaults.standard.string(forKey: PREF_GENERAL_NICKNAME) ?? "") : server.nickname
        
        cmdid = TT_DoLoginEx(ttInst, nickname, server.username, server.password, AppInfo.getClientName())
        channelsTab.activeCommands[cmdid] = .loginCmd
        
        reconnecttimer?.invalidate()
    }

    func closeConnectionResources() {
        if isClosingConnection {
            return
        }
        isClosingConnection = true
        MonitorCenter.shared.disconnectedLive(from: server)

        polltimer?.invalidate()
        polltimer = nil
        reconnecttimer?.invalidate()
        reconnecttimer = nil

        stopAudioRouteMonitoring()
        NotificationCenter.default.removeObserver(self)
        UIApplication.shared.endReceivingRemoteControlEvents()

        if let channelsTab = viewControllers?[CHANNELTAB] as? ChannelListViewController {
            channelsTab.clearServerState()
        }

        removeTTMessageHandler(self)
        viewControllers?.forEach { viewController in
            if let eventHandler = viewController as? TeamTalkEvent {
                removeTTMessageHandler(eventHandler)
            }
        }
        unreadmessages.removeAll()

        recorder.stop()
        if mixer?.hasAudioNet == true {
            AudioNetBridge.shared.stopSending()
        }
        stopMix()
        removeOfficialFile()
        resetAudioStateForDisconnect()
        if let instance = teamTalkInstance {
            TT_Disconnect(instance)
            TT_CloseTeamTalk(instance)
            if ttInst == instance { ttInst = nil }
            teamTalkInstance = nil
        }
        ConnectedServerManager.shared.remove(self)
    }

    func disconnectAndReturnToServerList() {
        closeConnectionResources()
        if let navigationController = navigationController {
            navigationController.popViewController(animated: true)
        } else {
            dismiss(animated: true, completion: nil)
        }
    }

    func disconnectAndDismissServerSheet() {
        closeConnectionResources()
        if let navigationController = navigationController, navigationController.presentingViewController != nil {
            navigationController.dismiss(animated: true, completion: nil)
        }
        else if presentingViewController != nil {
            dismiss(animated: true, completion: nil)
        }
        else {
            navigationController?.popViewController(animated: true)
        }
    }
    
    @IBAction func disconnectButtonPressed(_ sender: UIBarButtonItem) {
        disconnectAndReturnToServerList()
    }

    @objc private func showSaveServerDialog() {
        let alert = UIAlertController(title: NSLocalizedString("Save Server", comment: "Dialog message"),
                                      message: NSLocalizedString("Enter a name for this server.", comment: "Dialog message"),
                                      preferredStyle: .alert)
        alert.addTextField { [weak self] textField in
            guard let self else { return }
            textField.text = publicServerName.isEmpty
                ? NSLocalizedString("Server", comment: "unnamed server entry")
                : publicServerName
            textField.placeholder = NSLocalizedString("Server Name", comment: "server entry name")
        }
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "Dialog message"), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("Save", comment: "Dialog message"), style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.saveCurrentServer(name: name.isEmpty ? self.serverDisplayName : name)
        })
        present(alert, animated: true, completion: nil)
    }

    private func saveCurrentServer(name: String) {
        var servers = loadLocalServers()
        servers = servers.filter({$0.name != name})
        server.name = name
        servers.append(server)
        saveLocalServers(servers)
        refreshServerNavigationButtons()
        ConnectedServerManager.shared.sessions.forEach { $0.refreshConnectedServerNavigation() }
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
//        let channelsTab = viewControllers?[CHANNELTAB] as! ChannelListViewController
//        channelsTab.prepareForSegue(segue, sender: sender)
        
        for v in viewControllers! {
            v.prepare(for: segue, sender: sender)
        }
    }
}

private struct ChannelRemoteFile {
    let rawFile: RemoteFile
    let id: INT32
    let channelID: INT32
    let name: String
    let size: Int64
    let username: String
    let uploadTime: String

    init(_ file: RemoteFile) {
        rawFile = file
        id = file.nFileID
        channelID = file.nChannelID
        name = fromTTString(file.szFileName)
        size = file.nFileSize
        username = fromTTString(file.szUsername)
        uploadTime = fromTTString(file.szUploadTime)
    }
}

private enum ChannelFileTransferKind {
    case upload
    case download
}

private struct ChannelFileTransferState {
    let kind: ChannelFileTransferKind
    let fileName: String
    var transferred: Int64
    var fileSize: Int64
    let localURL: URL?
    let startedAt: Date
    let remoteIdentity: String?
}

private struct ChannelDownloadRecord: Codable {
    let fileName: String
    let sha256: String
}

private final class ChannelFileCardCell: UITableViewCell {
    static let reuseIdentifier = "ChannelFileCardCell"

    private let cardView = UIView()
    private let nameLabel = UILabel()
    private let sizeLabel = UILabel()
    private let uploadDetailsLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureLayout()
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayout()
    }

    func configure(name: String,
                   size: String,
                   uploadDetails: String,
                   canDownload: Bool) {
        nameLabel.text = name
        sizeLabel.text = size
        uploadDetailsLabel.text = uploadDetails

        isAccessibilityElement = true
        accessibilityLabel = [name, size, uploadDetails].joined(separator: ", ")
        accessibilityValue = nil
        accessibilityHint = canDownload
            ? NSLocalizedString("Downloads and previews the file.", comment: "files")
            : nil
        accessibilityTraits = canDownload ? .button : .staticText
        selectionStyle = canDownload ? .default : .none
    }

    private func configureLayout() {
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        cardView.backgroundColor = .secondarySystemGroupedBackground
        cardView.layer.cornerRadius = 14
        cardView.layer.cornerCurve = .continuous
        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.isAccessibilityElement = false
        contentView.addSubview(cardView)

        nameLabel.font = UIFont.preferredFont(forTextStyle: .headline)
        nameLabel.textColor = .label

        for label in [nameLabel, sizeLabel, uploadDetailsLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            label.isAccessibilityElement = false
        }

        for label in [sizeLabel, uploadDetailsLabel] {
            label.font = UIFont.preferredFont(forTextStyle: .subheadline)
            label.textColor = .secondaryLabel
        }

        let stackView = UIStackView(arrangedSubviews: [nameLabel, sizeLabel, uploadDetailsLabel])
        stackView.axis = .vertical
        stackView.spacing = 5
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.isAccessibilityElement = false
        cardView.addSubview(stackView)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            stackView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),
            stackView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 14),
            stackView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -14)
        ])
    }
}

private final class FileTransferProgressViewController: UIViewController {
    private let headingLabel = UILabel()
    private let fileNameLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let percentLabel = UILabel()
    private let transferredTitleLabel = UILabel()
    private let transferredLabel = UILabel()
    private let throughputTitleLabel = UILabel()
    private let throughputLabel = UILabel()
    private let cancelButton = UIButton(type: .system)
    private let onCancel: () -> Void

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .formSheet
        isModalInPresentation = true
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        onCancel = {}
        super.init(coder: coder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureLayout()
    }

    func update(with state: ChannelFileTransferState) {
        headingLabel.text = state.kind == .download
            ? NSLocalizedString("Downloading File", comment: "files")
            : NSLocalizedString("Uploading File", comment: "files")
        fileNameLabel.text = state.fileName
        transferredTitleLabel.text = state.kind == .download
            ? NSLocalizedString("Downloaded", comment: "files")
            : NSLocalizedString("Uploaded", comment: "files")

        if state.fileSize > 0 {
            let progress = min(1, max(0, Float(Double(state.transferred) / Double(state.fileSize))))
            progressView.setProgress(progress, animated: true)
            percentLabel.text = String(format: "%.0f%%", progress * 100)
            transferredLabel.text = String(format: NSLocalizedString("%@ of %@", comment: "files"),
                                           formatByteCount(state.transferred),
                                           formatByteCount(state.fileSize))
        } else {
            progressView.setProgress(0, animated: true)
            percentLabel.text = NSLocalizedString("Unknown", comment: "files")
            transferredLabel.text = formatByteCount(state.transferred)
        }

        let elapsed = max(Date().timeIntervalSince(state.startedAt), 0.1)
        let throughput = Int64(Double(state.transferred) / elapsed)
        throughputLabel.text = String(format: NSLocalizedString("%@/s", comment: "files"), formatByteCount(throughput))

        headingLabel.accessibilityLabel = headingLabel.text
        fileNameLabel.accessibilityLabel = String(format: NSLocalizedString("File %@", comment: "files"), state.fileName)
        transferredLabel.accessibilityLabel = state.kind == .download
            ? String(format: NSLocalizedString("Downloaded %@", comment: "files"), transferredLabel.text ?? "")
            : String(format: NSLocalizedString("Uploaded %@", comment: "files"), transferredLabel.text ?? "")
        throughputLabel.accessibilityLabel = String(format: NSLocalizedString("Throughput %@", comment: "files"), throughputLabel.text ?? "")
    }

    @objc private func cancelPressed() {
        onCancel()
    }

    private func configureLayout() {
        let stackView = UIStackView(arrangedSubviews: [
            headingLabel,
            fileNameLabel,
            progressView,
            percentLabel,
            labeledValue(titleLabel: transferredTitleLabel, valueLabel: transferredLabel),
            labeledValue(titleLabel: throughputTitleLabel, valueLabel: throughputLabel),
            cancelButton
        ])
        stackView.axis = .vertical
        stackView.spacing = 18
        stackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stackView)

        headingLabel.font = UIFont.preferredFont(forTextStyle: .title2)
        headingLabel.adjustsFontForContentSizeCategory = true
        headingLabel.textAlignment = .center
        headingLabel.numberOfLines = 0
        headingLabel.isAccessibilityElement = true

        fileNameLabel.font = UIFont.preferredFont(forTextStyle: .body)
        fileNameLabel.adjustsFontForContentSizeCategory = true
        fileNameLabel.textAlignment = .center
        fileNameLabel.numberOfLines = 0
        fileNameLabel.isAccessibilityElement = true

        progressView.isAccessibilityElement = true

        percentLabel.font = UIFont.preferredFont(forTextStyle: .headline)
        percentLabel.adjustsFontForContentSizeCategory = true
        percentLabel.textAlignment = .center
        percentLabel.isAccessibilityElement = false

        throughputTitleLabel.text = NSLocalizedString("Throughput", comment: "files")
        transferredTitleLabel.isAccessibilityElement = false
        throughputTitleLabel.isAccessibilityElement = false
        transferredLabel.isAccessibilityElement = true
        throughputLabel.isAccessibilityElement = true

        cancelButton.setTitle(NSLocalizedString("Cancel", comment: "message dialog"), for: .normal)
        cancelButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
        cancelButton.titleLabel?.adjustsFontForContentSizeCategory = true
        cancelButton.addTarget(self, action: #selector(cancelPressed), for: .touchUpInside)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor),
            stackView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stackView.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24)
        ])
    }

    private func labeledValue(titleLabel: UILabel, valueLabel: UILabel) -> UIStackView {
        titleLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .secondaryLabel

        valueLabel.font = UIFont.preferredFont(forTextStyle: .body)
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.numberOfLines = 0

        let stackView = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        stackView.axis = .vertical
        stackView.spacing = 4
        return stackView
    }

    private func formatByteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

final class ChannelFilesViewController: UITableViewController, TeamTalkEvent, UIDocumentPickerDelegate, UISearchResultsUpdating {
    private let channelID: INT32
    private let serverIdentifier: String
    private var files = [ChannelRemoteFile]()
    private var displayedFiles = [ChannelRemoteFile]()
    private let searchController = UISearchController(searchResultsController: nil)
    private var sortField = preferredFileSortField()
    private var sortAscending = preferredFileSortAscending()
    private var transfers = [INT32: ChannelFileTransferState]()
    private var uploadTemporaryURLs = Set<URL>()
    private var statusMessage = ""
    private var activeFileTransferID: INT32?
    private var fileTransferProgressViewController: FileTransferProgressViewController?
    private var fileTransferProgressTimer: Timer?
    private var canceledTransferIDs = Set<INT32>()

    init(channelID: INT32, serverIdentifier: String) {
        self.channelID = channelID
        self.serverIdentifier = serverIdentifier
        super.init(style: .insetGrouped)
        title = NSLocalizedString("Files", comment: "files")
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        channelID = 0
        serverIdentifier = ""
        super.init(coder: coder)
        title = NSLocalizedString("Files", comment: "files")
    }

    deinit {
        stopFileTransferProgressTimer()
        removeTTMessageHandler(self)
        NotificationCenter.default.removeObserver(self)
        cleanupUploadTemporaryFiles()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addToTTMessages(self)
        tableView.register(ChannelFileCardCell.self, forCellReuseIdentifier: ChannelFileCardCell.reuseIdentifier)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 130
        tableView.separatorStyle = .none
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = NSLocalizedString("Search Files", comment: "files")
        definesPresentationContext = true
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(fileSortPreferenceChanged),
                                               name: .fileSortPreferenceDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(fileSortPreferenceChanged),
                                               name: .iCloudSettingsDidApply,
                                               object: nil)
        configureNavigationButtons()
        refreshFiles()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        configureNavigationButtons()
    }

    private func configureNavigationButtons() {
        var buttons = [UIBarButtonItem]()

        if canUploadFiles() {
            let uploadButton = UIBarButtonItem(image: UIImage(systemName: "plus"),
                                               style: .plain,
                                               target: self,
                                               action: #selector(uploadFile))
            uploadButton.accessibilityLabel = NSLocalizedString("Upload File", comment: "files")
            buttons.append(uploadButton)
        }

        if files.isEmpty == false {
            let sortButton = UIBarButtonItem(image: UIImage(systemName: "arrow.up.arrow.down"),
                                             menu: makeSortMenu())
            sortButton.accessibilityLabel = NSLocalizedString("Sort Files", comment: "files")
            buttons.append(sortButton)
        }

        navigationItem.rightBarButtonItems = buttons
    }

    private func makeSortMenu() -> UIMenu {
        let fieldMenu = UIMenu(title: NSLocalizedString("Sort By", comment: "files"),
                               options: .displayInline,
                               children: [
                                sortFieldAction(title: NSLocalizedString("Name", comment: "files"), field: .name),
                                sortFieldAction(title: NSLocalizedString("Size", comment: "files"), field: .size),
                                sortFieldAction(title: NSLocalizedString("Owner", comment: "files"), field: .owner),
                                sortFieldAction(title: NSLocalizedString("Date", comment: "files"), field: .date)
                               ])
        let orderMenu = UIMenu(title: NSLocalizedString("Order", comment: "files"),
                               options: .displayInline,
                               children: [
                                sortOrderAction(title: NSLocalizedString("Ascending", comment: "files"), ascending: true),
                                sortOrderAction(title: NSLocalizedString("Descending", comment: "files"), ascending: false)
                               ])
        return UIMenu(title: NSLocalizedString("Sort Files", comment: "files"), children: [fieldMenu, orderMenu])
    }

    private func sortFieldAction(title: String, field: FileSortField) -> UIAction {
        UIAction(title: title, state: sortField == field ? .on : .off) { [weak self] _ in
            guard let self else { return }
            saveFileSortPreferences(field: field, ascending: sortAscending)
        }
    }

    private func sortOrderAction(title: String, ascending: Bool) -> UIAction {
        UIAction(title: title, state: sortAscending == ascending ? .on : .off) { [weak self] _ in
            guard let self else { return }
            saveFileSortPreferences(field: sortField, ascending: ascending)
        }
    }

    @objc private func fileSortPreferenceChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sortField = preferredFileSortField()
            self.sortAscending = preferredFileSortAscending()
            self.refreshDisplayedFiles()
            self.configureNavigationButtons()
            self.tableView.reloadData()
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        refreshDisplayedFiles()
        tableView.reloadData()
    }

    private func refreshDisplayedFiles() {
        let query = searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let matchingFiles = query.isEmpty
            ? files
            : files.filter { $0.name.localizedStandardContains(query) }
        displayedFiles = sorted(matchingFiles)
    }

    private func sorted(_ files: [ChannelRemoteFile]) -> [ChannelRemoteFile] {
        if sortField == .date {
            let datedFiles = files.map { (file: $0, date: parsedUploadDate($0.uploadTime)) }
            return datedFiles.sorted { first, second in
                let comparison: ComparisonResult
                if let firstDate = first.date, let secondDate = second.date {
                    comparison = firstDate.compare(secondDate)
                } else {
                    comparison = first.file.uploadTime.localizedCaseInsensitiveCompare(second.file.uploadTime)
                }
                if comparison == .orderedSame {
                    return first.file.name.localizedCaseInsensitiveCompare(second.file.name) == (sortAscending ? .orderedAscending : .orderedDescending)
                }
                return comparison == (sortAscending ? .orderedAscending : .orderedDescending)
            }.map(\.file)
        }

        return files.sorted { first, second in
            let comparison: ComparisonResult
            switch sortField {
            case .name:
                comparison = first.name.localizedCaseInsensitiveCompare(second.name)
            case .size:
                comparison = first.size == second.size ? .orderedSame : (first.size < second.size ? .orderedAscending : .orderedDescending)
            case .owner:
                comparison = first.username.localizedCaseInsensitiveCompare(second.username)
            case .date:
                comparison = .orderedSame
            }

            if comparison == .orderedSame {
                return first.name.localizedCaseInsensitiveCompare(second.name) == (sortAscending ? .orderedAscending : .orderedDescending)
            }
            return comparison == (sortAscending ? .orderedAscending : .orderedDescending)
        }
    }

    private func updateFileListUI() {
        if files.isEmpty {
            searchController.searchBar.text = nil
            navigationItem.searchController = nil
        } else if navigationItem.searchController == nil {
            navigationItem.searchController = searchController
            // iOS places it (automatic placement).
            navigationItem.preferredSearchBarPlacement = .automatic
        }
        refreshDisplayedFiles()
        configureNavigationButtons()
        tableView.reloadData()
    }

    func refreshFiles() {
        var count: INT32 = 0
        guard TT_GetChannelFiles(ttInst, channelID, nil, &count) == TRUE else {
            statusMessage = NSLocalizedString("Could not list files.", comment: "files")
            tableView.reloadData()
            return
        }

        guard count > 0 else {
            files.removeAll()
            statusMessage = ""
            updateFileListUI()
            return
        }

        var remoteFiles = Array(repeating: RemoteFile(), count: Int(count))
        let success = remoteFiles.withUnsafeMutableBufferPointer { buffer -> TTBOOL in
            var requestedCount = count
            return TT_GetChannelFiles(ttInst, channelID, buffer.baseAddress, &requestedCount)
        }
        if success == TRUE {
            files = remoteFiles
                .map(ChannelRemoteFile.init)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            statusMessage = ""
        } else {
            statusMessage = NSLocalizedString("Could not list files.", comment: "files")
        }
        updateFileListUI()
    }

    @objc private func uploadFile() {
        guard canUploadFiles() else { return }
        let picker: UIDocumentPickerViewController
        if #available(iOS 14.0, *) {
            picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        } else {
            picker = UIDocumentPickerViewController(documentTypes: ["public.item", "public.data"], in: .import)
        }
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let sourceURL = urls.first else { return }
        do {
            let uploadURL = try temporaryUploadURL(for: sourceURL)
            var wrapped = StringWrap()
            toTTString(uploadURL.path, dst: &wrapped.buf)
            let commandID = TT_DoSendFile(ttInst, channelID, fromStringWrap(&wrapped))
            if commandID < 0 {
                try? FileManager.default.removeItem(at: uploadURL)
                statusMessage = NSLocalizedString("Could not upload file.", comment: "files")
            } else {
                uploadTemporaryURLs.insert(uploadURL)
                let state = ChannelFileTransferState(kind: .upload,
                                                     fileName: uploadURL.lastPathComponent,
                                                     transferred: 0,
                                                     fileSize: fileSize(at: uploadURL),
                                                     localURL: uploadURL,
                                                     startedAt: Date(),
                                                     remoteIdentity: nil)
                transfers[commandID] = state
                statusMessage = ""
                showOrUpdateFileTransferProgress(for: commandID, state: state)
            }
            tableView.reloadData()
        } catch {
            statusMessage = error.localizedDescription
            tableView.reloadData()
        }
    }

    private func temporaryUploadURL(for sourceURL: URL) throws -> URL {
        let access = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if access {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let destinationURL = uniqueTemporaryURL(fileName: sourceURL.lastPathComponent)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private func download(_ file: ChannelRemoteFile) {
        guard canDownloadFiles() else { return }
        let identity = remoteIdentity(for: file)
        if let record = loadDownloadRecords()[identity],
           let localURL = try? downloadsDirectory().appendingPathComponent(record.fileName),
           FileManager.default.fileExists(atPath: localURL.path) {
            statusMessage = NSLocalizedString("Checking downloaded file…", comment: "files")
            tableView.reloadData()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let hash = try? self?.sha256(of: localURL)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    statusMessage = ""
                    if hash == record.sha256 {
                        preview(localURL)
                    } else {
                        removeDownloadRecord(for: identity)
                        beginDownload(file, identity: identity)
                    }
                    tableView.reloadData()
                }
            }
            return
        }
        beginDownload(file, identity: identity)
    }

    private func beginDownload(_ file: ChannelRemoteFile, identity: String) {
        let destinationURL: URL
        do {
            destinationURL = try uniqueDownloadURL(fileName: file.name)
        } catch {
            statusMessage = error.localizedDescription
            tableView.reloadData()
            return
        }
        var wrapped = StringWrap()
        toTTString(destinationURL.path, dst: &wrapped.buf)
        let commandID = TT_DoRecvFile(ttInst, file.channelID, file.id, fromStringWrap(&wrapped))
        if commandID < 0 {
            statusMessage = NSLocalizedString("Could not download file.", comment: "files")
            tableView.reloadData()
        } else {
            let state = ChannelFileTransferState(kind: .download,
                                                 fileName: file.name,
                                                 transferred: 0,
                                                 fileSize: file.size,
                                                 localURL: destinationURL,
                                                 startedAt: Date(),
                                                 remoteIdentity: identity)
            transfers[commandID] = state
            statusMessage = ""
            showOrUpdateFileTransferProgress(for: commandID, state: state)
            tableView.reloadData()
        }
    }

    private func confirmDelete(_ file: ChannelRemoteFile) {
        let alert = UIAlertController(title: NSLocalizedString("Delete File?", comment: "files"),
                                      message: file.name,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "message dialog"), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("Delete", comment: "message dialog"), style: .destructive) { [weak self] _ in
            self?.delete(file)
        })
        present(alert, animated: true)
    }

    private func delete(_ file: ChannelRemoteFile) {
        let commandID = TT_DoDeleteFile(ttInst, file.channelID, file.id)
        if commandID < 0 {
            statusMessage = NSLocalizedString("Could not delete file.", comment: "files")
            tableView.reloadData()
        }
    }

    func handleTTMessage(_ message: TTMessage) {
        switch message.nClientEvent {
        case CLIENTEVENT_CMD_FILE_NEW:
            let file = ChannelRemoteFile(message.remotefile)
            if file.channelID == channelID {
                upsert(file)
            }

        case CLIENTEVENT_CMD_FILE_REMOVE:
            let file = ChannelRemoteFile(message.remotefile)
            if file.channelID == channelID {
                files.removeAll { $0.id == file.id }
                updateFileListUI()
            }

        case CLIENTEVENT_FILETRANSFER:
            handleFileTransfer(message.filetransfer)

        case CLIENTEVENT_CMD_ERROR:
            statusMessage = getClientErrorMsg(message.clienterrormsg, strprop: ERRMESSAGE)
            tableView.reloadData()

        default:
            break
        }
    }

    private func handleFileTransfer(_ transfer: FileTransfer) {
        let currentTransfer = currentFileTransfer(for: transfer)
        let transferID = currentTransfer.nTransferID
        let localPath = fromTTString(currentTransfer.szLocalFilePath)
        let remoteName = fromTTString(currentTransfer.szRemoteFileName)
        let kind: ChannelFileTransferKind = currentTransfer.bInbound == TRUE ? .download : .upload
        let existingState = transfers[transferID] ?? activeCommandState(for: transferID)
        var state = existingState ?? ChannelFileTransferState(kind: kind,
                                                             fileName: remoteName,
                                                             transferred: currentTransfer.nTransferred,
                                                             fileSize: currentTransfer.nFileSize,
                                                             localURL: localPath.isEmpty ? nil : URL(fileURLWithPath: localPath),
                                                             startedAt: Date(),
                                                             remoteIdentity: nil)
        state.transferred = currentTransfer.nTransferred
        state.fileSize = currentTransfer.nFileSize
        transfers[transferID] = state

        switch currentTransfer.nStatus {
        case FILETRANSFER_FINISHED:
            transfers.removeValue(forKey: transferID)
            canceledTransferIDs.remove(transferID)
            statusMessage = ""
            dismissFileTransferProgressAlert(for: transferID)
            if state.kind == .download, let url = state.localURL {
                finalizeDownloadedFile(at: url, remoteIdentity: state.remoteIdentity)
                playSound(.filetx_COMPLETE)
            } else {
                cleanupUploadTemporaryFile(at: localPath)
                refreshFiles()
            }

        case FILETRANSFER_ERROR:
            transfers.removeValue(forKey: transferID)
            statusMessage = ""
            dismissFileTransferProgressAlert(for: transferID)
            cleanupUploadTemporaryFile(at: localPath)
            canceledTransferIDs.remove(transferID)

        case FILETRANSFER_ACTIVE:
            showOrUpdateFileTransferProgress(for: transferID, state: state)

        default:
            break
        }
        tableView.reloadData()
    }

    private func hasUserRight(_ right: UserRights) -> Bool {
        (TT_GetMyUserType(ttInst) & USERTYPE_ADMIN.rawValue) != 0 ||
            (TT_GetMyUserRights(ttInst) & right) != 0
    }

    private func canUploadFiles() -> Bool {
        hasUserRight(USERRIGHT_UPLOAD_FILES.rawValue)
    }

    private func canDownloadFiles() -> Bool {
        hasUserRight(USERRIGHT_DOWNLOAD_FILES.rawValue)
    }

    private func canDelete(_ file: ChannelRemoteFile) -> Bool {
        if (TT_GetMyUserType(ttInst) & USERTYPE_ADMIN.rawValue) != 0 {
            return true
        }
        if TT_IsChannelOperator(ttInst, TT_GetMyUserID(ttInst), file.channelID) == TRUE {
            return true
        }
        return file.username.isEmpty == false && file.username == myUsername()
    }

    private func myUsername() -> String {
        var account = UserAccount()
        guard TT_GetMyUserAccount(ttInst, &account) == TRUE else { return "" }
        return fromTTString(account.szUsername)
    }

    private func activeCommandState(for transferID: INT32) -> ChannelFileTransferState? {
        guard let activeFileTransferID,
              activeFileTransferID != transferID,
              let state = transfers.removeValue(forKey: activeFileTransferID) else {
            return nil
        }
        return state
    }

    private func currentFileTransfer(for transfer: FileTransfer) -> FileTransfer {
        var currentTransfer = transfer
        if TT_GetFileTransferInfo(ttInst, transfer.nTransferID, &currentTransfer) == TRUE {
            return currentTransfer
        }
        return transfer
    }

    private func upsert(_ file: ChannelRemoteFile) {
        if let index = files.firstIndex(where: { $0.id == file.id }) {
            files[index] = file
        } else {
            files.append(file)
        }
        files.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        updateFileListUI()
    }

    private func showOrUpdateFileTransferProgress(for transferID: INT32, state: ChannelFileTransferState) {
        activeFileTransferID = transferID
        startFileTransferProgressTimer()

        guard let progressViewController = fileTransferProgressViewController else {
            let progressViewController = FileTransferProgressViewController { [weak self] in
                self?.cancelActiveFileTransfer()
            }
            progressViewController.update(with: state)
            fileTransferProgressViewController = progressViewController
            presentFileTransferProgress(progressViewController)
            return
        }

        progressViewController.update(with: state)
    }

    private func presentFileTransferProgress(_ progressViewController: FileTransferProgressViewController) {
        if let presentedViewController, presentedViewController !== progressViewController {
            presentedViewController.dismiss(animated: true) { [weak self] in
                self?.present(progressViewController, animated: true)
            }
        } else if presentedViewController == nil {
            present(progressViewController, animated: true)
        }
    }

    private func startFileTransferProgressTimer() {
        guard fileTransferProgressTimer == nil else { return }
        fileTransferProgressTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollActiveFileTransfer()
        }
    }

    private func stopFileTransferProgressTimer() {
        fileTransferProgressTimer?.invalidate()
        fileTransferProgressTimer = nil
    }

    private func pollActiveFileTransfer() {
        guard let transferID = activeFileTransferID else {
            stopFileTransferProgressTimer()
            return
        }

        var transfer = FileTransfer()
        guard TT_GetFileTransferInfo(ttInst, transferID, &transfer) == TRUE else {
            if let state = transfers[transferID] {
                fileTransferProgressViewController?.update(with: state)
            }
            return
        }

        handleFileTransfer(transfer)
    }

    private func dismissFileTransferProgressAlert(for transferID: INT32) {
        guard activeFileTransferID == transferID else { return }
        activeFileTransferID = nil
        stopFileTransferProgressTimer()
        guard let progressViewController = fileTransferProgressViewController else { return }
        fileTransferProgressViewController = nil
        progressViewController.dismiss(animated: true)
    }

    private func cancelFileTransfer(transferID: INT32) {
        canceledTransferIDs.insert(transferID)
        _ = TT_CancelFileTransfer(ttInst, transferID)
        activeFileTransferID = nil
        stopFileTransferProgressTimer()
        statusMessage = ""
        fileTransferProgressViewController?.dismiss(animated: true)
        fileTransferProgressViewController = nil
        tableView.reloadData()
    }

    private func cancelActiveFileTransfer() {
        guard let transferID = activeFileTransferID else { return }
        cancelFileTransfer(transferID: transferID)
    }

    /// Opens a downloaded file in QuickLook.
    private func preview(_ url: URL) {
        let controller = TeamTalkPreviewController(url: url)
        if let presentedViewController {
            presentedViewController.dismiss(animated: true) { [weak self] in
                self?.present(controller, animated: true)
            }
        } else {
            present(controller, animated: true)
        }
    }

    private func uniqueTemporaryURL(fileName: String) -> URL {
        let sanitizedName = fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "TeamTalk File" : fileName
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent(sanitizedName)
        return uniqueURL(for: baseURL)
    }

    private func uniqueDownloadURL(fileName: String) throws -> URL {
        let sanitizedName = URL(fileURLWithPath: fileName).lastPathComponent
        let safeName = sanitizedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "TeamTalk File"
            : sanitizedName
        return uniqueURL(for: try downloadsDirectory().appendingPathComponent(safeName))
    }

    private func uniqueURL(for baseURL: URL) -> URL {
        var candidateURL = baseURL
        var index = 1
        while FileManager.default.fileExists(atPath: candidateURL.path) {
            let name = baseURL.deletingPathExtension().lastPathComponent
            let ext = baseURL.pathExtension
            let indexedName = ext.isEmpty ? "\(name)-\(index)" : "\(name)-\(index).\(ext)"
            candidateURL = baseURL.deletingLastPathComponent().appendingPathComponent(indexedName)
            index += 1
        }
        return candidateURL
    }

    private func downloadsDirectory() throws -> URL {
        let documentsURL = try FileManager.default.url(for: .documentDirectory,
                                                       in: .userDomainMask,
                                                       appropriateFor: nil,
                                                       create: true)
        let downloadsURL = documentsURL.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsURL, withIntermediateDirectories: true)
        return downloadsURL
    }

    private func remoteIdentity(for file: ChannelRemoteFile) -> String {
        [serverIdentifier,
         String(file.channelID),
         String(file.id),
         String(file.size),
         file.uploadTime,
         file.name].joined(separator: "|")
    }

    private func finalizeDownloadedFile(at url: URL, remoteIdentity: String?) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let hash = try? self?.sha256(of: url)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let remoteIdentity, let hash {
                    var records = loadDownloadRecords()
                    records[remoteIdentity] = ChannelDownloadRecord(fileName: url.lastPathComponent, sha256: hash)
                    saveDownloadRecords(records)
                }
                UIAccessibility.post(notification: .announcement,
                                     argument: String(format: NSLocalizedString("Download complete. %@", comment: "files"),
                                                      url.lastPathComponent))
                preview(url)
            }
        }
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: 1024 * 1024)
            guard data.isEmpty == false else { return false }
            hasher.update(data: data)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func downloadRecordsURL() throws -> URL {
        let supportURL = try FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: nil,
                                                     create: true)
        try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
        return supportURL.appendingPathComponent("channel-downloads.json")
    }

    private func loadDownloadRecords() -> [String: ChannelDownloadRecord] {
        guard let url = try? downloadRecordsURL(),
              let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([String: ChannelDownloadRecord].self, from: data) else {
            return [:]
        }
        return records
    }

    private func saveDownloadRecords(_ records: [String: ChannelDownloadRecord]) {
        guard let url = try? downloadRecordsURL(),
              let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func removeDownloadRecord(for identity: String) {
        var records = loadDownloadRecords()
        records.removeValue(forKey: identity)
        saveDownloadRecords(records)
    }

    private func cleanupUploadTemporaryFile(at path: String) {
        guard path.isEmpty == false else { return }
        let url = URL(fileURLWithPath: path)
        if uploadTemporaryURLs.remove(url) != nil {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func cleanupUploadTemporaryFiles() {
        for url in uploadTemporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        uploadTemporaryURLs.removeAll()
    }

    private func uploadDetailsText(for file: ChannelRemoteFile) -> String {
        let username = file.username.isEmpty
            ? NSLocalizedString("Unknown", comment: "files")
            : file.username
        let formattedDate = formattedUploadTime(file.uploadTime)
        return String(format: NSLocalizedString("Uploaded by %@ on %@", comment: "files"), username, formattedDate)
    }

    private func formattedUploadTime(_ value: String) -> String {
        guard value.isEmpty == false else {
            return NSLocalizedString("Unknown", comment: "files")
        }

        guard let date = parsedUploadDate(value) else { return value }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func parsedUploadDate(_ value: String) -> Date? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        let formats = [
            "yyyy/MM/dd HH:mm:ss",
            "yyyy/MM/dd HH:mm",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd'T'HH:mm:ss"
        ]

        for format in formats {
            parser.dateFormat = format
            if let date = parser.date(from: value) {
                return date
            }
        }
        return nil
    }

    private func formatByteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        statusMessage.isEmpty ? 1 : 2
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 1 {
            return 1
        }
        return max(displayedFiles.count, 1)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 1 {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = statusMessage
            cell.textLabel?.textColor = .secondaryLabel
            cell.textLabel?.numberOfLines = 0
            cell.selectionStyle = .none
            return cell
        }

        guard displayedFiles.isEmpty == false else {
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
            if files.isEmpty {
                cell.textLabel?.text = NSLocalizedString("No files", comment: "files")
                cell.detailTextLabel?.text = NSLocalizedString("Files uploaded to this channel will appear here.", comment: "files")
            } else {
                cell.textLabel?.text = NSLocalizedString("No matching files", comment: "files")
                cell.detailTextLabel?.text = NSLocalizedString("Try a different search.", comment: "files")
            }
            cell.detailTextLabel?.numberOfLines = 0
            cell.selectionStyle = .none
            cell.isAccessibilityElement = false
            cell.textLabel?.isAccessibilityElement = true
            cell.detailTextLabel?.isAccessibilityElement = true
            cell.accessibilityElements = [cell.textLabel, cell.detailTextLabel].compactMap { $0 }
            return cell
        }

        let file = displayedFiles[indexPath.row]
        guard let cell = tableView.dequeueReusableCell(withIdentifier: ChannelFileCardCell.reuseIdentifier,
                                                       for: indexPath) as? ChannelFileCardCell else {
            return UITableViewCell()
        }
        cell.configure(name: file.name,
                       size: formatByteCount(file.size),
                       uploadDetails: uploadDetailsText(for: file),
                       canDownload: canDownloadFiles())
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let visibleFiles = displayedFiles
        guard canDownloadFiles(), indexPath.section == 0, visibleFiles.indices.contains(indexPath.row) else { return }
        download(visibleFiles[indexPath.row])
    }

    override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        indexPath.section == 0 && displayedFiles.indices.contains(indexPath.row) && canDownloadFiles()
    }

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let visibleFiles = displayedFiles
        guard indexPath.section == 0, visibleFiles.indices.contains(indexPath.row) else { return nil }
        let file = visibleFiles[indexPath.row]
        guard canDelete(file) else { return nil }
        let delete = UIContextualAction(style: .destructive,
                                        title: NSLocalizedString("Delete", comment: "files")) { [weak self] _, _, completion in
            self?.confirmDelete(file)
            completion(true)
        }
        delete.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [delete])
    }
}
