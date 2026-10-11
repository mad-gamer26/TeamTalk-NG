/*
 * Copyright (c) 2005-2018, BearWare.dk
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

// Mixing what is sent to the channel besides the microphone: an AudioNet
// sound and an audio file, together. The mix goes out as TeamTalk's media
// file stream through a live source of the TeamTalk library (so the
// microphone stays on), or as voice for users without the right to
// stream media files.

import AVFoundation
import os

/// An audio file read in small pieces at the mixer's format.
final class MixerFileSource {
    let url: URL
    private let file: AVAudioFile
    private let mixed: AVAudioFormat
    private let output: AVAudioFormat
    private let converter: AVAudioConverter?
    private let inputChannels: Int
    private let outputChannels: Int
    private var pending = [Float]()
    private(set) var finished = false

    /// Opens `url` and starts at `offsetMSec`.
    init(url: URL, sampleRate: Double, channels: Int, offsetMSec: UInt32 = 0) throws {
        self.url = url
        file = try AVAudioFile(forReading: url)
        let input = file.processingFormat
        inputChannels = Int(input.channelCount)
        outputChannels = channels
        // Channels are mixed by hand (AVAudioConverter can produce silence
        // when downmixing); the converter changes only the sample rate.
        guard let mixed = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: input.sampleRate,
                                        channels: AVAudioChannelCount(channels), interleaved: false),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels), interleaved: false) else {
            throw MediaFilePreparationError.invalidOutputFormat
        }
        self.mixed = mixed
        self.output = output
        converter = input.sampleRate == sampleRate ? nil : AVAudioConverter(from: mixed, to: output)
        if input.sampleRate != sampleRate && converter == nil {
            throw MediaFilePreparationError.converterUnavailable
        }
        if offsetMSec > 0 {
            file.framePosition = min(file.length, AVAudioFramePosition(Double(offsetMSec) * input.sampleRate / 1000))
        }
    }

    /// Back to the start (looping).
    func rewind() {
        file.framePosition = 0
        pending.removeAll()
        finished = false
    }

    /// Up to `frames` interleaved frames; fewer only at the end of the file.
    func read(frames: Int) -> [Float] {
        let wanted = frames * outputChannels
        while pending.count < wanted && finished == false {
            if let block = nextBlock(), block.isEmpty == false {
                pending += block
            } else {
                finished = true
            }
        }
        let count = min(wanted, pending.count)
        let result = Array(pending[0..<count])
        pending.removeFirst(count)
        return result
    }

    /// About 100 msec, interleaved at the output format; nil at the end.
    private func nextBlock() -> [Float]? {
        let inputFrames = AVAudioFrameCount(max(1, file.processingFormat.sampleRate / 10))
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inputFrames),
              (try? file.read(into: inBuffer, frameCount: inputFrames)) != nil,
              inBuffer.frameLength > 0,
              let mixBuffer = AVAudioPCMBuffer(pcmFormat: mixed, frameCapacity: inBuffer.frameLength),
              let source = inBuffer.floatChannelData,
              let target = mixBuffer.floatChannelData else { return nil }
        let length = Int(inBuffer.frameLength)
        mixBuffer.frameLength = inBuffer.frameLength
        for c in 0..<outputChannels {
            for f in 0..<length {
                target[c][f] = mixSample(source, frame: f, toChannel: c)
            }
        }
        var result: AVAudioPCMBuffer = mixBuffer
        if let converter {
            let capacity = AVAudioFrameCount(Double(length) * output.sampleRate / mixed.sampleRate) + 64
            guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
            var given = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if given {
                    status.pointee = .noDataNow
                    return nil
                }
                given = true
                status.pointee = .haveData
                return mixBuffer
            }
            if error != nil { return nil }
            result = converted
        }
        guard let data = result.floatChannelData else { return nil }
        let count = Int(result.frameLength)
        var interleaved = [Float](repeating: 0, count: count * outputChannels)
        for f in 0..<count {
            for c in 0..<outputChannels {
                interleaved[f * outputChannels + c] = data[c][f]
            }
        }
        return interleaved
    }

    /// Mono: the average; stereo: left and right (a mono file on both;
    /// further channels left out).
    private func mixSample(_ source: UnsafePointer<UnsafeMutablePointer<Float>>, frame: Int, toChannel channel: Int) -> Float {
        if outputChannels == 1 {
            let used = min(inputChannels, 2)
            var sum: Float = 0
            for c in 0..<used { sum += source[c][frame] }
            return sum / Float(used)
        }
        return source[min(channel, inputChannels - 1)][frame]
    }
}

/// Mixes the AudioNet sound and an audio file. Read on the sending
/// thread, changed on the main thread.
final class ChannelMixer: @unchecked Sendable {
    let sampleRate: Int
    let channels: Int
    let audioNet = AudioNetTapReader()

    private let lock = NSLock()
    private var audioNetOn = false
    private var file: MixerFileSource?
    private var filePaused = false
    private var fileGain: Float = 1
    private var loopFile = false
    private var audioNetGain: Float = 1
    /// The file has played to its end (called on the main thread).
    var fileFinished: ((URL) -> Void)?

    init(sampleRate: Int, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    var hasAudioNet: Bool { lock.withLock { audioNetOn } }
    var hasFile: Bool { lock.withLock { file != nil } }
    var isFilePaused: Bool { lock.withLock { filePaused } }
    var fileURL: URL? { lock.withLock { file?.url } }

    func setAudioNet(_ tap: AudioTap?) {
        audioNet.tap = tap
        lock.withLock { audioNetOn = tap != nil }
    }

    func setFile(_ source: MixerFileSource?, paused: Bool = false) {
        lock.withLock {
            file = source
            filePaused = paused
        }
    }

    /// Volumes in percent, as the volume sliders (50: unchanged).
    func setGains(filePercent: Double, audioNetPercent: Double) {
        let unchanged = Float(SOUND_GAIN_DEFAULT.rawValue)
        lock.withLock {
            fileGain = Float(streamGainLevel(percent: filePercent)) / unchanged
            audioNetGain = Float(streamGainLevel(percent: audioNetPercent)) / unchanged
        }
    }

    func setLoop(_ loop: Bool) {
        lock.withLock { loopFile = loop }
    }

    func setFilePaused(_ paused: Bool) {
        lock.withLock { filePaused = paused }
    }

    /// The next `frames` frames of interleaved 16-bit samples.
    func pull(frames: Int) -> [Int16] {
        let count = frames * channels
        var mix = [Float](repeating: 0, count: count)
        let (useAudioNet, source, paused, netGain, gain, loop) = lock.withLock { (audioNetOn, file, filePaused, audioNetGain, fileGain, loopFile) }
        if useAudioNet {
            let samples = audioNet.read(frames: frames, channels: channels)
            for i in 0..<min(count, samples.count) {
                mix[i] += Float(samples[i]) / 32768 * netGain
            }
        }
        if let source, paused == false {
            var samples = source.read(frames: frames)
            if loop && source.finished && samples.count < count {
                source.rewind()
                samples += source.read(frames: (count - samples.count) / channels)
            }
            for i in 0..<min(count, samples.count) {
                mix[i] += samples[i] * gain
            }
            if source.finished && samples.count < count {
                let ended = lock.withLock { () -> Bool in
                    guard file === source else { return false }
                    file = nil
                    return true
                }
                if ended {
                    let url = source.url
                    DispatchQueue.main.async { [weak self] in self?.fileFinished?(url) }
                }
            }
        }
        return mix.map { Int16(max(-32768, min(32767, ($0 * 32767).rounded()))) }
    }
}

/// Live sources of the TeamTalk library's media file stream, by number:
/// the library calls `liveAudioRead` with the number as its context.
enum LiveMediaSources {
    private static let lock = NSLock()
    private static var mixers = [Int: ChannelMixer]()
    private static var next = 1

    /// Registers `mixer`; returns the "file" name to stream.
    static func add(_ mixer: ChannelMixer) -> (id: Int, path: String) {
        let id = lock.withLock { () -> Int in
            let id = next
            next += 1
            mixers[id] = mixer
            return id
        }
        let name = "teamtalkng-\(id)"
        TTNG_SetLiveAudioSource(name, Int32(mixer.sampleRate), Int32(mixer.channels), liveAudioRead,
                                UnsafeMutableRawPointer(bitPattern: id))
        return (id, "ttnglive:" + name)
    }

    static func remove(_ id: Int) {
        TTNG_RemoveLiveAudioSource("teamtalkng-\(id)")
        _ = lock.withLock { mixers.removeValue(forKey: id) }
    }

    fileprivate static func mixer(_ id: Int) -> ChannelMixer? {
        lock.withLock { mixers[id] }
    }
}

/// Called by the TeamTalk library on its streaming thread.
private let liveAudioRead: TTNGLiveAudioRead = { context, buffer, frames in
    guard let buffer, frames > 0,
          let mixer = LiveMediaSources.mixer(Int(bitPattern: context)) else { return 0 }
    let samples = mixer.pull(frames: Int(frames))
    samples.withUnsafeBufferPointer { source in
        buffer.update(from: source.baseAddress!, count: min(source.count, Int(frames) * mixer.channels))
    }
    return frames
}
