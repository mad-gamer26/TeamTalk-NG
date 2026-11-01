/*
 * One connected server: the TeamTalk instance, its channels and users, and
 * what the user does there. Together with Streaming.kt it is the iPhone app's
 * MainTabBarController and ChannelListViewController. Runs on the main thread;
 * Compose screens read its state directly.
 */
package com.matthewdovi.teamtalkng

import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import dk.bearware.AudioCodec
import dk.bearware.AudioPreprocessor
import dk.bearware.AudioPreprocessorType
import dk.bearware.Channel
import dk.bearware.ClientError
import dk.bearware.ClientEvent
import dk.bearware.ClientFlag
import dk.bearware.Codec
import dk.bearware.EncryptionContext
import dk.bearware.RemoteFile
import dk.bearware.ServerProperties
import dk.bearware.SoundLevel
import dk.bearware.StreamType
import dk.bearware.Subscription
import dk.bearware.TTMessage
import dk.bearware.TeamTalk5
import dk.bearware.TextMessage
import dk.bearware.TextMsgType
import dk.bearware.User
import dk.bearware.UserAccount
import dk.bearware.UserRight
import dk.bearware.UserState
import dk.bearware.UserType
import dk.bearware.WebRTCConstants
import java.io.File
import java.text.DateFormat
import java.util.Date

enum class MsgType { PrivIm, PrivImMyself, ChanIm, ChanImMyself, LogMsg, Bcast }

data class MyTextMessage(
    val message: String,
    val msgtype: MsgType,
    val nickname: String = "",
    val fromUserID: Int = 0,
    val date: Date = Date(),
) {
    val time: String get() = DateFormat.getTimeInstance(DateFormat.SHORT).format(date)
}

enum class Command { Login, Join, Leave, Move, Kick, Ban }

/** An alert to show; [dismissed] runs when it is closed. */
class SessionAlert(val title: String, val message: String, val dismissed: () -> Unit = {})

sealed interface ChannelRow {
    data class ChannelItem(val channel: Channel, val level: Int) : ChannelRow
    data class UserItem(val user: User, val level: Int) : ChannelRow
}

private const val TAG = "ServerSession"
private val CHANNEL_AUDIOCONFIG_MAX = 32000f

class ServerSession(initial: Server) {
    var server by mutableStateOf(initial)
    val tt = TeamTalk5()

    private val handler = Handler(Looper.getMainLooper())
    private val poll = object : Runnable {
        override fun run() {
            pump()
            if (!closed) handler.postDelayed(this, 100)
        }
    }
    private val reconnect = Runnable { connect() }
    private var closed = false
    private val message = TTMessage()

    /** Other screens' interest in this session's events (files, admin tools). */
    val listeners = mutableListOf<(TTMessage) -> Unit>()

    // What the iPhone app keeps in the channel list.
    val channels = mutableStateMapOf<Int, Channel>()
    val users = mutableStateMapOf<Int, User>()
    private val chanpasswds = HashMap<Int, String>()
    var curChannel by mutableStateOf(Channel())
    var myChannel by mutableStateOf(Channel())
    private var rejoinChannel = Channel()
    private val peerSubscriptions = HashMap<Int, Int>()
    val moveUsers = mutableStateListOf<Int>()
    private var cmdid = 0
    private var loginCmdid = 0
    private var currentCmdId = 0
    private val activeCommands = HashMap<Int, Command>()
    var serverProperties by mutableStateOf(ServerProperties())
    var myAccount by mutableStateOf(UserAccount())
    val expanded = mutableStateListOf<Int>()
    val unread = mutableStateListOf<Int>()

    /** Private conversations by user, and the channel's messages and events. */
    val privateMessages = mutableStateMapOf<Int, List<MyTextMessage>>()
    val channelMessages = mutableStateListOf<MyTextMessage>()
    private val mergeMessages = HashMap<Int, MutableList<String>>()

    var publicServerName by mutableStateOf("")
        private set
    var isAdmin by mutableStateOf(false)
        private set
    var canBroadcast by mutableStateOf(false)
        private set
    /** Changes whenever flags the screens show change (voice on, streaming). */
    val tick = mutableIntStateOf(0)
    var alert by mutableStateOf<SessionAlert?>(null)
    /** Called with the conversation that popped up (the app pushes its screen). */
    var openConversation: (Int) -> Unit = {}
    /** The conversation on screen, whose messages are already being read. */
    var visibleConversation = -1

    val streaming = ChannelStreaming(this)
    val recorder = ChannelRecorder(this)
    private var suppressFileUpdates = false
    private var soundAllowed = false
    private var soundInitialized = false

    val displayName: String
        get() = server.name.ifEmpty { publicServerName.ifEmpty { "Server" } }

    val serverKey: String get() = "${server.ipaddr.lowercase()}:${server.tcpport}"

    init {
        // SDK license: the free SDK takes none (empty, as in the iPhone app).
        handler.post(poll)
        connect()
    }

    fun refresh() { tick.intValue++ }

    private fun pump() {
        while (!closed && tt.getMessage(message, 0)) {
            val m = message
            runCatching { handle(m) }.onFailure { Log.e(TAG, "event ${m.nClientEvent}", it) }
            listeners.toList().forEach { it(m) }
        }
        if (!closed) streaming.checkOfficialFileStillStreaming()
    }

    // MARK: Connecting

