/*
 * Settings, stored under the iPhone app's keys so that NG Account sync moves
 * them between the two apps unchanged.
 */
package com.matthewdovi.teamtalkng

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.mutableIntStateOf
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min

const val PREF_GENERAL_NICKNAME = "nickname_preference"
const val PREF_GENERAL_STATUSMESSAGE = "statusmsg_preference"
const val PREF_GENERAL_GENDER = "gender_preference"
const val PREF_GENERAL_PTTLOCK = "general_pttlock_preference"
const val PREF_GENERAL_SENDONRETURN = "general_sendonreturn_preference"
const val PREF_JOINROOTCHANNEL = "joinroot_preference"

const val PREF_DISPLAY_SHOWUSERNAME = "display_showusername_preference"
const val PREF_DISPLAY_POPUPTXTMSG = "display_popuptxtmsg_preference"
const val PREF_DISPLAY_LIMITTEXT = "display_limittext_preference"
const val PREF_DISPLAY_SORTCHANNELS = "display_sortchannels_preference"
const val PREF_FILES_SORT_FIELD = "files_sort_field_preference"
const val PREF_FILES_SORT_ASCENDING = "files_sort_ascending_preference"

const val PREF_STREAM_LOOP = "stream_loop_preference"
const val PREF_STREAM_FILE_VOLUME = "stream_file_volume_percent"
const val PREF_STREAM_AUDIONET_VOLUME = "stream_audionet_volume_percent"
const val PREF_MEDIAFILE_VOLUME = "mediafile_volume_preference"

const val PREF_MASTER_VOLUME = "mastervolume_preference"
const val PREF_MICROPHONE_GAIN = "microphonegain_preference"
const val DEFAULT_AUDIO_LEVEL_PERCENT = 50
/** Android's own audio route: which of this phone's outputs, so it isn't synced. */
const val PREF_AUDIO_OUTPUT = "android_audio_output"
const val PREF_VOICE_PROCESSING = "voiceprocessing_preference"
const val PREF_SNDINPUT_DEVICE = "sndinput_device_preference"

const val PREF_SNDEVENT_SERVERLOST = "snd_srvlost_preference"
const val PREF_SNDEVENT_VOICETX = "snd_voicetx_preference"
const val PREF_SNDEVENT_VOICETX_ON = "snd_voicetx_on_preference"
const val PREF_SNDEVENT_VOICETX_OFF = "snd_voicetx_off_preference"
const val PREF_SNDEVENT_CHANMSG = "snd_chanmsg_preference"
const val PREF_SNDEVENT_USERMSG = "snd_usermsg_preference"
const val PREF_SNDEVENT_BCASTMSG = "snd_bcastmsg_preference"
const val PREF_SNDEVENT_JOINEDCHAN = "snd_joinedchan_preference"
const val PREF_SNDEVENT_LEFTCHAN = "snd_leftchan_preference"
const val PREF_SNDEVENT_TRANSMITREADY = "snd_transmitready_preference"
const val PREF_SNDEVENT_TRANSMITREADY_ON = "snd_transmitready_on_preference"
const val PREF_SNDEVENT_TRANSMITREADY_OFF = "snd_transmitready_off_preference"
const val PREF_SNDEVENT_LOGGEDIN = "snd_loggedin_preference"
const val PREF_SNDEVENT_LOGGEDOUT = "snd_loggedout_preference"
const val PREF_SNDEVENT_INTERCEPTION = "snd_interception_preference"
const val PREF_SNDEVENT_INTERCEPTION_START = "snd_interception_start_preference"
const val PREF_SNDEVENT_INTERCEPTION_END = "snd_interception_end_preference"
const val PREF_SNDEVENT_FILEUPDATE = "snd_fileupdate_preference"
const val PREF_SNDEVENT_FILETXCOMPLETE = "snd_filetx_complete_preference"

