/*
 * What goes to the channel besides the microphone: audio files and AudioNet.
 *
 * A file the TeamTalk library can open is streamed by it, as TeamTalk's media
 * file stream (others see and control it as a media file; the microphone stays
 * on), which needs the right to stream media files. AudioNet, a mix of it with
 * a file, or a file only Android can open go through the mixer. It reaches the
 * library as a live media file stream (LiveMediaServer), as on the iPhone. Where
 * that can't start, it goes through TT_InsertAudioBlock as voice, and the
 * microphone is off meanwhile.
 */
package com.matthewdovi.teamtalkng

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import dk.bearware.AudioBlock
import dk.bearware.AudioPreprocessor
import dk.bearware.AudioPreprocessorType
import dk.bearware.Channel
import dk.bearware.ClientFlag
import dk.bearware.Codec
import dk.bearware.MediaFileInfo
import dk.bearware.MediaFilePlayback
import dk.bearware.MediaFilePlaybackConstants
import dk.bearware.MediaFileStatus
import dk.bearware.SoundLevel
import dk.bearware.StreamType
import dk.bearware.Subscription
import dk.bearware.TeamTalkBase
import dk.bearware.User
import dk.bearware.UserRight
import dk.bearware.VideoCodec
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

private const val TAG = "Streaming"

class AudioBlockFormat(val sampleRate: Int, val channels: Int, val txIntervalMSec: Int)

/** Live sound the mixer reads from (AudioNet's tap, or nothing). */
fun interface LiveAudio {
    /** Interleaved 16-bit samples, up to `frames` of them. */
    fun read(frames: Int): ShortArray
}

/** Samples between the decoding thread and the sending thread. */
private class SampleRing(capacity: Int) {
    private val samples = FloatArray(capacity)
    private val lock = Object()
    private var start = 0
    private var size = 0
    private var cancelled = false

    /** Adds all of [from], waiting while full; false when cancelled. */
    fun write(from: FloatArray): Boolean {
        var done = 0
        synchronized(lock) {
            while (done < from.size) {
                while (size == samples.size && !cancelled) lock.wait()
                if (cancelled) return false
                val n = min(min(from.size - done, samples.size - size), samples.size - (start + size) % samples.size)
                System.arraycopy(from, done, samples, (start + size) % samples.size, n)
                size += n
                done += n
            }
        }
        return true
    }

    /** Takes up to [count] samples into [into] without waiting. */
    fun read(into: FloatArray, count: Int): Int = synchronized(lock) {
        val wanted = min(count, size)
        var done = 0
        while (done < wanted) {
            val n = min(wanted - done, samples.size - start)
            System.arraycopy(samples, start, into, done, n)
            start = (start + n) % samples.size
            done += n
        }
        size -= wanted
        if (wanted > 0) lock.notifyAll()
        wanted
    }

    fun cancel() = synchronized(lock) {
        cancelled = true
        lock.notifyAll()
    }
}

/**
 * An audio file decoded by Android at the mixer's format. Decoding has its own
 * thread and a few seconds of buffer, because the sending thread has a deadline
 * every few milliseconds and the decoder takes as long as it takes.
 */
class MixerFileSource(val file: File, private val sampleRate: Int, private val channels: Int, offsetMSec: Int = 0) {
    private val extractor = MediaExtractor()
    private val codec: MediaCodec
    private val inRate: Int
    private val inChannels: Int
    private var inputDone = false
    /** The next output frame's place in the source, for resampling. */
    private var position = 0.0
    private var carry = FloatArray(0)
    private val ring = SampleRing(sampleRate * channels * BUFFER_SECONDS)
    @Volatile private var decoded = false
    @Volatile private var closed = false
    /** Starts over at the end of the file, without a gap. */
    @Volatile var loop = false
    var finished = false
        private set
    private val decoder: Thread