    private fun connect() {
        if (closed) return
        if (!setupEncryption()) {
            alert = SessionAlert("Connect to Server", "Failed to setup encryption") { disconnect() }
            return
        }
        if (!tt.connect(server.ipaddr, server.tcpport, server.udpport, 0, 0, server.encrypted)) {
            resetSoundDevices()
            tt.disconnect()
            startReconnectTimer()
        }
    }

    private fun startReconnectTimer() {
        if (closed) return
        handler.removeCallbacks(reconnect)
        handler.postDelayed(reconnect, 5000)
    }

    private fun setupEncryption(): Boolean {
        if (!server.encrypted) return true
        val dir = TeamTalkApp.context.cacheDir
        val files = mutableListOf<File>()
        fun write(name: String, data: String): String {
            if (data.isEmpty()) return ""
            return File(dir, name).also { it.writeText(data); files.add(it) }.path
        }
        return try {
            val encryption = EncryptionContext()
            encryption.szCAFile = write("ca_cert.pem", server.cacertdata)
            encryption.szCertificateFile = write("cert.pem", server.certdata)
            encryption.szPrivateKeyFile = write("key.pem", server.certprivkeydata)
            encryption.bVerifyPeer = server.certverifypeer
            encryption.nVerifyDepth = if (server.certverifypeer) 0 else -1
            tt.setEncryptionContext(encryption)
        } finally {
            files.forEach { it.delete() }
        }
    }

    private fun login() {
        val nickname = server.nickname.ifEmpty { Prefs.string(PREF_GENERAL_NICKNAME) }
        tt.setClientVersion(AppInfo.clientVersion)
        loginCmdid = tt.doLoginEx(nickname, server.username, server.password, AppInfo.CLIENT_NAME)
        cmdid = loginCmdid
        activeCommands[loginCmdid] = Command.Login
        handler.removeCallbacks(reconnect)
    }

    /** Closes this connection for good. */
    fun disconnect() {
        if (closed) return
        closed = true
        MonitorCenter.disconnectedLive(server)
        handler.removeCallbacksAndMessages(null)
        clearServerState()
        recorder.stop()
        streaming.close()
        enableVoiceTx(false, playToggleSound = false)
        tt.closeSoundInputDevice()
        tt.closeSoundOutputDevice()
        tt.disconnect()
        tt.closeTeamTalk()
        SessionManager.remove(this)
    }

    private fun clearServerState(preserveReconnectState: Boolean = false) {
        channels.clear()
        users.clear()
        peerSubscriptions.clear()
        moveUsers.clear()
        expanded.clear()
        curChannel = Channel()
        myChannel = Channel()
        cmdid = 0
        currentCmdId = 0
        activeCommands.clear()
        serverProperties = ServerProperties()
        myAccount = UserAccount()
        if (!preserveReconnectState) {
            rejoinChannel = Channel()
            chanpasswds.clear()
            privateMessages.clear()
        }
        refresh()
    }

    // MARK: Questions the screens ask

    val myUserID: Int get() = if (closed) 0 else tt.myUserID
    private val flags: Int get() = if (closed) 0 else tt.flags
    val isLoggedIn: Boolean get() = flags and ClientFlag.CLIENT_AUTHORIZED != 0
    val isConnected: Boolean get() = flags and ClientFlag.CLIENT_CONNECTED != 0
    val isTransmitting: Boolean get() = flags and ClientFlag.CLIENT_TX_VOICE != 0
    val isInChannel: Boolean get() = myChannel.nChannelID > 0

    fun hasRight(right: Int) = myAccount.uUserRights and right != 0
    val myRights: Int get() = if (closed) 0 else myAccountNow().uUserRights
    val myType: Int get() = if (closed) 0 else myAccountNow().uUserType
    private fun myAccountNow() = UserAccount().also { tt.getMyUserAccount(it) }

    fun isOperator(userID: Int, channelID: Int) = !closed && tt.isChannelOperator(userID, channelID)
    fun channelSupportsAudio(channel: Channel) = channel.nChannelID > 0 && channel.audiocodec.nCodec != Codec.NO_CODEC
    fun canUseVoiceTx() = channelSupportsAudio(myChannel) && soundAllowed && isLoggedIn
    fun canEditChannel(channel: Channel) =
        hasRight(UserRight.USERRIGHT_MODIFY_CHANNELS) || isOperator(myUserID, channel.nChannelID)
    fun channelEditActionTitle(channel: Channel) = if (canEditChannel(channel)) "Edit properties" else "View properties"

    fun displayName(user: User): String {
        if (Prefs.on(PREF_DISPLAY_SHOWUSERNAME, false)) return limitText(user.szUsername.orEmpty())
        val nickname = user.szNickname.orEmpty()
        return if (nickname.isEmpty()) "Noname - #${user.nUserID}" else limitText(nickname)
    }

    fun getUsersCount(chanid: Int): Int =
        users.values.count { it.nChannelID == chanid } +
            channels.values.filter { it.nParentID == chanid }.sumOf { getUsersCount(it.nChannelID) }

    fun channelTitle(channel: Channel): String =
        if (channel.nParentID == 0) serverProperties.szServerName.orEmpty()
        else "${channel.szName} (${getUsersCount(channel.nChannelID)})"

    fun channelHasExpandableRows(channel: Channel) =
        users.values.any { it.nChannelID == channel.nChannelID } || channels.values.any { it.nParentID == channel.nChannelID }

    fun channelDisplayName(channel: Channel): String =
        if (channel.nParentID == 0) "root" else channel.szName.orEmpty().ifEmpty { "channel" }