const val PREF_SUB_USERMSG = "sub_usertextmsg_preference"
const val PREF_SUB_CHANMSG = "sub_chantextmsg_preference"
const val PREF_SUB_BROADCAST = "sub_broadcastmsg_preference"
const val PREF_SUB_VOICE = "sub_voice_preference"
const val PREF_SUB_VIDEOCAP = "sub_videocapture_preference"
const val PREF_SUB_MEDIAFILE = "sub_mediafile_preference"
const val PREF_SUB_DESKTOP = "sub_desktop_preference"
const val PREF_SUB_DESKTOPINPUT = "sub_desktopinput_preference"

/** The speech engine's package; engines differ between devices, so it isn't synced. */
const val PREF_TTSEVENT_ENGINE = "android_tts_engine"
const val PREF_TTSEVENT_VOICEID = "tts_voiceid_preference"
const val PREF_TTSEVENT_VOICELANG = "tts_voicelang_preference"
const val PREF_TTSEVENT_JOINEDCHAN = "tts_joinedchan_preference"
const val PREF_TTSEVENT_LEFTCHAN = "tts_leftchan_preference"
const val PREF_TTSEVENT_CONLOST = "tts_conlost_preference"
const val PREF_TTSEVENT_TEXTMSG = "tts_usertxtmsg_preference"
const val PREF_TTSEVENT_CHANTEXTMSG = "tts_chantxtmsg_preference"
const val PREF_TTSEVENT_BROADCASTMSG = "tts_broadcasttxtmsg_preference"
const val PREF_TTSEVENT_RATE = "tts_rate_preference"
const val PREF_TTSEVENT_VOL = "tts_volume_preference"
const val PREF_TTSEVENT_USE_VOICEOVER = "tts_use_voiceover_preference"
const val PREF_TTSEVENT_USERLOGIN = "tts_user_login"
const val PREF_TTSEVENT_USERLOGOUT = "tts_user_logout"
const val PREF_TTSEVENT_SUBSCRIPTIONS = "tts_subscriptions_preference"
const val PREF_TTSEVENT_INTERCEPTION = "tts_interception_preference"
const val PREF_TTSEVENT_INTERCEPTION_START = "tts_interception_start_preference"
const val PREF_TTSEVENT_INTERCEPTION_END = "tts_interception_end_preference"
const val PREF_TTSEVENT_FILEUPDATE = "tts_fileupdate_preference"

const val PREF_RECORD_CHANNEL_FILE = "RecordChannelFile"
const val PREF_RECORD_USER_FILES = "RecordUserFiles"
const val PREF_RECORD_MEDIA_FILES = "RecordMediaFiles"

const val TT_STRLEN = 512
const val MAX_TEXTMESSAGES = 100
const val DEFAULT_LIMIT_TEXT = TT_STRLEN - 1

/** The app's settings. [revision] goes up with every change, for Compose screens to follow. */
object Prefs {
    lateinit var store: SharedPreferences
        private set
    val revision = mutableIntStateOf(0)
    private val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, _ -> revision.intValue++ }

    fun init(context: Context) {
        store = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
        store.registerOnSharedPreferenceChangeListener(listener)
    }

    fun has(key: String) = store.contains(key)

    // NG Account sync can bring a setting in another JSON type than this app
    // saves it (an iPhone's 50 as a number where this app has a float).
    private fun any(key: String): Any? = store.all[key]

    /** On unless turned off, which is how most of these settings default. */
    fun on(key: String, default: Boolean = true): Boolean = try {
        store.getBoolean(key, default)
    } catch (_: ClassCastException) {
        (any(key) as? Number)?.let { it.toInt() != 0 } ?: default
    }
    fun enabled(key: String, legacy: String? = null): Boolean = when {
        store.contains(key) -> on(key)
        legacy != null && store.contains(legacy) -> on(legacy)
        else -> true
    }
    fun int(key: String, default: Int): Int = try {
        store.getInt(key, default)
    } catch (_: ClassCastException) {
        (any(key) as? Number)?.toInt() ?: default
    }
    fun float(key: String, default: Float): Float = try {
        store.getFloat(key, default)
    } catch (_: ClassCastException) {
        (any(key) as? Number)?.toFloat() ?: default
    }
    fun string(key: String, default: String = ""): String = try {
        store.getString(key, default) ?: default
    } catch (_: ClassCastException) {
        default
    }
    fun set(key: String, value: Boolean) = store.edit().putBoolean(key, value).apply()
    fun set(key: String, value: Int) = store.edit().putInt(key, value).apply()
    fun set(key: String, value: Float) = store.edit().putFloat(key, value).apply()
    fun set(key: String, value: String) = store.edit().putString(key, value).apply()
    fun remove(key: String) = store.edit().remove(key).apply()
}