    init {
        extractor.setDataSource(file.path)
        val track = (0 until extractor.trackCount).firstOrNull {
            extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
        } ?: throw IllegalArgumentException("There is no audio in this file.")
        extractor.selectTrack(track)
        val format = extractor.getTrackFormat(track)
        inRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        inChannels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
        codec.configure(format, null, null, 0)
        codec.start()
        if (offsetMSec > 0) extractor.seekTo(offsetMSec * 1000L, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
        decoder = thread(name = "FileDecoder", isDaemon = true) {
            Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
            runCatching { decode() }.onFailure { Log.w(TAG, "Decoding ${file.name} stopped: ${it.message}") }
            decoded = true
            runCatching { codec.stop() }
            runCatching { codec.release() }
            extractor.release()
        }
    }

    private fun decode() {
        while (!closed) {
            val block = nextBlock()
            if (block == null) {
                if (!loop) return
                extractor.seekTo(0, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                codec.flush()
                inputDone = false
                continue
            }
            if (!ring.write(block)) return
        }
    }

    fun close() {
        closed = true
        ring.cancel()
    }

    /**
     * Up to [count] samples into [into]. Fewer means the decoder is behind, or,
     * once [finished], that the file has ended.
     */
    fun read(into: FloatArray, count: Int): Int {
        val got = ring.read(into, count)
        if (got < count && decoded) finished = true
        return got
    }

    /** The next decoded audio at the output format; null at the end. */
    private fun nextBlock(): FloatArray? {
        val info = MediaCodec.BufferInfo()
        while (!closed) {
            if (!inputDone) {
                val index = codec.dequeueInputBuffer(5000)
                if (index >= 0) {
                    val size = extractor.readSampleData(codec.getInputBuffer(index)!!, 0)
                    if (size < 0) {
                        codec.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputDone = true
                    } else {
                        codec.queueInputBuffer(index, 0, size, extractor.sampleTime, 0)
                        extractor.advance()
                    }
                }
            }
            val index = codec.dequeueOutputBuffer(info, 5000)
            if (index >= 0) {
                val end = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                val data = if (info.size > 0) convert(codec.getOutputBuffer(index)!!, info) else null
                codec.releaseOutputBuffer(index, false)
                if (data != null && data.isNotEmpty()) return data
                if (end) return null
            }
        }
        return null
    }

    private fun convert(buffer: ByteBuffer, info: MediaCodec.BufferInfo): FloatArray {
        buffer.position(info.offset)
        buffer.limit(info.offset + info.size)
        val shorts = buffer.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        val inFrames = shorts.remaining() / inChannels
        // Channels by hand: mono is the average, stereo is left and right (a
        // mono file on both; further channels left out).
        val mixed = FloatArray(inFrames * channels)
        for (f in 0 until inFrames) {
            for (c in 0 until channels) {
                mixed[f * channels + c] = if (channels == 1) {
                    val used = min(inChannels, 2)
                    var sum = 0f
                    for (i in 0 until used) sum += shorts.get(f * inChannels + i) / 32768f
                    sum / used
                } else shorts.get(f * inChannels + min(c, inChannels - 1)) / 32768f
            }
        }
        if (inRate == sampleRate) return mixed
        // Linear resampling, carrying the last frame into the next block.
        val joined = carry + mixed
        val totalFrames = joined.size / channels
        val step = inRate.toDouble() / sampleRate
        val capacity = ((totalFrames - position) / step).toInt() + 2
        val out = FloatArray(max(0, capacity) * channels)
        var n = 0
        while (position + 1 < totalFrames && (n + 1) * channels <= out.size) {
            val i = position.toInt()
            val t = (position - i).toFloat()
            for (c in 0 until channels) {
                out[n * channels + c] = joined[i * channels + c] * (1 - t) + joined[(i + 1) * channels + c] * t
            }
            n++
            position += step
        }
        val keepFrom = min(position.toInt(), totalFrames - 1)
        carry = joined.copyOfRange(keepFrom * channels, joined.size)
        position -= keepFrom
        return out.copyOf(n * channels)
    }

    private companion object {
        const val BUFFER_SECONDS = 2
    }
}

/** Mixes the AudioNet sound and an audio file. Read on the sending thread. */
class ChannelMixer(val sampleRate: Int, val channels: Int) {
    private val lock = Any()
    private var live: LiveAudio? = null
    private var file: MixerFileSource? = null
    private var filePaused = false
    private var fileGain = 1f
    private var netGain = 1f
    private var loop = false
    /** The file has played to its end (on the main thread). */
    var fileFinished: (File) -> Unit = {}
    private val main = Handler(Looper.getMainLooper())

    val hasAudioNet get() = synchronized(lock) { live != null }
    val hasFile get() = synchronized(lock) { file != null }
    val isFilePaused get() = synchronized(lock) { filePaused }
    val fileUrl get() = synchronized(lock) { file?.file }

    fun setAudioNet(tap: LiveAudio?) = synchronized(lock) { live = tap }
    fun setFile(source: MixerFileSource?, paused: Boolean = false) {
        val old = synchronized(lock) {
            val previous = file
            file = source
            filePaused = paused
            previous
        }
        if (old !== source) old?.close()
    }
    fun setFilePaused(paused: Boolean) = synchronized(lock) { filePaused = paused }
    fun setLoop(value: Boolean) = synchronized(lock) { loop = value }
    fun setGains(filePercent: Double, audioNetPercent: Double) {
        val unchanged = SoundLevel.SOUND_GAIN_DEFAULT.toFloat()
        synchronized(lock) {
            fileGain = refVolume(filePercent) / unchanged
            netGain = refVolume(audioNetPercent) / unchanged
        }
    }

    private var mix = FloatArray(0)
    private var fileSamples = FloatArray(0)

    /** The next `frames` frames of interleaved 16-bit samples. */
    fun pull(frames: Int): ShortArray = ShortArray(frames * channels).also { pullInto(it) }

    /** Fills [out], without allocating when nothing changes: this runs many times a second. */
    fun pullInto(out: ShortArray) {
        val count = out.size
        if (mix.size != count) {
            mix = FloatArray(count)
            fileSamples = FloatArray(count)
        }
        val mix = mix
        java.util.Arrays.fill(mix, 0f)
        // The tap's read is the only thing here that may take a moment.
        val tap = synchronized(lock) { live }
        val net = tap?.read(count / channels)
        synchronized(lock) {
            if (net != null) {
                val gain = netGain
                for (i in 0 until min(count, net.size)) mix[i] += net[i] / 32768f * gain
            }
            val source = file
            if (source != null && !filePaused) {
                source.loop = loop
                val got = source.read(fileSamples, count)
                val gain = fileGain
                for (i in 0 until got) mix[i] += fileSamples[i] * gain
                if (source.finished) {
                    file = null
                    val done = source.file
                    source.close()
                    main.post { fileFinished(done) }
                }
            }
        }
        for (i in 0 until count) {
            val v = (mix[i] * 32767f).roundToInt()
            out[i] = (if (v > 32767) 32767 else if (v < -32768) -32768 else v).toShort()
        }
    }

    fun close() {
        setAudioNet(null)
        setFile(null)
    }
}

/** Sends live sound block by block at the channel's transmit interval, until stopped. */
class AudioBlockStreamer(
    private val tt: TeamTalkBase,
    private val format: AudioBlockFormat,
    private val read: (Int) -> ShortArray,
    private val finished: (Throwable?) -> Unit,
) {
    private val stopped = AtomicBoolean(false)
    private val paused = AtomicBoolean(false)
    private val streamID = (1..Int.MAX_VALUE).random()
    private val main = Handler(Looper.getMainLooper())
    val isActive get() = !stopped.get()
    val isPaused get() = paused.get()

    private var thread: Thread? = null

    fun start() {
        thread = Thread({
            var problem: Throwable? = null
            try {
                run()
            } catch (e: Exception) {
                problem = e
            }
            endBlock()
            stopped.set(true)
            main.post { finished(problem) }
        }, "AudioBlockStreamer").also { it.start() }
    }

    fun stop() {
        stopped.set(true)
        // The TeamTalk instance may be closed next, which this thread must not outlive.
        runCatching { thread?.join(1000) }
    }

    /** Ends the inserted stream: the SDK's wrapper takes no null, so an empty block says it. */
    private fun endBlock() {
        val block = AudioBlock()
        block.nStreamID = streamID
        block.nSampleRate = format.sampleRate
        block.nChannels = format.channels
        block.lpRawAudio = ByteArray(0)
        block.nSamples = 0
        block.uStreamTypes = StreamType.STREAMTYPE_VOICE
        runCatching { tt.insertAudioBlock(block) }
    }

    fun pause() {
        paused.set(true)
        endBlock()
    }

    fun resume() = paused.set(false)

    private fun run() {
        val framesPerBlock = max(1, format.sampleRate * format.txIntervalMSec / 1000)
        val intervalNanos = max(1, format.txIntervalMSec) * 1_000_000L
        val prebuffer = 3
        val silence = ShortArray(framesPerBlock * format.channels)
        repeat(prebuffer) { if (!stopped.get()) insert(silence, framesPerBlock) }
        var next = System.nanoTime() + intervalNanos
        var wasPaused = false
        while (!stopped.get()) {
            val now = System.nanoTime()
            if (next > now) Thread.sleep((next - now) / 1_000_000, ((next - now) % 1_000_000).toInt())
            if (stopped.get()) break
            val block = read(framesPerBlock)
            if (paused.get()) {
                // Keeps reading, so resuming sends what is live then.
                wasPaused = true
            } else {
                if (wasPaused) {
                    wasPaused = false
                    repeat(prebuffer) { if (!stopped.get()) insert(silence, framesPerBlock) }
                }
                insert(block, framesPerBlock)
            }
            next += intervalNanos
            val after = System.nanoTime()
            // A long stall: start the pace again rather than rushing to catch up.
            if (after > next + intervalNanos * 4) next = after + intervalNanos
        }
    }

    private fun insert(samples: ShortArray, frames: Int) {
        val raw = ByteArray(samples.size * 2)
        ByteBuffer.wrap(raw).order(ByteOrder.nativeOrder()).asShortBuffer().put(samples)
        while (!stopped.get()) {
            val block = AudioBlock()
            block.nStreamID = streamID
            block.nSampleRate = format.sampleRate
            block.nChannels = format.channels
            block.lpRawAudio = raw
            block.nSamples = frames
            block.uSampleIndex = 0
            block.uStreamTypes = StreamType.STREAMTYPE_VOICE
            if (tt.insertAudioBlock(block)) return
            Thread.sleep(5)
        }
    }
}

/**
 * Live sound as something the library can stream: an endless
 * WAV over HTTP, which its FFmpeg reads like any media file. This is what the
 * iPhone app's patched "ttnglive:" source does. It listens on this phone's
 * loopback address only, at a path nothing else can guess.
 *
 * The library opens a file once to look at it and again to stream it, so only
 * the newest connection takes sound from the mixer.
 */
class LiveMediaServer(private val format: AudioBlockFormat, private val fill: (ShortArray) -> Unit) {
    private val listener = ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"))
    private val token = UUID.randomUUID().toString()
    private val newest = AtomicInteger(0)
    @Volatile private var closed = false
    /** How much the library has sent to the channel. */
    @Volatile var playedMSec = -1L

    val url = "http://127.0.0.1:${listener.localPort}/$token.wav"

    fun start() {
        thread(name = "LiveMedia", isDaemon = true) {
            while (!closed) {
                val client = try { listener.accept() } catch (_: IOException) { break }
                val id = newest.incrementAndGet()
                thread(name = "LiveMedia-$id", isDaemon = true) {
                    runCatching { client.use { serve(it, id) } }
                }
            }
        }
    }

    fun close() {
        closed = true
        runCatching { listener.close() }
    }

    private fun serve(client: Socket, id: Int) {
        client.tcpNoDelay = true
        val request = client.getInputStream().bufferedReader(Charsets.ISO_8859_1)
        val first = request.readLine().orEmpty()
        while (!request.readLine().isNullOrEmpty()) { /* the headers */ }
        val out = client.getOutputStream()
        if (!first.contains("/$token.wav")) {
            out.write("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n".toByteArray())
            return
        }
        out.write("HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nConnection: close\r\n\r\n".toByteArray())
        out.write(wavHeader())
        // The library keeps this much ahead of real time, which is what covers
        // a late block. A newer connection is the one that streams, so this also
        // lets the library look at the file without waiting.
        out.write(ByteArray((format.sampleRate * LIVE_LEAD_MSEC / 1000).toInt() * format.channels * 2))
        out.flush()
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)

        val frames = max(1, (format.sampleRate * LIVE_BLOCK_MSEC / 1000).toInt())
        val blockNanos = LIVE_BLOCK_MSEC * 1_000_000L
        val samples = ShortArray(frames * format.channels)
        val bytes = ByteBuffer.allocate(samples.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        val shorts = bytes.asShortBuffer()
        val started = System.nanoTime()
        var next = started
        var written = LIVE_LEAD_MSEC
        var lowest = Long.MAX_VALUE
        var checked = started
        var catchingUp = false
        while (!closed && newest.get() == id) {
            fill(samples)
            // The library starts reading some time after it connects, and what
            // was sent meanwhile would stay as delay. So how far this is ahead
            // of what has played decides: too far, and the sound goes unsent
            // until it's back to the lead.
            val played = playedMSec
            val ahead = if (played >= 0) written - played else LIVE_LEAD_MSEC
            if (ahead > LIVE_LEAD_MSEC + LIVE_SLACK_MSEC) catchingUp = true else if (ahead <= LIVE_LEAD_MSEC) catchingUp = false
            if (!catchingUp) {
                shorts.clear()
                shorts.put(samples)
                out.write(bytes.array())
                out.flush()
                written += LIVE_BLOCK_MSEC
            }
            next += blockNanos
            val now = System.nanoTime()
            // Run out, and listeners hear a gap.
            if (played >= 0) lowest = min(lowest, ahead)
            if (now - checked > 10_000_000_000L) {
                Log.i(TAG, "Live stream over the last 10 s: at least $lowest msec ahead of what's playing, now $ahead")
                lowest = Long.MAX_VALUE
                checked = now
            }
            val wait = next - now
            when {
                wait > 0 -> Thread.sleep(wait / 1_000_000, (wait % 1_000_000).toInt())
                // Late: the next blocks follow at once and win the lead back.
                // Only after a long stall is that time given up.
                wait < -CATCH_UP_LIMIT_NANOS -> next = System.nanoTime()
            }
        }
    }

    /** A 16-bit PCM header with the sizes that mean "no end". */
    private fun wavHeader(): ByteArray {
        val endless = -1
        return ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray()); putInt(endless); put("WAVEfmt ".toByteArray()); putInt(16)
            putShort(1); putShort(format.channels.toShort()); putInt(format.sampleRate)
            putInt(format.sampleRate * format.channels * 2)
            putShort((format.channels * 2).toShort()); putShort(16)
            put("data".toByteArray()); putInt(endless)
        }.array()
    }