    fun currentServerName(): String {
        var name = serverProperties.szServerName.orEmpty()
        if (name.isEmpty()) {
            val live = ServerProperties()
            if (tt.getServerProperties(live)) name = live.szServerName.orEmpty()
        }
        return name.ifEmpty { "server" }
    }

    /** The flat channel tree shown on the channel screen. */
    fun rows(): List<ChannelRow> {
        val rows = mutableListOf<ChannelRow>()
        sortedUsers(0).forEach { rows.add(ChannelRow.UserItem(it, 0)) }
        sortedChannels(channels.values.filter { it.nParentID == 0 }).forEach { appendTree(rows, it, 0) }
        return rows
    }

    private fun appendTree(rows: MutableList<ChannelRow>, channel: Channel, level: Int) {
        rows.add(ChannelRow.ChannelItem(channel, level))
        if (channel.nChannelID !in expanded) return
        sortedUsers(channel.nChannelID).forEach { rows.add(ChannelRow.UserItem(it, level + 1)) }
        sortedChannels(channels.values.filter { it.nParentID == channel.nChannelID }).forEach { appendTree(rows, it, level + 1) }
    }

    private fun sortedChannels(list: List<Channel>): List<Channel> {
        val byName = compareBy<Channel> { it.szName.orEmpty().lowercase() }
        return if (Prefs.int(PREF_DISPLAY_SORTCHANNELS, CHANSORT_ASCENDING) == CHANSORT_POPULARITY) {
            list.sortedWith(compareByDescending<Channel> { c -> users.values.count { it.nChannelID == c.nChannelID } }.then(byName))
        } else list.sortedWith(byName)
    }

    private fun sortedUsers(chanid: Int) =
        users.values.filter { it.nChannelID == chanid }.sortedBy { displayName(it).lowercase() }

    private fun expandChannelAndParents(channelID: Int) {
        var id = channelID
        while (true) {
            val channel = channels[id] ?: break
            if (channel.nChannelID !in expanded) expanded.add(channel.nChannelID)
            if (channel.nParentID == 0) break
            id = channel.nParentID
        }
    }

    fun toggleChannelExpanded(channelID: Int) {
        channels[channelID]?.let { curChannel = it }
        if (channelID in expanded) expanded.remove(channelID) else expanded.add(channelID)
    }

    // MARK: Things the user does

    fun joinChannel(channel: Channel, password: String = "") {
        if (channel.bPassword) chanpasswds[channel.nChannelID] = password
        expandChannelAndParents(channel.nChannelID)
        cmdid = tt.doJoinChannelByID(channel.nChannelID, password)
        activeCommands[cmdid] = Command.Join
    }

    fun rememberedPassword(channelID: Int): String = chanpasswds[channelID].orEmpty()

    fun leaveCurrentChannel() {
        if (myChannel.nChannelID > 0) {
            cmdid = tt.doLeaveChannel()
            activeCommands[cmdid] = Command.Leave
        }
    }

    fun toggleMute(user: User) {
        tt.setUserMute(user.nUserID, StreamType.STREAMTYPE_MEDIAFILE_AUDIO, user.uUserState and UserState.USERSTATE_MUTE_MEDIAFILE == 0)
        tt.setUserMute(user.nUserID, StreamType.STREAMTYPE_VOICE, user.uUserState and UserState.USERSTATE_MUTE_VOICE == 0)
        // Ask the event loop for an updated User.
        tt.pumpMessage(ClientEvent.CLIENTEVENT_USER_STATECHANGE, user.nUserID)
    }

    /** The channel a user is in: this app shows the whole tree, so not necessarily the current one. */
    private fun channelOf(userID: Int): Int {
        val user = User()
        return if (tt.getUser(userID, user)) user.nChannelID else curChannel.nChannelID
    }

    fun kick(userID: Int) {
        cmdid = tt.doKickUser(userID, channelOf(userID))
        activeCommands[cmdid] = Command.Kick
    }

    fun ban(userID: Int) {
        cmdid = tt.doBanUser(userID, channelOf(userID))
        activeCommands[cmdid] = Command.Ban
        kick(userID)
    }

    fun moveInto(channelID: Int) {
        moveUsers.forEach {
            cmdid = tt.doMoveUser(it, channelID)
            activeCommands[cmdid] = Command.Move
        }
        moveUsers.clear()
    }

    fun clearConversation(userID: Int) {
        privateMessages.remove(userID)
        unread.remove(userID)
    }

    /** Sends a private or (userID 0) channel message. */
    fun sendText(userID: Int, content: String): Boolean {
        val msg = TextMessage()
        msg.nFromUserID = myUserID
        if (userID == 0) {
            msg.nMsgType = TextMsgType.MSGTYPE_CHANNEL
            msg.nChannelID = tt.myChannelID
        } else {
            msg.nMsgType = TextMsgType.MSGTYPE_USER
            msg.nToUserID = userID
            val name = users[myUserID]?.let { displayName(it) }.orEmpty()
            appendPrivate(userID, MyTextMessage(content, MsgType.PrivImMyself, name, msg.nFromUserID))
        }
        return send(msg, content)
    }

    fun sendBroadcast(content: String): Boolean {
        val msg = TextMessage()
        msg.nFromUserID = myUserID
        msg.nMsgType = TextMsgType.MSGTYPE_BROADCAST
        return send(msg, content)
    }

