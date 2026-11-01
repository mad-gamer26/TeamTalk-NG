/*
 * Recording conversations, like TeamTalk for Windows and macOS: the channel's
 * audio into one file (everyone's voice mixed, and media files streamed in the
 * channel unless turned off), and/or a separate file for each person.
 *
 * A channel can forbid recording; then only users with the right to record
 * voice in all channels, or administrators, may. While recording is on it
 * follows the session: joining another channel starts new files there, and
 * after a lost connection it starts again once a channel is joined.
 */
package com.matthewdovi.teamtalkng

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import dk.bearware.AudioFileFormat
import dk.bearware.Channel
import dk.bearware.ChannelType
import dk.bearware.Codec
import dk.bearware.IntPtr
import dk.bearware.MediaFileInfo
import dk.bearware.MediaFileStatus
import dk.bearware.StreamType
import dk.bearware.User
import dk.bearware.UserRight
import dk.bearware.UserType
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class RecordingChoices(val channelFile: Boolean, val userFiles: Boolean, val mediaFiles: Boolean) {
    companion object {
        val current get() = RecordingChoices(
            Prefs.on(PREF_RECORD_CHANNEL_FILE), Prefs.on(PREF_RECORD_USER_FILES, false), Prefs.on(PREF_RECORD_MEDIA_FILES),
        )
    }
}

/** The phone's copy of a recording folder, which other apps reach through Share. */
fun recordingsDirectory(): File {
    val context = TeamTalkApp.context
    return File(context.getExternalFilesDir(null) ?: context.filesDir, "Recordings").apply { mkdirs() }
}

class ChannelRecorder(private val session: ServerSession) {
    var wanted by mutableStateOf(false)
        private set
    var channelID by mutableStateOf(0)
        private set
    var channelName by mutableStateOf("")
        private set
    var since by mutableStateOf<Date?>(null)
        private set
    var channelFile by mutableStateOf<File?>(null)
        private set
    var userFolder by mutableStateOf<File?>(null)
        private set
    private var codecFormat = ""
    private val recordedUsers = mutableSetOf<Int>()
    private val tt get() = session.tt

    val isRecording get() = channelFile != null || userFolder != null

    /** Why this channel cannot be recorded by this user, in words. */
    fun problem(): String? {
        val channel = Channel()
        if (!tt.getChannel(tt.myChannelID, channel)) return null
        return if (allowed(channel)) null else "This channel does not allow recording."
    }

    /** Starts recording the channel this user is in; says why it could not. */
    fun start(): String? {
        val choices = RecordingChoices.current
        if (!choices.channelFile && !choices.userFiles) {
            return "Choose what to record: one file for the channel, a file for each person, or both."
        }
        val channel = tt.myChannelID
        if (channel <= 0) return "Join a channel to record it."
        wanted = true
        begin(channel)?.let {
            wanted = false
            return it
        }
        announce("Recording started.")
        return null
    }

    fun stop() {
        if (!wanted && !isRecording) return
        wanted = false
        val had = isRecording
        end()
        if (had) announce("Recording stopped. It is under Recordings on the Record screen.")
    }

    fun joinedChannel(id: Int) {
        if (!wanted || id == channelID) return
        end()
        val error = begin(id)
        if (error != null) {
            wanted = false
            announce(error)
        } else announce("Recording $channelName.")
    }

    fun leftChannel() = end()
    fun connectionLost() = end()

    fun userJoined(user: User) {
        if (userFolder == null || user.nChannelID != channelID) return
        storeUser(if (user.nUserID == tt.myUserID) 0 else user.nUserID)
    }

    fun userLeft(user: User) {
        if (recordedUsers.remove(user.nUserID)) tt.setUserMediaStorageDir(user.nUserID, "", "", AudioFileFormat.AFF_NONE)
    }

    fun channelUpdated(channel: Channel) {
        if (!isRecording || channel.nChannelID != channelID) return
        if (!allowed(channel)) {
            wanted = false
            end()
            announce("Recording stopped: this channel no longer allows recording.")
            return
        }
        if (format(channel) != codecFormat) {
            end()
            begin(channel.nChannelID)?.let {
                wanted = false
                announce(it)
            }
        }
    }