    private companion object {
        const val LIVE_BLOCK_MSEC = 40L
        const val LIVE_LEAD_MSEC = 500L
        const val LIVE_SLACK_MSEC = 250L
        const val CATCH_UP_LIMIT_NANOS = 2_000_000_000L
    }
}

/** A session's audio files and AudioNet stream. */
class ChannelStreaming(private val session: ServerSession) {
    private val tt get() = session.tt

    var officialFile by mutableStateOf<File?>(null)
        private set
    private var officialPaused by mutableStateOf(false)
    private var officialElapsed = 0
    /** The library has sent some of the file. */
    private var officialProgressed = false
    private var officialStartedAt = 0L

    var mixer by mutableStateOf<ChannelMixer?>(null)
        private set
    private var mixPaused = false
    private var streamer by mutableStateOf<AudioBlockStreamer?>(null)
    /** The mix going out as a media file stream, which leaves the microphone alone. */
    private var liveMedia: LiveMediaServer? = null
    private var wasVoiceTransmitting = false
    private var enabledOwnVoiceSubscription = false
    private var ownUserID = 0
    private val generation = AtomicReference<Any?>(null)

    private val hasMediaFileRight get() = session.myRights and UserRight.USERRIGHT_TRANSMIT_MEDIAFILE_AUDIO != 0
    private val hasVoiceRight get() = session.myRights and UserRight.USERRIGHT_TRANSMIT_VOICE != 0
    private val channelHasAudio get() = session.channelSupportsAudio(session.myChannel)