    private fun send(msg: TextMessage, content: String): Boolean {
        var sent = true
        for (part in splitTextMessage(content)) {
            val m = TextMessage(msg)
            m.szMessage = part.first
            m.bMore = part.second
            sent = tt.doTextMessage(m) > 0 && sent
        }
        return sent
    }

    private fun appendPrivate(userID: Int, m: MyTextMessage) {
        privateMessages[userID] = (privateMessages[userID].orEmpty() + m).takeLast(MAX_TEXTMESSAGES)
    }

    private fun appendChannel(m: MyTextMessage) {
        channelMessages.add(m)
        while (channelMessages.size > MAX_TEXTMESSAGES) channelMessages.removeAt(0)
    }

    fun applyPreferredStatus(message: String? = null) {
        if (isConnected) tt.doChangeStatus(preferredStatusMode(), message ?: preferredStatusMessage())
    }

    fun updatePublicServerName(name: String) {
        publicServerName = name
    }

    fun channelFiles(channelID: Int): List<RemoteFile> {
        val count = dk.bearware.IntPtr()
        if (!tt.getChannelFiles(channelID, null, count) || count.value <= 0) return emptyList()
        val files = arrayOfNulls<RemoteFile>(count.value)
        for (i in files.indices) files[i] = RemoteFile()
        return if (tt.getChannelFiles(channelID, files, count)) files.filterNotNull().take(count.value) else emptyList()
    }

    // MARK: Voice

    fun enableVoiceTx(enable: Boolean, playToggleSound: Boolean = true) {
        if (closed && enable) return
        val was = isTransmitting
        if (enable) {
            if (!canUseVoiceTx()) { refresh(); return }
            if (!setupSoundDevices(enableInput = true)) { refresh(); return }
            updateAudioConfig()
        } else if (!was) {
            refresh()
            return
        }
        tt.enableVoiceTransmission(enable)
        if (!enable && soundInitialized) setupSoundDevices(enableInput = false)
        if (playToggleSound) playSound(if (enable) Sounds.TxOn else Sounds.TxOff)
        refresh()
    }

    fun toggleVoiceTransmission() {
        if (canUseVoiceTx()) AppHooks.withMicrophone { enableVoiceTx(!isTransmitting) }
    }

    /** Sets the sound devices up again, keeping the microphone as it is. */
    fun restoreSoundDevices() {
        if (soundInitialized && canConfigure()) setupSoundDevices(enableInput = isTransmitting)
    }

    private fun canConfigure() = soundAllowed && isLoggedIn

    private fun setupSoundDevices(enableInput: Boolean): Boolean {
        if (!canConfigure()) return false
        tt.closeSoundInputDevice()
        tt.closeSoundOutputDevice()
        val devices = AudioRouting.configure(enableInput)
        val input = !enableInput || tt.initSoundInputDevice(devices.input)
        val output = tt.initSoundOutputDevice(devices.output)
        if (!input || !output) {
            Log.w(TAG, "Sound devices failed: input $input output $output")
            tt.closeSoundInputDevice()
            tt.closeSoundOutputDevice()
            soundInitialized = false
            return false
        }
        if (enableInput) tt.setSoundDeviceEffects(devices.effects)
        soundInitialized = true
        return true
    }

    private fun resetSoundDevices() {
        soundAllowed = false
        tt.closeSoundInputDevice()
        tt.closeSoundOutputDevice()
        soundInitialized = false
        AudioRouting.release()
    }

    private fun applyConnectedAudioPreferences() {
        if (!Prefs.has(PREF_MASTER_VOLUME)) Prefs.set(PREF_MASTER_VOLUME, DEFAULT_AUDIO_LEVEL_PERCENT)
        if (!Prefs.has(PREF_MICROPHONE_GAIN)) Prefs.set(PREF_MICROPHONE_GAIN, DEFAULT_AUDIO_LEVEL_PERCENT)
        tt.setSoundOutputVolume(refVolume(Prefs.int(PREF_MASTER_VOLUME, DEFAULT_AUDIO_LEVEL_PERCENT).toDouble()))
        tt.setSoundInputGainLevel(refVolume(Prefs.int(PREF_MICROPHONE_GAIN, DEFAULT_AUDIO_LEVEL_PERCENT).toDouble()))
    }

    fun updateAudioConfig() {
        if (myChannel.audiocfg.bEnableAGC) {
            tt.setSoundInputGainLevel(SoundLevel.SOUND_GAIN_DEFAULT)
            val ap = AudioPreprocessor(AudioPreprocessorType.WEBRTC_AUDIOPREPROCESSOR, true)
            val gain = myChannel.audiocfg.nGainLevel / CHANNEL_AUDIOCONFIG_MAX
            ap.webrtc.gaincontroller2.fixeddigital.fGainDB = WebRTCConstants.WEBRTC_GAINCONTROLLER2_FIXEDGAIN_MAX * gain
            ap.webrtc.gaincontroller2.bEnable = true
            tt.setSoundInputPreprocess(ap)
        } else {
            tt.setSoundInputPreprocess(AudioPreprocessor(AudioPreprocessorType.TEAMTALK_AUDIOPREPROCESSOR, true))
            // With several connections each keeps its temporary gain.
            if (SessionManager.sessions.size <= 1) {
                tt.setSoundInputGainLevel(refVolume(Prefs.int(PREF_MICROPHONE_GAIN, DEFAULT_AUDIO_LEVEL_PERCENT).toDouble()))
            }
        }
    }

