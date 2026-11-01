/*
 * AudioNet in TeamTalk NG: send what one of your AudioNet devices is sharing
 * into the current TeamTalk channel.
 *
 * TeamTalk NG signs in to the AudioNet account as a visitor, like AudioNet's
 * web client: no device is added to the account. It listens to the chosen
 * device into an AudioTap (the engine hands the sound to the app instead of a
 * speaker), and the channel's streamer reads the tap at the channel's format.
 */
package com.matthewdovi.teamtalkng

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.matthewdovi.audionet.engine.AudioNetAndroid
import com.matthewdovi.teamtalkng.ui.ActionRow
import com.matthewdovi.teamtalkng.ui.ActionsDialog
import com.matthewdovi.teamtalkng.ui.ConfirmationDialog
import com.matthewdovi.teamtalkng.ui.GroupedBody
import com.matthewdovi.teamtalkng.ui.GroupedSection
import com.matthewdovi.teamtalkng.ui.MessageDialog
import com.matthewdovi.teamtalkng.ui.PercentSlider
import com.matthewdovi.teamtalkng.ui.RowDivider
import com.matthewdovi.teamtalkng.ui.RowPadding
import com.matthewdovi.teamtalkng.ui.ScreenFrame
import com.matthewdovi.teamtalkng.ui.SessionAlertDialog
import com.matthewdovi.teamtalkng.ui.TextRow
import com.matthewdovi.teamtalkng.ui.ValueRow
import com.matthewdovi.teamtalkng.ui.secondaryText
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import uniffi.audionet_ffi.AudioNetException
import uniffi.audionet_ffi.AudioTap
import uniffi.audionet_ffi.Client
import uniffi.audionet_ffi.Device
import uniffi.audionet_ffi.Event
import uniffi.audionet_ffi.EventListener
import uniffi.audionet_ffi.Source
import uniffi.audionet_ffi.StreamState
import uniffi.audionet_ffi.VisitorLogin
import uniffi.audionet_ffi.visitorSignIn
import uniffi.audionet_ffi.visitorSignOut
import java.net.URI

private const val LOGIN_KEY = "audionet.visitor"

object AudioNetBridge {
    sealed interface Connection {
        data object SignedOut : Connection
        data object Connecting : Connection
        data object Connected : Connection
        data class Disconnected(val reason: String) : Connection
    }

    class Sending(val sessionID: String, val deviceName: String, val sourceName: String, val tap: AudioTap, var active: Boolean)

    var login by mutableStateOf<VisitorLogin?>(null)
        private set
    var connection by mutableStateOf<Connection>(Connection.SignedOut)
        private set
    val devices = mutableStateListOf<Device>()
    var sending by mutableStateOf<Sending?>(null)
        private set
    var sendingActive by mutableStateOf(false)
        private set
    var status by mutableStateOf("")
        private set
    var busy by mutableStateOf(false)
        private set
    /** The stream being sent ended; the reason in words. */
    var ended: (String) -> Unit = {}

    private var client: Client? = null
    private var generation = 0
    private val main = Handler(Looper.getMainLooper())

    fun attach(context: Context) {
        AudioNetAndroid.attach(context)
        login = SecretStore.get(LOGIN_KEY)?.let {
            runCatching {
                val j = JSONObject(it)
                VisitorLogin(j.getString("server_url"), j.getString("username"), j.getString("token"))
            }.getOrNull()
        }
    }

    val lastServer get() = login?.serverUrl ?: Prefs.string("AudioNetServer")
    val lastUsername get() = login?.username ?: Prefs.string("AudioNetUsername")

    /** Connects with the saved sign-in, if any; the connection then stays while the app runs. */
    fun connectIfSignedIn() {
        val login = login ?: return
        if (client != null) return
        val gen = ++generation
        val c = Client.visitor(login, "TeamTalk NG", object : EventListener {
            override fun onEvent(event: Event) {
                main.post { if (gen == generation) handle(event) }
            }
        })
        client = c
        connection = Connection.Connecting
        c.start()
    }

    suspend fun signIn(server: String, username: String, password: String) {
        val s = server.trim()
        val u = username.trim()
        Prefs.set("AudioNetServer", s)
        Prefs.set("AudioNetUsername", u)
        busy = true
        try {
            val result = withContext(Dispatchers.IO) { visitorSignIn(s, u, password) }
            SecretStore.put(LOGIN_KEY, JSONObject().put("server_url", result.serverUrl).put("username", result.username).put("token", result.token).toString())
            login = result
            connectIfSignedIn()
        } finally {
            busy = false
        }
    }