    /** Audio files need the right to stream media files. */
    fun canStreamAudioFiles() = channelHasAudio && hasMediaFileRight
    /** AudioNet goes out as a media file stream, or as voice where that isn't allowed. */
    fun canSendAudioNet() = channelHasAudio && (hasMediaFileRight || hasVoiceRight)
    fun audioBlockStreamingActive() = streamer?.isActive == true

    val isStreamingFile: Boolean get() = officialFile != null || mixer?.hasFile == true
    val isFilePaused: Boolean
        get() = if (officialFile != null) officialPaused else mixer?.hasFile == true && mixer?.isFilePaused == true

    val loops get() = Prefs.on(PREF_STREAM_LOOP, false)

    fun setLoops(value: Boolean) {
        Prefs.set(PREF_STREAM_LOOP, value)
        mixer?.setLoop(value)
    }

    fun setFileVolume(percent: Double) {
        Prefs.set(PREF_STREAM_FILE_VOLUME, percent.toFloat())
        if (officialFile != null) updateMediaStream(officialPaused, filePreprocessor())
        applyGains()
    }

    fun setAudioNetVolume(percent: Double) {
        Prefs.set(PREF_STREAM_AUDIONET_VOLUME, percent.toFloat())
        applyGains()
    }

    private fun applyGains() {
        mixer?.setGains(streamVolumePercent(PREF_STREAM_FILE_VOLUME), streamVolumePercent(PREF_STREAM_AUDIONET_VOLUME))
    }