    /** The volume of others' media files relative to voice, as BearWare's clients set it. */
    fun applyAudioFileVolume(userID: Int) {
        val percent = preferredAudioFileVolumePercent() ?: return
        tt.setUserVolume(userID, StreamType.STREAMTYPE_MEDIAFILE_AUDIO, refVolume(percent))
        tt.pumpMessage(ClientEvent.CLIENTEVENT_USER_STATECHANGE, userID)
    }

    fun applyAudioFileVolumeToEveryone() {
        users.keys.filter { it != myUserID }.forEach { applyAudioFileVolume(it) }
    }

    // MARK: Events

    private fun handle(m: TTMessage) {
        when (m.nClientEvent) {
            ClientEvent.CLIENTEVENT_CON_SUCCESS -> login()

            ClientEvent.CLIENTEVENT_CON_CRYPT_ERROR, ClientEvent.CLIENTEVENT_CON_FAILED -> {
                resetSoundDevices()
                tt.disconnect()
                startReconnectTimer()
            }

            ClientEvent.CLIENTEVENT_CON_LOST -> {
                recorder.connectionLost()
                resetSoundDevices()
                tt.disconnect()
                playSound(Sounds.SrvLost)
                if (Prefs.on(PREF_TTSEVENT_CONLOST)) newUtterance("Connection lost")
                startReconnectTimer()
                clearServerState(preserveReconnectState = true)
            }

            ClientEvent.CLIENTEVENT_CMD_PROCESSING -> {
                if (m.bActive) {
                    currentCmdId = m.nSource
                    val cmd = activeCommands[m.nSource]
                    suppressFileUpdates = cmd == Command.Login || cmd == Command.Join
                } else {
                    suppressFileUpdates = false
                    currentCmdId = 0
                    commandComplete(m.nSource)
                }
            }

            ClientEvent.CLIENTEVENT_CMD_ERROR -> commandError(m)

            ClientEvent.CLIENTEVENT_CMD_SERVER_UPDATE -> {
                serverProperties = m.serverproperties
                updatePublicServerName(m.serverproperties.szServerName.orEmpty())
            }

            ClientEvent.CLIENTEVENT_CMD_MYSELF_LOGGEDIN -> {
                val account = m.useraccount
                isAdmin = account.uUserType and UserType.USERTYPE_ADMIN != 0
                canBroadcast = isAdmin || account.uUserRights and UserRight.USERRIGHT_TEXTMESSAGE_BROADCAST != 0
                // An administrator can do everything.
                if (isAdmin) account.uUserRights = -1
                myAccount = account
                // A monitor using this account steps aside while connected.
                MonitorCenter.connectedLive(server)
                soundAllowed = true
                applyConnectedAudioPreferences()
                setupSoundDevices(enableInput = false)
                account.szInitChannel?.takeIf { it.isNotEmpty() }?.let { server = server.copy(channel = it) }
                refresh()
            }

            ClientEvent.CLIENTEVENT_CMD_MYSELF_KICKED -> if (m.nSource == 0) disconnect()

            ClientEvent.CLIENTEVENT_CMD_CHANNEL_NEW -> {
                channels[m.channel.nChannelID] = m.channel
                if (m.channel.nParentID == 0) updatePublicServerName(currentServerName())
            }

            ClientEvent.CLIENTEVENT_CMD_CHANNEL_UPDATE -> channelUpdated(m.channel)

            ClientEvent.CLIENTEVENT_CMD_CHANNEL_REMOVE -> channels.remove(m.channel.nChannelID)

            ClientEvent.CLIENTEVENT_CMD_USER_LOGGEDIN -> userLoggedIn(m.user)
            ClientEvent.CLIENTEVENT_CMD_USER_LOGGEDOUT -> userLoggedOut(m.user)
            ClientEvent.CLIENTEVENT_CMD_USER_JOINED -> userJoined(m.user)
            ClientEvent.CLIENTEVENT_CMD_USER_LEFT -> userLeft(m.user, m.nSource)
            ClientEvent.CLIENTEVENT_CMD_USER_UPDATE -> userUpdated(m.user)
            ClientEvent.CLIENTEVENT_CMD_USER_TEXTMSG -> textMessage(m.textmessage)

            ClientEvent.CLIENTEVENT_USER_STATECHANGE -> users[m.user.nUserID] = m.user

            ClientEvent.CLIENTEVENT_CMD_FILE_NEW -> if (!suppressFileUpdates) fileUpdate(m.remotefile, added = true)
            ClientEvent.CLIENTEVENT_CMD_FILE_REMOVE -> if (!suppressFileUpdates) fileUpdate(m.remotefile, added = false)

            ClientEvent.CLIENTEVENT_USER_RECORD_MEDIAFILE -> recorder.recordingEvent(m.nSource, m.mediafileinfo)

            ClientEvent.CLIENTEVENT_STREAM_MEDIAFILE -> streaming.mediaFileEvent(m.mediafileinfo)
        }
    }

    private fun commandError(m: TTMessage) {
        val text = m.clienterrormsg.szErrorMsg.orEmpty()
        appendChannel(MyTextMessage("Command failed: $text", MsgType.LogMsg))
        if (m.nSource == loginCmdid) {
            // The server refused the login.
            alert = SessionAlert("Error", text) { disconnect() }
        } else if (m.nSource == cmdid || activeCommands.containsKey(m.nSource)) {
            if (m.clienterrormsg.nErrorNo != ClientError.CMDERR_SUCCESS) alert = SessionAlert("Error", text)
        }
    }