    fun signOut() {
        stopSending()
        generation++
        val old = client
        val token = login
        client = null
        Thread {
            runCatching { old?.stop() }
            token?.let { runCatching { visitorSignOut(it) } }
        }.start()
        SecretStore.remove(LOGIN_KEY)
        login = null
        devices.clear()
        connection = Connection.SignedOut
        status = ""
    }

    /** Starts listening to a device's sound into a new tap with the channel's format. */
    fun startSending(device: Device, source: Source, sampleRate: Int, channels: Int): AudioTap {
        val c = client
        if (c == null || connection != Connection.Connected) {
            throw IllegalStateException("AudioNet is not connected yet. Try again in a moment.")
        }
        stopSending()
        val tap = AudioTap("TeamTalk channel", sampleRate.toUInt(), channels.toUInt())
        val session = c.listen(device.nodeId, source.id, tap.destinationId())
        sending = Sending(session, device.name, source.name, tap, false)
        sendingActive = false
        return tap
    }

    fun stopSending() {
        val s = sending ?: return
        sending = null
        sendingActive = false
        runCatching { client?.stopStream(s.sessionID) }
    }

    fun message(e: Throwable): String = when (e) {
        is AudioNetException.Failed -> e.message.orEmpty()
        else -> e.message.orEmpty()
    }

    private fun streamEnded(id: String, reason: String) {
        if (sending?.sessionID != id) return
        sending = null
        sendingActive = false
        ended(reason)
    }

    private fun handle(event: Event) {
        when (event) {
            Event.Connected -> {
                connection = Connection.Connected
                client?.refreshDevices()
            }
            is Event.Disconnected -> connection = Connection.Disconnected(event.reason)
            is Event.Status -> status = event.text
            is Event.Devices -> { devices.clear(); devices.addAll(event.devices) }
            is Event.DeviceChanged -> {
                val i = devices.indexOfFirst { it.nodeId == event.device.nodeId }
                if (i >= 0) devices[i] = event.device else devices.add(event.device)
            }
            is Event.Stream -> when (event.state) {
                StreamState.ACTIVE -> if (sending?.sessionID == event.sessionId && !sendingActive) {
                    sendingActive = true
                    announce("AudioNet sound is being sent to the channel.")
                }
                StreamState.FAILED, StreamState.ENDED -> streamEnded(event.sessionId, event.detail)
                StreamState.STARTING -> {}
            }
            is Event.StreamEnded -> streamEnded(event.sessionId, event.reason)
            is Event.ServerProblem -> status = event.message
            is Event.Stopped -> {
                // The sign-in ended for good (it expired, or was ended elsewhere).
                client = null
                sending = null
                sendingActive = false
                devices.clear()
                val error = event.error
                if (error != null) {
                    SecretStore.remove(LOGIN_KEY)
                    login = null
                    connection = Connection.SignedOut
                    status = error
                } else connection = Connection.Disconnected("")
            }
            is Event.Diagnostics -> {}
        }
    }
}

private fun LiveAudioOf(tap: AudioTap) = LiveAudio { frames -> tap.read(frames.toUInt()).toShortArray() }

/** Sends a device's sound into the channel, mixed with an audio file if one is streaming. */
private fun startSending(session: ServerSession, device: Device, source: Source): String? {
    val streaming = session.streaming
    if (!streaming.canSendAudioNet()) return "You do not have permission to stream audio on this server."
    val format = streaming.channelFormat()
    val tap = try {
        AudioNetBridge.startSending(device, source, format.sampleRate, format.channels)
    } catch (e: Exception) {
        return AudioNetBridge.message(e)
    }
    AudioNetBridge.ended = { reason ->
        streaming.detachAudioNet()
        announce(if (reason.isEmpty()) "AudioNet stopped sending to the channel." else "AudioNet stopped sending to the channel: $reason")
    }
    val error = streaming.attachAudioNet(LiveAudioOf(tap))
    if (error != null) AudioNetBridge.stopSending()
    return error
}

private fun stopSending(session: ServerSession) {
    AudioNetBridge.stopSending()
    session.streaming.detachAudioNet()
}