    /** Starts streaming a temporary copy of an audio file; returns an error in words. */
    fun streamFile(file: File): String? {
        if (!canStreamAudioFiles()) {
            file.delete()
            return "You do not have permission to stream audio files on this server."
        }
        mixer?.let { mixer ->
            // AudioNet is going out: the file joins it.
            return try {
                val source = MixerFileSource(file, mixer.sampleRate, mixer.channels)
                mixer.fileUrl?.delete()
                mixer.setFile(source)
                updateMixSink()
                session.refresh()
                null
            } catch (e: Exception) {
                file.delete()
                e.message ?: "This audio file could not be opened."
            }
        }
        if (startOfficial(file)) return null
        val error = startMix(file, 0, false, null)
        if (error != null) file.delete()
        return error
    }

    private fun playback(paused: Boolean, offset: Int, preprocessor: AudioPreprocessor) = MediaFilePlayback().apply {
        uOffsetMSec = offset
        bPaused = paused
        audioPreprocessor = preprocessor
    }

    private fun noVideo() = VideoCodec().apply { nCodec = Codec.NO_CODEC }

    /** A file the library streams gets its volume from TeamTalk's own gain. */
    private fun filePreprocessor() = AudioPreprocessor(AudioPreprocessorType.TEAMTALK_AUDIOPREPROCESSOR, true).apply {
        ttpreprocessor.nGainLevel = refVolume(streamVolumePercent(PREF_STREAM_FILE_VOLUME))
    }

