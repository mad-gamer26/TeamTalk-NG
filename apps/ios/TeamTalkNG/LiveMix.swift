import AVFoundation
import AudioNetKit
import Darwin
import Foundation

// What goes to the channel besides the microphone, mixed (the old app's
// mixing): an AudioNet sound and an audio file together, with their own
// volumes. It goes out as TeamTalk's media file stream, so the microphone
// stays on: the mix is written in real time, as a WAV, into a FIFO that the
// SDK streams like a file (BearWare's SDK as it is: nothing patched; the
// core doesn't probe a FIFO, so the SDK reads it once, from its header).

/// An audio file read in small pieces at the mix's format.
final class MixFile: @unchecked Sendable {
    let url: URL
    private let file: AVAudioFile
    private let mixed: AVAudioFormat
    private let output: AVAudioFormat
    private let converter: AVAudioConverter?
    private let inputChannels: Int
    private let outputChannels: Int
    private var pending: [Float] = []
    private(set) var finished = false

    init(url: URL, sampleRate: Double, channels: Int, offsetMs: UInt32 = 0) throws {
        self.url = url
        file = try AVAudioFile(forReading: url)
        let input = file.processingFormat
        inputChannels = Int(input.channelCount)
        outputChannels = channels
        // Channels are mixed here (a converter can make silence when
        // downmixing); the converter changes only the sample rate.
        guard let mixed = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: input.sampleRate,
                                        channels: AVAudioChannelCount(channels), interleaved: false),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels), interleaved: false)
        else { throw CocoaError(.fileReadCorruptFile) }
        self.mixed = mixed
        self.output = output
        converter = input.sampleRate == sampleRate ? nil : AVAudioConverter(from: mixed, to: output)
        if input.sampleRate != sampleRate, converter == nil { throw CocoaError(.fileReadUnsupportedScheme) }
        if offsetMs > 0 {
            file.framePosition = min(file.length, AVAudioFramePosition(Double(offsetMs) * input.sampleRate / 1000))
        }
    }

    var durationMs: UInt32 { UInt32(Double(file.length) / file.processingFormat.sampleRate * 1000) }

    func rewind() {
        file.framePosition = 0
        pending.removeAll()
        finished = false
    }

    /// Up to `frames` interleaved frames; fewer only at its end.
    func read(frames: Int) -> [Float] {
        let wanted = frames * outputChannels
        while pending.count < wanted, !finished {
            if let block = nextBlock(), !block.isEmpty { pending += block } else { finished = true }
        }
        let n = min(wanted, pending.count)
        let out = Array(pending[0..<n])
        pending.removeFirst(n)
        return out
    }

    /// About 100 ms, interleaved, at the mix's format; nil at the end.
    private func nextBlock() -> [Float]? {
        let inFrames = AVAudioFrameCount(max(1, file.processingFormat.sampleRate / 10))
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inFrames),
              (try? file.read(into: inBuf, frameCount: inFrames)) != nil, inBuf.frameLength > 0,
              let mixBuf = AVAudioPCMBuffer(pcmFormat: mixed, frameCapacity: inBuf.frameLength),
              let src = inBuf.floatChannelData, let dst = mixBuf.floatChannelData
        else { return nil }
        let length = Int(inBuf.frameLength)
        mixBuf.frameLength = inBuf.frameLength
        for c in 0..<outputChannels {
            for f in 0..<length {
                if outputChannels == 1 {
                    let used = min(inputChannels, 2)
                    var sum: Float = 0
                    for i in 0..<used { sum += src[i][f] }
                    dst[c][f] = sum / Float(used)
                } else {
                    dst[c][f] = src[min(c, inputChannels - 1)][f]
                }
            }
        }
        var result = mixBuf
        if let converter {
            let cap = AVAudioFrameCount(Double(length) * output.sampleRate / mixed.sampleRate) + 64
            guard let conv = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: cap) else { return nil }
            var given = false
            var error: NSError?
            converter.convert(to: conv, error: &error) { _, status in
                if given { status.pointee = .noDataNow; return nil }
                given = true
                status.pointee = .haveData
                return mixBuf
            }
            if error != nil { return nil }
            result = conv
        }
        guard let data = result.floatChannelData else { return nil }
        let count = Int(result.frameLength)
        var out = [Float](repeating: 0, count: count * outputChannels)
        for f in 0..<count {
            for c in 0..<outputChannels { out[f * outputChannels + c] = data[c][f] }
        }
        return out
    }
}

/// The desktop's volume curve as a gain (50: unchanged; 0: silent).
func mixGain(percent: Int) -> Float {
    guard percent > 0 else { return 0 }
    return Float((82.832 * exp(0.0508 * Double(percent)) - 50) / 1000)
}

