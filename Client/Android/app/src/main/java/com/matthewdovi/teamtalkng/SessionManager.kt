/*
 * The servers connected right now, and how the rest of the app reaches the
 * phone's audio and the visible screen.
 */
package com.matthewdovi.teamtalkng

import android.content.Context
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.getSystemService
import dk.bearware.SoundDevice
import dk.bearware.SoundDeviceConstants
import dk.bearware.SoundDeviceEffects
import dk.bearware.SoundDeviceFeature
import dk.bearware.TeamTalkBase
import java.util.Vector

object AppInfo {
    const val CLIENT_NAME = "TeamTalk NG for Android"

    /**
     * The version sent at login: major.minor.build. TeamTalk clients show it
     * as three numbers of 0 to 255 each, so only the first two of the app's
     * version are used.
     */
    val clientVersion: String
        get() {
            val parts = BuildConfig.VERSION_NAME.split(".")
            return "${parts.getOrElse(0) { "0" }}.${parts.getOrElse(1) { "0" }}.${BuildConfig.VERSION_CODE}"
        }
    const val TTLINK_PREFIX = "tt://"
}

object SessionManager {
    val sessions = mutableStateListOf<ServerSession>()
    var active by mutableStateOf<ServerSession?>(null)

    val showsSessionTabs get() = sessions.size >= 2

    fun connect(server: Server): ServerSession {
        session(server)?.let { active = it; return it }
        // Before the first connection the foreground service must be up, and
        // Android only lets it use the microphone while the app is on screen.
        val session = ServerSession(server)
        sessions.add(session)
        active = session
        ConnectionService.update(TeamTalkApp.context)
        return session
    }

    fun remove(session: ServerSession) {
        sessions.remove(session)
        if (active === session) active = sessions.firstOrNull()
        AppHooks.sessionClosed(session)
        ConnectionService.update(TeamTalkApp.context)
    }

    fun session(server: Server) = sessions.firstOrNull { it.server.sameAddress(server) }
    fun isConnected(server: Server) = session(server) != null

    fun adjacent(session: ServerSession, offset: Int): ServerSession? {
        if (sessions.size < 2) return null
        val index = sessions.indexOf(session)
        if (index < 0) return null
        return sessions[(index + offset + sessions.size) % sessions.size]
    }

    fun restoreSoundDevices() = sessions.forEach { it.restoreSoundDevices() }
    fun disconnectAll() = sessions.toList().forEach { it.disconnect() }
}

/** What the session layer asks of the UI. MainActivity fills these in. */
object AppHooks {
    /** Runs [then] once the microphone may be used. */
    var withMicrophone: (then: () -> Unit) -> Unit = { it() }
    var sessionClosed: (ServerSession) -> Unit = {}
}

class SoundDevices(val input: Int, val output: Int, val effects: SoundDeviceEffects)

/**
 * The phone's audio for TeamTalk. Android has one OpenSL ES path for media
 * (speaker or headphones, what's playing goes there) and one for voice calls,
 * which has the echo cancelling the iPhone app's voice preprocessing uses.
 * The voice path also reaches the earpiece and Bluetooth headset microphones.
 */
object AudioRouting {
    private val manager: AudioManager? get() = TeamTalkApp.context.getSystemService<AudioManager>()
    private const val SPEAKER = "speaker"
    private const val EARPIECE = "earpiece"

    /** Goes up when devices come and go, for the settings to follow. */
    val revision = mutableIntStateOf(0)
    private var lastInput = false
    private var lastVoicePath = false

    val voiceProcessing get() = Prefs.on(PREF_VOICE_PROCESSING, false)

    /** Something to route to: "" is Android's own choice. */
    class Device(val key: String, val name: String)

    private fun key(d: AudioDeviceInfo) = "${d.type}:${d.productName}"