    fun recordingEvent(userID: Int, info: MediaFileInfo) {
        if (info.nStatus != MediaFileStatus.MFS_ERROR) return
        val user = User()
        val who = if (userID == 0 || !tt.getUser(userID, user)) "your" else "${user.szNickname}'s"
        announce("Could not record $who audio.")
    }

    private fun allowed(channel: Channel): Boolean =
        channel.uChannelType and ChannelType.CHANNEL_NO_RECORDING == 0 ||
            session.myRights and UserRight.USERRIGHT_RECORD_VOICE != 0 ||
            session.myType and UserType.USERTYPE_ADMIN != 0

    private fun begin(id: Int): String? {
        val channel = Channel()
        if (!tt.getChannel(id, channel)) return "The channel could not be found."
        if (!allowed(channel)) return "This channel does not allow recording."
        val choices = RecordingChoices.current
        channelName = channel.szName.orEmpty().ifEmpty { session.displayName }
        val folder = recordingsDirectory()
        val stamp = SimpleDateFormat("yyyy-MM-dd HH.mm.ss", Locale.US).format(Date())
        val base = safe("$stamp ${session.displayName} - $channelName")
        codecFormat = format(channel)

        if (choices.channelFile) {
            if (channel.audiocodec.nCodec == Codec.NO_CODEC) return "This channel has no audio to record."
            val file = File(folder, "$base.wav")
            var streams = StreamType.STREAMTYPE_VOICE
            if (choices.mediaFiles) streams = streams or StreamType.STREAMTYPE_MEDIAFILE_AUDIO
            if (!tt.startRecordingMuxedStreams(streams, channel.audiocodec, file.path, AudioFileFormat.AFF_WAVE_FORMAT)) {
                return "TeamTalk could not start recording the channel to a file."
            }
            channelFile = file
        }
        if (choices.userFiles) {
            val users = File(folder, base)
            if (!users.mkdirs() && !users.isDirectory) {
                end()
                return "The folder for each person's files could not be made."
            }
            userFolder = users
            val me = tt.myUserID
            channelUsers(id).forEach { storeUser(if (it.nUserID == me) 0 else it.nUserID) }
            if (0 !in recordedUsers) storeUser(0)
        }
        channelID = id
        since = Date()
        return null
    }

    private fun storeUser(id: Int) {
        val folder = userFolder ?: return
        if (tt.setUserMediaStorageDir(id, folder.path, "%Y%m%d-%H%M%S %nickname%", AudioFileFormat.AFF_WAVE_FORMAT)) {
            recordedUsers.add(id)
        }
    }

    private fun end() {
        if (channelFile != null) tt.stopRecordingMuxedAudioFile()
        recordedUsers.forEach { tt.setUserMediaStorageDir(it, "", "", AudioFileFormat.AFF_NONE) }
        recordedUsers.clear()
        channelFile = null
        userFolder = null
        channelID = 0
        since = null
    }

    private fun channelUsers(channel: Int): List<User> {
        val count = IntPtr()
        if (!tt.getChannelUsers(channel, null, count) || count.value <= 0) return emptyList()
        val users = arrayOfNulls<User>(count.value)
        for (i in users.indices) users[i] = User()
        return if (tt.getChannelUsers(channel, users, count)) users.filterNotNull().take(count.value) else emptyList()
    }

    private fun format(channel: Channel): String {
        val c = channel.audiocodec
        return when (c.nCodec) {
            Codec.OPUS_CODEC -> "opus ${c.opus.nSampleRate} ${c.opus.nChannels}"
            Codec.SPEEX_CODEC -> "speex ${c.speex.nBandmode}"
            Codec.SPEEX_VBR_CODEC -> "speex ${c.speex_vbr.nBandmode}"
            else -> c.nCodec.toString()
        }
    }

    private fun safe(name: String) =
        name.map { if (it in "/\\:?%*|\"<>" || it.isISOControl()) ' ' else it }.joinToString("").trim().take(120)
}