    private fun commandComplete(id: Int) {
        val cmd = activeCommands.remove(id) ?: return
        if (cmd != Command.Login) return

        // The initial channel, once: after this rejoining takes over.
        if (server.channel.isNotEmpty()) {
            val chanid = tt.getChannelIDFromPath(server.channel)
            if (chanid > 0) {
                rejoinChannel = Channel().apply { nChannelID = chanid; szPassword = server.chanpasswd }
            } else {
                val tokens = server.channel.split("/").toMutableList()
                if (tokens.isNotEmpty()) {
                    val name = tokens.removeAt(tokens.lastIndex)
                    val parent = tt.getChannelIDFromPath(tokens.joinToString("") { "/$it" })
                    if (parent > 0) {
                        rejoinChannel = Channel(true, true).apply {
                            nParentID = parent
                            szName = name
                            szPassword = server.chanpasswd
                        }
                    }
                }
            }
            server = server.copy(channel = "", chanpasswd = "")
        }
        applyPreferredStatus(server.statusmsg.ifEmpty { preferredStatusMessage() })

        if (!isLoggedIn) return
        when {
            rejoinChannel.nChannelID > 0 -> {
                val id2 = rejoinChannel.nChannelID
                val password = chanpasswds[id2] ?: rejoinChannel.szPassword.orEmpty()
                chanpasswds[id2] = password
                rejoinChannel.szPassword = password
                cmdid = tt.doJoinChannel(rejoinChannel)
                activeCommands[cmdid] = Command.Join
            }
            rejoinChannel.szName.orEmpty().isNotEmpty() -> {
                cmdid = tt.doJoinChannel(rejoinChannel)
                activeCommands[cmdid] = Command.Join
            }
            Prefs.on(PREF_JOINROOTCHANNEL) -> {
                cmdid = tt.doJoinChannelByID(tt.rootChannelID, "")
                activeCommands[cmdid] = Command.Join
            }
        }
    }

    private fun channelUpdated(channel: Channel) {
        channels[channel.nChannelID] = channel
        recorder.channelUpdated(channel)
        if (myChannel.nChannelID == channel.nChannelID) {
            val me = myUserID
            if (channel.transmitUsersQueue[0] == me && myChannel.transmitUsersQueue[0] != me) playSound(Sounds.TransmitOn)
            if (myChannel.transmitUsersQueue[0] == me && channel.transmitUsersQueue[0] != me) playSound(Sounds.TransmitOff)
            myChannel = channel
            updateAudioConfig()
            refresh()
        }
    }

    private fun userLoggedIn(user: User) {
        val subs = defaultSubscriptions()
        if (myUserID != user.nUserID && user.uLocalSubscriptions != subs) {
            tt.doUnsubscribe(user.nUserID, user.uLocalSubscriptions xor subs)
        }
        users[user.nUserID] = user
        peerSubscriptions[user.nUserID] = user.uPeerSubscriptions

        val speak = Prefs.on(PREF_TTSEVENT_USERLOGIN)
        if (myUserID == user.nUserID) {
            appendChannel(MyTextMessage("Logged in to server", MsgType.LogMsg))
            if (speak) newUtterance("Logged in to ${currentServerName()}")
        } else if (currentCmdId == 0) {
            val name = displayName(user)
            appendChannel(MyTextMessage("$name has logged in", MsgType.LogMsg))
            playSound(Sounds.LoggedIn)
            if (speak) {
                newUtterance(if (SessionManager.sessions.size >= 2) "$name has logged in to ${currentServerName()}" else "$name has logged in")
            }
        }
    }

    private fun userLoggedOut(user: User) {
        users.remove(user.nUserID)
        peerSubscriptions.remove(user.nUserID)
        if (currentCmdId == 0 && myUserID != user.nUserID) {
            val name = displayName(user)
            appendChannel(MyTextMessage("$name has logged out", MsgType.LogMsg))
            playSound(Sounds.LoggedOut)
            if (Prefs.on(PREF_TTSEVENT_USERLOGOUT)) {
                newUtterance(if (SessionManager.sessions.size >= 2) "$name has logged out of ${currentServerName()}" else "$name has logged out")
            }
        }
    }

    private fun userJoined(user: User) {
        users[user.nUserID] = user
        peerSubscriptions[user.nUserID] = user.uPeerSubscriptions
        val me = user.nUserID == myUserID
        if (me) recorder.joinedChannel(user.nChannelID) else {
            recorder.userJoined(user)
            applyAudioFileVolume(user.nUserID)
        }
        val speak = currentCmdId == 0 && Prefs.on(PREF_TTSEVENT_JOINEDCHAN)
        if (me) {
            val channel = channels[user.nChannelID] ?: return
            curChannel = channel
            myChannel = channel
            expandChannelAndParents(user.nChannelID)
            if (rejoinChannel.nChannelID == 0 && chanpasswds[user.nChannelID] == null) {
                chanpasswds[user.nChannelID] = rejoinChannel.szPassword.orEmpty()
            }
            rejoinChannel = channel
            when {
                isTransmitting -> enableVoiceTx(true, playToggleSound = false)
                shouldUnmuteByDefault() && canUseVoiceTx() ->
                    AppHooks.withMicrophone { enableVoiceTx(true, playToggleSound = false) }
                else -> { updateAudioConfig(); refresh() }
            }
            appendChannel(MyTextMessage("Joined channel ${channelDisplayName(channel)}", MsgType.LogMsg))
            if (Prefs.on(PREF_TTSEVENT_JOINEDCHAN)) newUtterance("Joined channel ${channelDisplayName(myChannel)}")
        } else if (user.nChannelID == myChannel.nChannelID && myChannel.nChannelID > 0) {
            if (currentCmdId == 0) {
                playSound(Sounds.JoinedChan)
                appendChannel(MyTextMessage("${displayName(user)} joined channel ${channelDisplayName(myChannel)}", MsgType.LogMsg))
            }
            if (speak) newUtterance("${displayName(user)} joined channel")
        } else channels[user.nChannelID]?.let { channel ->
            if (currentCmdId == 0) {
                appendChannel(MyTextMessage("${displayName(user)} joined channel ${channelDisplayName(channel)}", MsgType.LogMsg))
            }
            if (speak) newUtterance("${displayName(user)} joined channel ${channelDisplayName(channel)}")
        }
    }