@Composable
private fun SignInDialog(onDismiss: () -> Unit, failed: (String) -> Unit) {
    var server by remember { mutableStateOf(AudioNetBridge.lastServer) }
    var username by remember { mutableStateOf(AudioNetBridge.lastUsername) }
    var password by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Sign In to AudioNet") },
        text = {
            Column {
                Text("Your AudioNet server's address, account name and password.")
                OutlinedTextField(server, { server = it }, label = { Text("Server address") }, singleLine = true)
                OutlinedTextField(username, { username = it }, label = { Text("Account name") }, singleLine = true)
                OutlinedTextField(password, { password = it }, label = { Text("Password") }, singleLine = true,
                    visualTransformation = PasswordVisualTransformation())
            }
        },
        confirmButton = {
            TextButton(onClick = {
                onDismiss()
                appScope.launch {
                    runCatching { AudioNetBridge.signIn(server, username, password) }
                        .onSuccess { announce("Signed in to AudioNet.") }
                        .onFailure { failed(AudioNetBridge.message(it)) }
                }
            }) { Text("Sign In") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/** The AudioNet screen: sign in, choose a device's sound to send to the channel, see and stop what is being sent. */
@Composable
fun AudioNetContent(session: ServerSession) {
    val bridge = AudioNetBridge
    val streaming = session.streaming
    session.tick.intValue
    Prefs.revision.intValue
    var signingIn by remember { mutableStateOf(false) }
    var signingOut by remember { mutableStateOf(false) }
    var choosing by remember { mutableStateOf<Device?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) { runCatching { bridge.connectIfSignedIn() }.onFailure { error = it.message } }
    val canSend = streaming.canSendAudioNet()

    ScreenFrame("AudioNet") {
        GroupedBody {
            if (bridge.login == null) {
                GroupedSection(footer = "Sign in to your AudioNet account to send what one of your devices is sharing into this channel. TeamTalk NG signs in as a visitor: no device is added to your account.") {
                    TextRow(if (bridge.busy) "Signing In…" else "Sign In to AudioNet", enabled = !bridge.busy, onClick = { signingIn = true })
                }
            } else {
                val state = when (bridge.connection) {
                    AudioNetBridge.Connection.SignedOut -> "signed out"
                    AudioNetBridge.Connection.Connecting -> "connecting"
                    AudioNetBridge.Connection.Connected -> "connected"
                    is AudioNetBridge.Connection.Disconnected -> "reconnecting"
                }
                val host = runCatching { URI(bridge.lastServer).host }.getOrNull() ?: bridge.lastServer
                GroupedSection(header = "Account", footer = bridge.status.ifEmpty { null }) {
                    ValueRow("${bridge.lastUsername} on $host", state)
                    RowDivider()
                    TextRow("Sign Out of AudioNet", color = MaterialTheme.colorScheme.error, onClick = { signingOut = true })
                }
                bridge.sending?.let { s ->
                    GroupedSection(header = "Sending to This Channel") {
                        ValueRow("${s.sourceName} from ${s.deviceName}", if (bridge.sendingActive) "sending" else "starting")
                        RowDivider()
                        TextRow("Stop Sending", color = MaterialTheme.colorScheme.error, onClick = { stopSending(session) })
                    }
                }
                GroupedSection(footer = "How loud the AudioNet sound is for everyone in the channel, also next to an audio file. 50 % leaves it as it is.") {
                    PercentSlider("Sending Volume", streamVolumePercent(PREF_STREAM_AUDIONET_VOLUME).toInt() / 10 * 10) { streaming.setAudioNetVolume(it.toDouble()) }
                }
                GroupedSection(header = "Devices", footer = if (canSend) "Choose a device to send its sound into this channel." else "You cannot send audio in this channel.") {
                    val devices = bridge.devices.sortedBy { it.name.lowercase() }
                    if (devices.isEmpty()) {
                        Text(if (bridge.connection == AudioNetBridge.Connection.Connected) "No other devices in this account." else "Connecting to AudioNet…",
                            modifier = Modifier.padding(RowPadding))
                    }
                    devices.forEachIndexed { i, d ->
                        if (i > 0) RowDivider()
                        val state2 = when {
                            !d.online -> "offline"
                            !d.sharing || d.sources.isEmpty() -> "not sharing"
                            d.sources.size == 1 -> "1 sound"
                            else -> "${d.sources.size} sounds"
                        }
                        val enabled = d.online && d.sharing && d.sources.isNotEmpty() && canSend
                        TextRow("${d.name}, $state2", enabled = enabled, onClick = { choosing = d })
                    }
                }
            }
        }
    }

    if (signingIn) SignInDialog({ signingIn = false }) { error = it }
    if (signingOut) {
        ConfirmationDialog("Sign out of AudioNet?" + if (bridge.sending != null) " Sending to the channel stops." else "", "Sign Out", onConfirm = {
            stopSending(session)
            bridge.signOut()
        }, onDismiss = { signingOut = false })
    }
    choosing?.let { d ->
        ActionsDialog("Send from ${d.name}", "Its sound goes into this channel. Your microphone stays as it is unless this server only allows voice, when it is off meanwhile.",
            d.sources.sortedByDescending { it.isDefault }.map { source ->
                source.name to { error = startSending(session, d, source) }
            }) { choosing = null }
    }
    error?.let { MessageDialog("AudioNet", it) { error = null } }
    SessionAlertDialog(session)
}