    private fun startOfficial(file: File): Boolean {
        if (!hasMediaFileRight) return false
        val info = MediaFileInfo()
        if (!TeamTalkBase.getMediaFileInfo(file.path, info)) {
            Log.i(TAG, "The TeamTalk library cannot open this file; mixing it instead.")
            return false
        }
        if (!tt.startStreamingMediaFileToChannel(file.path, playback(false, 0, filePreprocessor()), noVideo())) {
            Log.w(TAG, "startStreamingMediaFileToChannel failed; mixing the file instead.")
            return false
        }
        officialPaused = false
        officialElapsed = 0
        officialProgressed = false
        officialStartedAt = System.currentTimeMillis()
        officialFile = file
        session.refresh()
        return true
    }

    private fun updateMediaStream(paused: Boolean, preprocessor: AudioPreprocessor): Boolean =
        tt.updateStreamingMediaFileToChannel(
            playback(paused, MediaFilePlaybackConstants.TT_MEDIAPLAYBACK_OFFSET_IGNORE, preprocessor), null,
        )

    private fun removeOfficialFile() {
        officialFile?.delete()
        officialFile = null
        officialPaused = false
    }

    /** Progress and end of the media file stream. */
    fun mediaFileEvent(info: MediaFileInfo) {
        liveMedia?.let { live ->
            if (info.szFileName == live.url) {
                live.playedMSec = info.uElapsedMSec.toLong()
                if (info.nStatus in listOf(MediaFileStatus.MFS_FINISHED, MediaFileStatus.MFS_ABORTED, MediaFileStatus.MFS_ERROR)) {
                    Log.w(TAG, "The live stream ended with status ${info.nStatus} after ${info.uElapsedMSec} msec.")
                    liveStreamEnded()
                }
                return
            }
        }
        val url = officialFile
        val ended = info.nStatus in listOf(MediaFileStatus.MFS_FINISHED, MediaFileStatus.MFS_ABORTED, MediaFileStatus.MFS_ERROR, MediaFileStatus.MFS_CLOSED)
        if (url != null && File(info.szFileName.orEmpty()).canonicalPath == url.canonicalPath) {
            officialElapsed = info.uElapsedMSec
            Log.i(TAG, "media file status ${info.nStatus}, ${info.uElapsedMSec} of ${info.uDurationMSec} msec")
            if (info.uElapsedMSec > 0) officialProgressed = true
            // A stream stopped to loop the file can report closing after the
            // new one started: only a stream that is gone has ended.
            val still = tt.flags and ClientFlag.CLIENT_STREAM_AUDIO != 0
            val earlierRun = System.currentTimeMillis() - officialStartedAt < 1000
            if (ended && !earlierRun && (info.nStatus == MediaFileStatus.MFS_FINISHED || !still)) {
                officialFileEnded(info.nStatus == MediaFileStatus.MFS_FINISHED)
            }
        }
        session.refresh()
    }

    fun checkOfficialFileStillStreaming() {
        if (officialFile != null && tt.flags and ClientFlag.CLIENT_STREAM_AUDIO == 0) officialFileEnded(true)
    }

    private fun officialFileEnded(finished: Boolean) {
        val url = officialFile ?: return
        if (!officialProgressed) {
            // The library took the file but sent none of it (it opens more
            // formats than it can decode here): Android decodes it instead.
            Log.i(TAG, "The library sent nothing of this file; mixing it instead.")
            officialFile = null
            officialPaused = false
            startMix(url, 0, false, null)?.let {
                url.delete()
                session.alert = SessionAlert("Audio File", it)
            }
            session.refresh()
            return
        }
        if (finished && loops) {
            tt.stopStreamingMediaFileToChannel()
            if (tt.startStreamingMediaFileToChannel(url.path, playback(false, 0, filePreprocessor()), noVideo())) {
                officialPaused = false
                officialElapsed = 0
                officialStartedAt = System.currentTimeMillis()
                session.refresh()
                return
            }
        }
        removeOfficialFile()
        session.refresh()
    }