    private fun isBluetooth(d: AudioDeviceInfo) = d.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
        d.type == AudioDeviceInfo.TYPE_BLE_HEADSET || d.type == AudioDeviceInfo.TYPE_BLE_SPEAKER ||
        (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && d.type == AudioDeviceInfo.TYPE_HEARING_AID)

    private fun isWired(d: AudioDeviceInfo) = d.type == AudioDeviceInfo.TYPE_WIRED_HEADSET ||
        d.type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES || d.type == AudioDeviceInfo.TYPE_USB_HEADSET ||
        d.type == AudioDeviceInfo.TYPE_USB_DEVICE

    private fun micLabel(d: AudioDeviceInfo): String = when {
        isBluetooth(d) -> "Bluetooth headset microphone: ${d.productName}"
        d.type == AudioDeviceInfo.TYPE_WIRED_HEADSET -> "Wired headset microphone"
        else -> "USB microphone: ${d.productName}"
    }

    private fun outputLabel(d: AudioDeviceInfo): String = when {
        isBluetooth(d) -> "Bluetooth: ${d.productName}"
        d.type == AudioDeviceInfo.TYPE_WIRED_HEADSET || d.type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "Wired headphones"
        else -> "USB: ${d.productName}"
    }

    /** The microphones to choose from. A phone's own microphones aren't Android's to pick between. */
    fun microphones(): List<Device> {
        val inputs = manager?.getDevices(AudioManager.GET_DEVICES_INPUTS).orEmpty()
        return listOf(Device("", "Phone default")) + inputs
            .filter { (isWired(it) && it.type != AudioDeviceInfo.TYPE_WIRED_HEADPHONES) || isBluetooth(it) }
            .distinctBy { key(it) }.map { Device(key(it), micLabel(it)) }
    }

    /** The saved microphone, if this phone has it now. */
    val selectedMicrophone: String
        get() = Prefs.string(PREF_SNDINPUT_DEVICE).takeIf { saved -> microphones().any { it.key == saved } }.orEmpty()

