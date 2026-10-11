/*
 * The sound of monitor notifications: the selected sound pack's sounds (the
 * default), the iPhone's default notification sound, or none. iOS plays
 * notification sounds only from the app's own files, as WAV, AIFF or CAF
 * and at most 30 seconds, so the pack's sounds are converted into the app
 * group's Library/Sounds, where the notification service extension picks
 * them (see MonitorNotificationSound in MonitorShared.swift).
 */

import AVFoundation
import Foundation

enum MonitorNotificationSounds {
    /// The sounds monitor notifications use, by the name the service gives
    /// them, and the app's sound event for each.
    static let events: [(name: String, sound: Sounds)] = [
        ("logged_on", .logged_IN),
        ("logged_off", .logged_OUT),
        ("user_msg", .user_MSG),
        ("channel_msg", .chan_MSG),
        ("broadcast_msg", .broadcast_MSG),
        ("serverlost", .srv_LOST),
    ]

    private static let queue = DispatchQueue(label: "MonitorNotificationSounds", qos: .utility)

    /// Bring the notification sounds in line with the selected sound pack
    /// and sound event settings. Cheap when nothing changed.
    static func refresh() {
        let store = SoundPackStore.shared
        // What each sound should be now: a file, or nothing when its sound
        // event is turned off.
        let wanted: [(name: String, source: URL?)] = events.map { event in
            (event.name, getSoundFile(event.sound) == nil ? nil : store.soundURL(for: event.sound))
        }
        queue.async { export(wanted) }
    }

    private static func export(_ wanted: [(name: String, source: URL?)]) {
        guard let dir = MonitorNotificationSound.soundsDirectory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previous = MonitorNotificationSound.files
        var files: [String: String] = [:]
        for (name, source) in wanted {
            guard let source else {
                files[name] = ""
                continue
            }
            // A new name whenever the source changes: iOS remembers sounds by name.
            let attributes = try? FileManager.default.attributesOfItem(atPath: source.path)
            let stamp = "\(source.path)|\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
            let file = "ttng-\(name)-\(String(stableHash(stamp), radix: 36)).caf"
            if previous[name] == file, FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path) {
                files[name] = file
                continue
            }
            do {
                try convert(source, to: dir.appendingPathComponent(file))
                files[name] = file
            } catch {
                // The service's own sound plays instead.
                print("Could not prepare notification sound \(name): \(error.localizedDescription)")
            }
        }
        MonitorNotificationSound.files = files
        // Remove sounds no longer used.
        let keep = Set(files.values)
        for item in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where item.hasPrefix("ttng-") && !keep.contains(item) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(item))
        }
    }

    /// Convert any sound the app can play into 16-bit linear PCM CAF, at most
    /// 29 seconds, which iOS accepts as a notification sound.
    static func convert(_ source: URL, to destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        try? FileManager.default.removeItem(at: destination)
        let output = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        var remaining = min(input.length, AVAudioFramePosition(format.sampleRate * 29))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { return }
        while remaining > 0 {
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, remaining)))
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
    }

    /// A hash that stays the same between launches (Swift's does not).
    private static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 1469598103934665603
        for byte in s.utf8 {
            h = (h ^ UInt64(byte)) &* 1099511628211
        }
        return h
    }
}