    /** Starts sending a mix of AudioNet and a file; returns an error in words. */
    private fun startMix(file: File?, offsetMSec: Int, filePaused: Boolean, tap: LiveAudio?): String? {
        val format = channelFormat()
        val mix = ChannelMixer(format.sampleRate, format.channels)
        if (file != null) {
            try {
                mix.setFile(MixerFileSource(file, format.sampleRate, format.channels, offsetMSec), filePaused)
            } catch (e: Exception) {
                return e.message ?: "This audio file could not be opened."
            }
        }
        mix.setAudioNet(tap)
        mix.setGains(streamVolumePercent(PREF_STREAM_FILE_VOLUME), streamVolumePercent(PREF_STREAM_AUDIONET_VOLUME))
        mix.setLoop(loops)
        mix.fileFinished = { mixedFileFinished(it) }
        mixer = mix
        mixPaused = false

        if (!startLiveMedia(mix, format)) {
            Log.w(TAG, "The live media stream could not start; sending the mix as voice.")
            startVoiceSink(mix, format)
        }
        updateMixSink()
        session.refresh()
        return null
    }

    /** The mix as a media file stream, the way the iPhone app sends it. */
    private fun startLiveMedia(mix: ChannelMixer, format: AudioBlockFormat): Boolean {
        if (!hasMediaFileRight) return false
        val live = try {
            LiveMediaServer(format, mix::pullInto)
        } catch (e: IOException) {
            Log.w(TAG, "No live media server: ${e.message}")
            return false
        }
        live.start()
        val none = AudioPreprocessor().apply { nPreprocessor = AudioPreprocessorType.NO_AUDIOPREPROCESSOR }
        if (!tt.startStreamingMediaFileToChannel(live.url, playback(false, 0, none), noVideo())) {
            live.close()
            return false
        }
        liveMedia = live
        return true
    }

    /** The library stopped reading the live stream: carry on as voice if allowed. */
    private fun liveStreamEnded() {
        val mix = mixer ?: return
        liveMedia?.close()
        liveMedia = null
        tt.stopStreamingMediaFileToChannel()
        if (hasVoiceRight) {
            startVoiceSink(mix, AudioBlockFormat(mix.sampleRate, mix.channels, channelFormat().txIntervalMSec))
        } else {
            if (mix.hasAudioNet) AudioNetBridge.stopSending()
            stopMix()
            session.alert = SessionAlert("Audio File", "Sending to the channel stopped.")
        }
        session.refresh()
    }

    /** The mix as voice: the microphone is off meanwhile. */
    private fun startVoiceSink(mix: ChannelMixer, format: AudioBlockFormat) {
        wasVoiceTransmitting = session.isTransmitting
        configureOwnVoiceSubscription()
        if (wasVoiceTransmitting) session.enableVoiceTx(false, playToggleSound = false)
        val token = Any()
        generation.set(token)
        val s = AudioBlockStreamer(tt, format, mix::pull) { problem -> blockStreamFinished(token, problem) }
        streamer = s
        s.start()
    }

    /** The mix pauses only when it is a paused file alone. */
    private fun updateMixSink() {
        val mix = mixer ?: return
        val paused = !mix.hasAudioNet && mix.hasFile && mix.isFilePaused
        if (paused == mixPaused) return
        mixPaused = paused
        if (liveMedia != null) {
            val none = AudioPreprocessor().apply { nPreprocessor = AudioPreprocessorType.NO_AUDIOPREPROCESSOR }
            updateMediaStream(paused, none)
            return
        }
        val s = streamer ?: return
        if (paused) {
            s.pause()
            restoreAudioState(clearSavedState = false)
        } else {
            configureOwnVoiceSubscription()
            if (session.isTransmitting) session.enableVoiceTx(false, playToggleSound = false)
            s.resume()
        }
    }

    private fun stopMix() {
        val mix = mixer ?: return
        mixer = null
        liveMedia?.let {
            liveMedia = null
            tt.stopStreamingMediaFileToChannel()
            it.close()
        }
        streamer?.let {
            streamer = null
            generation.set(null)
            it.stop()
            restoreAudioState(clearSavedState = true)
        }
        val file = mix.fileUrl
        mix.close()
        file?.delete()
        mixPaused = false
        session.refresh()
    }

    private fun mixedFileFinished(file: File) {
        Log.i(TAG, "${file.name} finished in the mix")
        file.delete()
        mixer?.let { if (!it.hasAudioNet) stopMix() }
        session.refresh()
    }

    fun togglePause() {
        val paused = !isFilePaused
        if (officialFile != null) {
            if (!updateMediaStream(paused, filePreprocessor())) {
                session.alert = SessionAlert("Audio File", if (paused) "Could not pause the audio file." else "Could not resume the audio file.")
                return
            }
            officialPaused = paused
        } else {
            val mix = mixer ?: return
            if (!mix.hasFile) return
            mix.setFilePaused(paused)
            updateMixSink()
        }
        session.refresh()
    }