    /** What call audio can be sent to. Bluetooth media-only speakers can't be, so Automatic covers them. */
    private fun callDevices(): List<AudioDeviceInfo> {
        val audio = manager ?: return emptyList()
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) audio.availableCommunicationDevices
        else audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).toList()
    }

    fun outputs(): List<Device> {
        val devices = callDevices()
        return buildList {
            add(Device("", "Automatic"))
            if (devices.any { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }) add(Device(SPEAKER, "Speaker"))
            if (devices.any { it.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE }) add(Device(EARPIECE, "Earpiece"))
            devices.filter { isWired(it) || isBluetooth(it) }.distinctBy { key(it) }.forEach { add(Device(key(it), outputLabel(it))) }
        }
    }

    /** The saved output, if this phone has it now. */
    val selectedOutput: String
        get() = Prefs.string(PREF_AUDIO_OUTPUT).takeIf { saved -> outputs().any { it.key == saved } }.orEmpty()

    private fun voicePath(enableInput: Boolean) =
        (enableInput && voiceProcessing) || (enableInput && selectedMicrophone.isNotEmpty()) || selectedOutput.isNotEmpty()

    /** What this phone's voice communication device can do. */
    private fun features(): Int {
        val devices = Vector<SoundDevice>()
        if (!TeamTalkBase.getSoundDevices(devices)) return 0
        return devices.firstOrNull { it.nDeviceID == SoundDeviceConstants.TT_SOUNDDEVICE_ID_OPENSLES_VOICECOM }?.uSoundDeviceFeatures ?: 0
    }

    fun processingDescription(): String {
        val f = runCatching { features() }.getOrDefault(0)
        val names = buildList {
            if (f and SoundDeviceFeature.SOUNDDEVICEFEATURE_AEC != 0) add("echo cancelling")
            if (f and SoundDeviceFeature.SOUNDDEVICEFEATURE_DENOISE != 0) add("noise reduction")
            if (f and SoundDeviceFeature.SOUNDDEVICEFEATURE_AGC != 0) add("automatic gain")
        }
        return if (names.isEmpty()) "Uses call audio. This phone reports no echo cancelling, noise reduction or automatic gain, so it may only change the audio path."
        else "Uses call audio, with this phone's ${names.joinToString(", ")}."
    }

    fun configure(enableInput: Boolean): SoundDevices {
        val audio = manager
        val path = voicePath(enableInput)
        lastInput = enableInput
        lastVoicePath = path
        val id = if (path) SoundDeviceConstants.TT_SOUNDDEVICE_ID_OPENSLES_VOICECOM
        else SoundDeviceConstants.TT_SOUNDDEVICE_ID_OPENSLES_DEFAULT
        if (audio != null) {
            audio.mode = if (path) AudioManager.MODE_IN_COMMUNICATION else AudioManager.MODE_NORMAL
            if (path) route(audio, enableInput) else clearRoute(audio)
        }
        val effects = SoundDeviceEffects()
        if (enableInput && path && voiceProcessing) {
            val f = runCatching { features() }.getOrDefault(0)
            effects.bEnableAGC = f and SoundDeviceFeature.SOUNDDEVICEFEATURE_AGC != 0
            effects.bEnableDenoise = f and SoundDeviceFeature.SOUNDDEVICEFEATURE_DENOISE != 0
            effects.bEnableEchoCancellation = f and SoundDeviceFeature.SOUNDDEVICEFEATURE_AEC != 0
        }
        return SoundDevices(id, id, effects)
    }

    /** The device for call audio. Android would otherwise use the earpiece. */
    private fun wanted(enableInput: Boolean): AudioDeviceInfo? {
        val devices = callDevices()
        val mic = if (enableInput) selectedMicrophone else ""
        val output = selectedOutput
        return devices.firstOrNull { mic.isNotEmpty() && key(it) == mic }
            ?: devices.firstOrNull { mic.startsWith("${AudioDeviceInfo.TYPE_BLUETOOTH_SCO}:") && isBluetooth(it) }
            ?: when (output) {
                SPEAKER -> devices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                EARPIECE -> devices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE }
                "" -> devices.firstOrNull(::isWired) ?: devices.firstOrNull(::isBluetooth)
                    ?: devices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                else -> devices.firstOrNull { key(it) == output }
            }
    }

    @Suppress("DEPRECATION")
    private fun route(audio: AudioManager, enableInput: Boolean) {
        val device = wanted(enableInput)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            device?.let { audio.setCommunicationDevice(it) }
        } else {
            val bluetooth = device?.let(::isBluetooth) == true
            audio.isSpeakerphoneOn = device?.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
            if (bluetooth) { audio.startBluetoothSco(); audio.isBluetoothScoOn = true } else {
                audio.isBluetoothScoOn = false
                audio.stopBluetoothSco()
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun clearRoute(audio: AudioManager) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) audio.clearCommunicationDevice() else {
            audio.stopBluetoothSco()
            audio.isSpeakerphoneOn = false
        }
    }

    /** Follows headphones and headsets coming and going. */
    fun watchDevices() {
        manager?.registerAudioDeviceCallback(object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>) = devicesChanged()
            override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>) = devicesChanged()
        }, Handler(Looper.getMainLooper()))
    }

    private fun devicesChanged() {
        revision.intValue++
        if (SessionManager.sessions.none { it.isLoggedIn }) return
        val audio = manager ?: return
        when {
            // A chosen device left or came back.
            voicePath(lastInput) != lastVoicePath -> SessionManager.restoreSoundDevices()
            lastVoicePath -> route(audio, lastInput)
        }
    }

    /** No connection is using the sound devices any more. */
    fun release() {
        if (SessionManager.sessions.any { it.isLoggedIn }) return
        manager?.let {
            it.mode = AudioManager.MODE_NORMAL
            clearRoute(it)
        }
    }
}