    private fun userLeft(user: User, channelID: Int) {
        val me = user.nUserID == myUserID
        if (me) recorder.leftChannel() else recorder.userLeft(user)
        if (myAccount.uUserRights and UserRight.USERRIGHT_VIEW_ALL_USERS == 0) users.remove(user.nUserID) else users[user.nUserID] = user

        val speak = currentCmdId == 0 && Prefs.on(PREF_TTSEVENT_LEFTCHAN)
        if (me) {
            val leftID = if (user.nChannelID > 0) user.nChannelID else channelID
            val left = channels[leftID]
            expanded.remove(leftID)
            curChannel = Channel()
            myChannel = Channel()
            rejoinChannel = Channel()
            refresh()
            left?.let {
                appendChannel(MyTextMessage("Left channel ${channelDisplayName(it)}", MsgType.LogMsg))
                if (Prefs.on(PREF_TTSEVENT_LEFTCHAN)) newUtterance("Left channel ${channelDisplayName(it)}")
            }
        } else if (channelID == myChannel.nChannelID && myChannel.nChannelID > 0) {
            if (currentCmdId == 0) {
                playSound(Sounds.LeftChan)
                appendChannel(MyTextMessage("${displayName(user)} left channel ${channelDisplayName(myChannel)}", MsgType.LogMsg))
            }
            if (speak) newUtterance("${displayName(user)} left channel")
        } else channels[channelID]?.let { channel ->
            if (currentCmdId == 0) {
                appendChannel(MyTextMessage("${displayName(user)} left channel ${channelDisplayName(channel)}", MsgType.LogMsg))
            }
            if (speak) newUtterance("${displayName(user)} left channel ${channelDisplayName(channel)}")
        }
    }

    private fun userUpdated(user: User) {
        val previous = peerSubscriptions[user.nUserID]
        if (user.nUserID != myUserID && previous != null && previous != user.uPeerSubscriptions) {
            speakSubscriptionChanges(user, previous, user.uPeerSubscriptions)
            notifyInterceptionChanges(user, previous, user.uPeerSubscriptions)
        }
        peerSubscriptions[user.nUserID] = user.uPeerSubscriptions
        users[user.nUserID] = user
    }

    private fun textMessage(msg: TextMessage) {
        // TeamTalk splits long messages into several events; only the last
        // one completes it.
        val key = (msg.nMsgType shl 16) or msg.nFromUserID
        if (msg.bMore) {
            val parts = mergeMessages.getOrPut(key) { mutableListOf() }
            parts.add(msg.szMessage.orEmpty())
            if (parts.size > 1000) mergeMessages.remove(key) // out of memory otherwise
            return
        }
        val content = mergeMessages.remove(key).orEmpty().joinToString("") + msg.szMessage.orEmpty()
        val sender = User().also { tt.getUser(msg.nFromUserID, it) }
        val name = displayName(sender)
        val mine = msg.nFromUserID == myUserID
        when (msg.nMsgType) {
            TextMsgType.MSGTYPE_CHANNEL -> {
                playSound(Sounds.ChanMsg)
                appendChannel(MyTextMessage(content, if (mine) MsgType.ChanImMyself else MsgType.ChanIm, name, msg.nFromUserID))
                if (Prefs.on(PREF_TTSEVENT_CHANTEXTMSG)) newUtterance("Channel message from ${limitText(name)}. $content")
            }
            TextMsgType.MSGTYPE_BROADCAST -> {
                playSound(Sounds.BroadcastMsg)
                appendChannel(MyTextMessage(content, MsgType.Bcast, name, msg.nFromUserID))
                if (Prefs.on(PREF_TTSEVENT_BROADCASTMSG)) newUtterance("Broadcast message from ${limitText(name)}: $content")
            }
            TextMsgType.MSGTYPE_USER -> {
                playSound(Sounds.UserMsg)
                appendPrivate(msg.nFromUserID, MyTextMessage(content, if (mine) MsgType.PrivImMyself else MsgType.PrivIm, name, msg.nFromUserID))
                if (visibleConversation != msg.nFromUserID) {
                    if (msg.nFromUserID !in unread) unread.add(msg.nFromUserID)
                    if (Prefs.on(PREF_DISPLAY_POPUPTXTMSG)) openConversation(msg.nFromUserID)
                }
                if (Prefs.on(PREF_TTSEVENT_TEXTMSG)) newUtterance("Private text message from ${limitText(name)}. $content")
            }
        }
    }