    fun stopFile() {
        if (officialFile != null) {
            if (!tt.stopStreamingMediaFileToChannel()) {
                session.alert = SessionAlert("Audio File", "Could not stop audio file streaming.")
                return
            }
            removeOfficialFile()
            session.refresh()
            return
        }
        val mix = mixer ?: return
        val file = mix.fileUrl ?: return
        mix.setFile(null)
        file.delete()
        if (!mix.hasAudioNet) stopMix() else updateMixSink()
        session.refresh()
    }

    private fun blockStreamFinished(token: Any, problem: Throwable?) {
        if (generation.get() !== token) return
        if (mixer?.hasAudioNet == true) AudioNetBridge.stopSending()
        stopMix()
        problem?.let { session.alert = SessionAlert("Audio File", it.message ?: "Sending to the channel stopped because of an error.") }
    }

    // AudioNet

    /** Sends a tap's sound into the channel, mixed with an audio file if one is streaming. */
    fun attachAudioNet(tap: LiveAudio): String? {
        mixer?.let {
            it.setAudioNet(tap)
            updateMixSink()
            session.refresh()
            return null
        }
        // A file the library is streaming continues in the mix, from where it is.
        val file = officialFile
        val offset = officialElapsed
        val paused = officialPaused
        if (file != null) {
            officialFile = null
            officialPaused = false
            tt.stopStreamingMediaFileToChannel()
        }
        val error = startMix(file, offset, paused, tap)
        if (error != null) file?.delete()
        return error
    }

    fun detachAudioNet() {
        val mix = mixer ?: return
        if (!mix.hasAudioNet) return
        mix.setAudioNet(null)
        if (mix.hasFile) updateMixSink() else stopMix()
        session.refresh()
    }

    /** The format of the channel's codec, for sending and for AudioNet's tap. */
    fun channelFormat(): AudioBlockFormat {
        val mix = mixer
        val base = channelCodecFormat(session.myChannel)
        return if (mix != null) AudioBlockFormat(mix.sampleRate, mix.channels, base.txIntervalMSec) else base
    }

    private fun channelCodecFormat(channel: Channel): AudioBlockFormat {
        val codec = channel.audiocodec
        fun speexRate(mode: Int) = when (mode) { 0 -> 8000; 2 -> 32000; else -> 16000 }
        return when (codec.nCodec) {
            Codec.OPUS_CODEC -> AudioBlockFormat(codec.opus.nSampleRate, codec.opus.nChannels.coerceIn(1, 2), max(20, codec.opus.nTxIntervalMSec))
            Codec.SPEEX_CODEC -> AudioBlockFormat(speexRate(codec.speex.nBandmode), 1, max(20, codec.speex.nTxIntervalMSec))
            Codec.SPEEX_VBR_CODEC -> AudioBlockFormat(speexRate(codec.speex_vbr.nBandmode), 1, max(20, codec.speex_vbr.nTxIntervalMSec))
            else -> AudioBlockFormat(48000, 1, 40)
        }
    }

    /** While sending, the server sends this user's own voice back so they hear what goes out. */
    private fun configureOwnVoiceSubscription() {
        ownUserID = session.myUserID
        enabledOwnVoiceSubscription = false
        // Recording: hearing it come back would record it twice.
        if (session.recorder.wanted || ownUserID <= 0) return
        val user = User()
        if (!tt.getUser(ownUserID, user)) return
        if (user.uLocalSubscriptions and Subscription.SUBSCRIBE_VOICE == 0) {
            tt.doSubscribe(ownUserID, Subscription.SUBSCRIBE_VOICE)
            enabledOwnVoiceSubscription = true
        }
    }

    private fun restoreAudioState(clearSavedState: Boolean) {
        if (enabledOwnVoiceSubscription && ownUserID > 0) tt.doUnsubscribe(ownUserID, Subscription.SUBSCRIBE_VOICE)
        enabledOwnVoiceSubscription = false
        if (clearSavedState) ownUserID = 0
        val restore = wasVoiceTransmitting
        if (clearSavedState) wasVoiceTransmitting = false
        // Inserted audio ends a moment after the last block; voice can't start before.
        if (restore) restoreVoice(0, onlyWhilePaused = !clearSavedState)
    }

    private fun restoreVoice(attempt: Int, onlyWhilePaused: Boolean) {
        if (onlyWhilePaused && streamer?.let { it.isActive && !it.isPaused } == true) return
        session.enableVoiceTx(true, playToggleSound = false)
        if (session.isTransmitting || attempt >= 5) return
        Handler(Looper.getMainLooper()).postDelayed({ restoreVoice(attempt + 1, onlyWhilePaused) }, 100)
    }

    fun close() {
        if (mixer?.hasAudioNet == true) AudioNetBridge.stopSending()
        stopMix()
        removeOfficialFile()
    }
}