/// Mixes the AudioNet sound and a file; pulled on the writer's thread,
/// changed on the main thread.
final class ChannelMix: @unchecked Sendable {
    static let sampleRate = 48000
    static let channels = 2

    private let lock = NSLock()
    private var tap: AudioTap?
    private var file: MixFile?
    private var filePaused = false
    private var loopFile = false
    private var fileGain: Float = 1
    private var audioNetGain: Float = 1
    /// The file played to its end (on the main thread).
    var fileFinished: (@MainActor (URL) -> Void)?

    var hasAudioNet: Bool { lock.withLock { tap != nil } }
    var hasFile: Bool { lock.withLock { file != nil } }
    var isEmpty: Bool { lock.withLock { tap == nil && file == nil } }
    var fileURL: URL? { lock.withLock { file?.url } }
    var isFilePaused: Bool { lock.withLock { filePaused } }

    func setAudioNet(_ t: AudioTap?) { lock.withLock { tap = t } }
    func setFile(_ f: MixFile?, loop: Bool) { lock.withLock { file = f; loopFile = loop; filePaused = false } }
    func setFilePaused(_ p: Bool) { lock.withLock { filePaused = p } }
    func setGains(file: Int, audioNet: Int) {
        lock.withLock { fileGain = mixGain(percent: file); audioNetGain = mixGain(percent: audioNet) }
    }

    /// The next `frames` frames, interleaved 16-bit.
    func pull(frames: Int) -> [Int16] {
        let n = frames * Self.channels
        var mix = [Float](repeating: 0, count: n)
        let (t, f, paused, loop, fg, ng) = lock.withLock { (tap, file, filePaused, loopFile, fileGain, audioNetGain) }
        if let t {
            let s = t.read(frames: UInt32(frames))
            for i in 0..<min(n, s.count) { mix[i] += Float(s[i]) / 32768 * ng }
        }
        if let f, !paused {
            var s = f.read(frames: frames)
            if loop, f.finished, s.count < n {
                f.rewind()
                s += f.read(frames: (n - s.count) / Self.channels)
            }
            for i in 0..<min(n, s.count) { mix[i] += s[i] * fg }
            if f.finished, s.count < n {
                let ended = lock.withLock { () -> Bool in
                    guard file === f else { return false }
                    file = nil
                    return true
                }
                if ended {
                    let url = f.url
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated { self?.fileFinished?(url) }
                    }
                }
            }
        }
        return mix.map { Int16(max(-32768, min(32767, ($0 * 32767).rounded()))) }
    }
}

/// The FIFO the SDK streams, written in real time from the mix: a WAV
/// header, then 20 ms blocks kept a little ahead. Closing it ends the
/// stream.
final class LiveFifo: @unchecked Sendable {
    let path: String
    private let mix: ChannelMix
    private let lock = NSLock()
    private var stopping = false
    private var fd: Int32 = -1

    init?(mix: ChannelMix) {
        self.mix = mix
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("live", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = dir.appendingPathComponent("mix-\(UUID().uuidString.prefix(8)).wav").path
        guard mkfifo(p, 0o600) == 0 else { return nil }
        path = p
    }

    /// Starts writing (the open waits for the SDK to open it to read).
    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "TeamTalk NG live mix"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        lock.withLock { stopping = true }
        // Unblock an open still waiting for its reader.
        let r = open(path, O_RDONLY | O_NONBLOCK)
        if r >= 0 { close(r) }
    }

    private var isStopping: Bool { lock.withLock { stopping } }

    private func run() {
        signal(SIGPIPE, SIG_IGN)
        let f = open(path, O_WRONLY)
        defer { if f >= 0 { close(f) }; unlink(path) }
        guard f >= 0, !isStopping else { return }
        guard write(all: Self.header(), to: f) else { return }
        let rate = ChannelMix.sampleRate, block = rate / 50
        let start = Date()
        var sent = 0
        while !isStopping {
            // 200 ms ahead of the wall clock at most.
            let due = Int((Date().timeIntervalSince(start) + 0.2) * Double(rate))
            if sent >= due { usleep(5000); continue }
            let samples = mix.pull(frames: block)
            let ok = samples.withUnsafeBytes { buf in write(all: Data(buf), to: f) }
            if !ok { return }
            sent += block
        }
    }

    private func write(all data: Data, to f: Int32) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(f, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }

    /// A WAV that never ends (its sizes as large as they go).
    private static func header() -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let rate = UInt32(ChannelMix.sampleRate), ch = UInt16(ChannelMix.channels)
        d.append(contentsOf: Array("RIFF".utf8)); u32(.max)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(ch)
        u32(rate); u32(rate * UInt32(ch) * 2); u16(ch * 2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(.max - 36)
        return d
    }
}