/** A slider's percent as a TeamTalk volume or gain level (50 % is the default level). */
fun refVolume(percent: Double): Int {
    if (percent == 0.0) return 0
    return (82.832 * exp(0.0508 * percent) - 50).toInt()
}

fun refVolumeToPercent(volume: Int): Int {
    if (volume == 0) return 0
    val d = (volume + 50.0) / 82.832
    return (ln(d) / 0.0508 + 0.5).toInt()
}

fun streamVolumePercent(key: String): Double =
    if (Prefs.has(key)) min(100.0, max(0.0, Prefs.float(key, 50f).toDouble())) else DEFAULT_AUDIO_LEVEL_PERCENT.toDouble()

/** Others' audio files relative to voice, in percent; null while never set. */
fun preferredAudioFileVolumePercent(): Double? =
    if (Prefs.has(PREF_MEDIAFILE_VOLUME)) Prefs.float(PREF_MEDIAFILE_VOLUME, 0.5f) * 100.0 else null

const val STATUSMODE_FEMALE = 0x00000100
const val STATUSMODE_STREAM_MEDIAFILE = 0x00000800
const val STATUSMODE_NEUTRAL = 0x00001000

/** 0 male, 1 female, 2 neutral (the default). */
fun preferredGenderIndex(): Int = min(max(if (Prefs.has(PREF_GENERAL_GENDER)) Prefs.int(PREF_GENERAL_GENDER, 2) else 2, 0), 2)

fun preferredStatusMode(): Int = when (preferredGenderIndex()) {
    1 -> STATUSMODE_FEMALE
    2 -> STATUSMODE_NEUTRAL
    else -> 0
}

fun preferredStatusMessage(): String = Prefs.string(PREF_GENERAL_STATUSMESSAGE)

fun shouldUnmuteByDefault(): Boolean = Prefs.on(PREF_GENERAL_PTTLOCK, false)

fun limitText(s: String): String {
    val length = if (Prefs.has(PREF_DISPLAY_LIMITTEXT)) Prefs.int(PREF_DISPLAY_LIMITTEXT, DEFAULT_LIMIT_TEXT) else DEFAULT_LIMIT_TEXT
    return if (s.length > length) s.take(length) else s
}

enum class FileSortField(val key: String) { Name("name"), Size("size"), Owner("owner"), Date("date") }

fun preferredFileSortField(): FileSortField =
    FileSortField.entries.firstOrNull { it.key == Prefs.string(PREF_FILES_SORT_FIELD) } ?: FileSortField.Name

fun preferredFileSortAscending(): Boolean = Prefs.on(PREF_FILES_SORT_ASCENDING)

fun saveFileSortPreferences(field: FileSortField, ascending: Boolean) {
    Prefs.set(PREF_FILES_SORT_FIELD, field.key)
    Prefs.set(PREF_FILES_SORT_ASCENDING, ascending)
}

/** ChanSort of the iPhone app: 0 by name, 1 by people in the channel. */
const val CHANSORT_ASCENDING = 0
const val CHANSORT_POPULARITY = 1