    private fun fileUpdate(file: RemoteFile, added: Boolean) {
        if (file.nChannelID != tt.myChannelID) return
        val username = file.szUsername.orEmpty()
        val own = added && username.isNotEmpty() && username == myAccount.szUsername
        playSound(if (own) Sounds.FileTxComplete else Sounds.FileUpdate)
        if (Prefs.on(PREF_TTSEVENT_FILEUPDATE)) {
            newUtterance("File ${file.szFileName} ${if (added) "added" else "removed"} by $username.")
        }
    }

    private fun speakSubscriptionChanges(user: User, previous: Int, current: Int) {
        if (!Prefs.on(PREF_TTSEVENT_SUBSCRIPTIONS)) return
        val changed = previous xor current
        for ((subscription, name) in SUBSCRIPTION_NAMES) {
            if (changed and subscription != 0) {
                val state = if (current and subscription != 0) "on" else "off"
                newUtterance("${displayName(user)} changed subscription $name to: $state")
            }
        }
    }

    private fun notifyInterceptionChanges(user: User, previous: Int, current: Int) {
        val changed = previous xor current
        for ((subscription, name) in INTERCEPTION_NAMES) {
            if (changed and subscription == 0) continue
            val enabled = current and subscription != 0
            playSound(if (enabled) Sounds.InterceptStart else Sounds.InterceptEnd)
            val speak = if (enabled) Prefs.enabled(PREF_TTSEVENT_INTERCEPTION_START, PREF_TTSEVENT_INTERCEPTION)
            else Prefs.enabled(PREF_TTSEVENT_INTERCEPTION_END, PREF_TTSEVENT_INTERCEPTION)
            if (speak) newUtterance("${displayName(user)} changed subscription intercept $name to: ${if (enabled) "on" else "off"}")
        }
    }

    companion object {
        private val SUBSCRIPTION_NAMES = listOf(
            Subscription.SUBSCRIBE_USER_MSG to "user messages",
            Subscription.SUBSCRIBE_CHANNEL_MSG to "channel messages",
            Subscription.SUBSCRIBE_BROADCAST_MSG to "broadcast messages",
            Subscription.SUBSCRIBE_VOICE to "voice",
            Subscription.SUBSCRIBE_VIDEOCAPTURE to "web cam",
            Subscription.SUBSCRIBE_DESKTOP to "desktop",
            Subscription.SUBSCRIBE_DESKTOPINPUT to "desktop input",
            Subscription.SUBSCRIBE_MEDIAFILE to "audio files",
        )
        private val INTERCEPTION_NAMES = listOf(
            Subscription.SUBSCRIBE_INTERCEPT_USER_MSG to "user messages",
            Subscription.SUBSCRIBE_INTERCEPT_CHANNEL_MSG to "channel messages",
            Subscription.SUBSCRIBE_INTERCEPT_VOICE to "voice",
            Subscription.SUBSCRIBE_INTERCEPT_VIDEOCAPTURE to "web cam",
            Subscription.SUBSCRIBE_INTERCEPT_DESKTOP to "desktop",
            Subscription.SUBSCRIBE_INTERCEPT_MEDIAFILE to "audio files",
        )

        fun defaultSubscriptions(): Int {
            var subs = Subscription.SUBSCRIBE_CUSTOM_MSG
            if (Prefs.on(PREF_SUB_USERMSG)) subs = subs or Subscription.SUBSCRIBE_USER_MSG
            if (Prefs.on(PREF_SUB_CHANMSG)) subs = subs or Subscription.SUBSCRIBE_CHANNEL_MSG
            if (Prefs.on(PREF_SUB_BROADCAST)) subs = subs or Subscription.SUBSCRIBE_BROADCAST_MSG
            if (Prefs.on(PREF_SUB_VOICE)) subs = subs or Subscription.SUBSCRIBE_VOICE
            if (Prefs.on(PREF_SUB_VIDEOCAP)) subs = subs or Subscription.SUBSCRIBE_VIDEOCAPTURE
            if (Prefs.on(PREF_SUB_MEDIAFILE)) subs = subs or Subscription.SUBSCRIBE_MEDIAFILE
            if (Prefs.on(PREF_SUB_DESKTOP)) subs = subs or Subscription.SUBSCRIBE_DESKTOP
            if (Prefs.on(PREF_SUB_DESKTOPINPUT, false)) subs = subs or Subscription.SUBSCRIBE_DESKTOPINPUT
            return subs
        }
    }
}

/**
 * Splits a message into TeamTalk's pieces of at most 511 UTF-8 bytes, without
 * breaking a character. Each piece says whether more follow.
 */
fun splitTextMessage(content: String): List<Pair<String, Boolean>> {
    val limit = TT_STRLEN - 1
    val parts = mutableListOf<Pair<String, Boolean>>()
    var rest = content
    while (rest.toByteArray().size > limit) {
        var bytes = 0
        var i = 0
        while (i < rest.length) {
            val cp = rest.codePointAt(i)
            val size = when {
                cp < 0x80 -> 1
                cp < 0x800 -> 2
                cp < 0x10000 -> 3
                else -> 4
            }
            if (bytes + size > limit) break
            bytes += size
            i += Character.charCount(cp)
        }
        parts.add(rest.substring(0, i) to true)
        rest = rest.substring(i)
    }
    parts.add(rest to false)
    return parts
}
