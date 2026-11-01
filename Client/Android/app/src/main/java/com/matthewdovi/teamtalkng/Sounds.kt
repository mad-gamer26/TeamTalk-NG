/*
 * The app's event sounds and sound packs.
 */
package com.matthewdovi.teamtalkng

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import androidx.compose.runtime.mutableIntStateOf
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.util.UUID
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

enum class Sounds(val fileName: String, val title: String) {
    TxOn("on", "Voice Transmission On"),
    TxOff("off", "Voice Transmission Off"),
    ChanMsg("channel_msg", "Channel Text Message"),
    BroadcastMsg("broadcast_msg", "Broadcast Text Message"),
    UserMsg("user_msg", "Private Text Message"),
    SrvLost("serverlost", "Server Connection Lost"),
    JoinedChan("newuser", "User Joins Channel"),
    LeftChan("removeuser", "User Leaves Channel"),
    TransmitOn("txqueue_start", "Exclusive Mode On"),
    TransmitOff("txqueue_stop", "Exclusive Mode Off"),
    LoggedIn("logged_on", "User Logged In"),
    LoggedOut("logged_off", "User Logged Out"),
    InterceptStart("intercept", "Interception Started"),
    InterceptEnd("interceptEnd", "Interception Ended"),
    FileUpdate("fileupdate", "Channel File Updated"),
    FileTxComplete("filetx_complete", "File Transfer Complete");

    val enabled: Boolean
        get() = when (this) {
            TxOn -> Prefs.enabled(PREF_SNDEVENT_VOICETX_ON, PREF_SNDEVENT_VOICETX)
            TxOff -> Prefs.enabled(PREF_SNDEVENT_VOICETX_OFF, PREF_SNDEVENT_VOICETX)
            ChanMsg -> Prefs.on(PREF_SNDEVENT_CHANMSG)
            UserMsg -> Prefs.on(PREF_SNDEVENT_USERMSG)
            BroadcastMsg -> Prefs.on(PREF_SNDEVENT_BCASTMSG)
            SrvLost -> Prefs.on(PREF_SNDEVENT_SERVERLOST)
            JoinedChan -> Prefs.on(PREF_SNDEVENT_JOINEDCHAN)
            LeftChan -> Prefs.on(PREF_SNDEVENT_LEFTCHAN)
            TransmitOn -> Prefs.enabled(PREF_SNDEVENT_TRANSMITREADY_ON, PREF_SNDEVENT_TRANSMITREADY)
            TransmitOff -> Prefs.enabled(PREF_SNDEVENT_TRANSMITREADY_OFF, PREF_SNDEVENT_TRANSMITREADY)
            LoggedIn -> Prefs.on(PREF_SNDEVENT_LOGGEDIN)
            LoggedOut -> Prefs.on(PREF_SNDEVENT_LOGGEDOUT)
            InterceptStart -> Prefs.enabled(PREF_SNDEVENT_INTERCEPTION_START, PREF_SNDEVENT_INTERCEPTION)
            InterceptEnd -> Prefs.enabled(PREF_SNDEVENT_INTERCEPTION_END, PREF_SNDEVENT_INTERCEPTION)
            FileUpdate -> Prefs.on(PREF_SNDEVENT_FILEUPDATE)
            FileTxComplete -> Prefs.on(PREF_SNDEVENT_FILETXCOMPLETE)
        }

    /** The preference that turns this sound on and off in Sound Events. */
    val prefKey: String
        get() = when (this) {
            TxOn -> PREF_SNDEVENT_VOICETX_ON
            TxOff -> PREF_SNDEVENT_VOICETX_OFF
            ChanMsg -> PREF_SNDEVENT_CHANMSG
            UserMsg -> PREF_SNDEVENT_USERMSG
            BroadcastMsg -> PREF_SNDEVENT_BCASTMSG
            SrvLost -> PREF_SNDEVENT_SERVERLOST
            JoinedChan -> PREF_SNDEVENT_JOINEDCHAN
            LeftChan -> PREF_SNDEVENT_LEFTCHAN
            TransmitOn -> PREF_SNDEVENT_TRANSMITREADY_ON
            TransmitOff -> PREF_SNDEVENT_TRANSMITREADY_OFF
            LoggedIn -> PREF_SNDEVENT_LOGGEDIN
            LoggedOut -> PREF_SNDEVENT_LOGGEDOUT
            InterceptStart -> PREF_SNDEVENT_INTERCEPTION_START
            InterceptEnd -> PREF_SNDEVENT_INTERCEPTION_END
            FileUpdate -> PREF_SNDEVENT_FILEUPDATE
            FileTxComplete -> PREF_SNDEVENT_FILETXCOMPLETE
        }
}

data class SoundPack(
    val id: String,
    var name: String,
    var author: String? = null,
    var createdAt: Long = 0,
    var catalogID: String? = null,
    var version: String? = null,
) {
    val isDefault get() = id == SoundPackStore.DEFAULT_ID
}

data class RemoteSoundPack(
    val id: String,
    val name: String,
    val author: String,
    val description: String?,
    val version: String,
    val downloadURL: String,
    val official: Boolean,
)

class SoundPackException(message: String) : Exception(message)

object SoundPackStore {
    const val DEFAULT_ID = "default"
    private const val SELECTED_KEY = "settings.selectedSoundPackID"
    /** What the iPhone app takes, and what Android plays. */
    private val extensions = listOf("mp3", "wav", "caf", "aiff", "aif", "m4a", "aac", "ogg", "flac")
    private lateinit var root: File
    private lateinit var appContext: Context

    /** Goes up with every change, for Compose screens and for sync to follow. */
    val revision = mutableIntStateOf(0)
    var customPacks: List<SoundPack> = emptyList()
        private set
    var selectedPackID = DEFAULT_ID
        private set

    val defaultPack get() = SoundPack(DEFAULT_ID, "Default")
    val allPacks get() = listOf(defaultPack) + customPacks
    val selectedPack get() = pack(selectedPackID) ?: defaultPack

    fun init(context: Context) {
        appContext = context.applicationContext
        root = File(context.filesDir, "SoundPacks").apply { mkdirs() }
        load()
    }

    private fun changed() {
        revision.intValue++
        MonitorNotificationSounds.refresh()
    }

    fun pack(id: String) = if (id == DEFAULT_ID) defaultPack else customPacks.firstOrNull { it.id == id }
    private fun dir(id: String) = File(root, id)
    fun installedPack(catalogID: String) = customPacks.firstOrNull { it.catalogID == catalogID }
    fun updatesAvailable(catalog: List<RemoteSoundPack>) =
        catalog.filter { r -> installedPack(r.id)?.let { it.version != r.version } == true }

    fun selectPack(id: String) {
        selectedPackID = pack(id)?.id ?: DEFAULT_ID
        Prefs.set(SELECTED_KEY, selectedPackID)
        changed()
    }

    fun createPack(name: String): SoundPack {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) throw SoundPackException("Enter a sound pack name.")
        val pack = SoundPack(UUID.randomUUID().toString(), trimmed, createdAt = System.currentTimeMillis())
        dir(pack.id).mkdirs()
        customPacks = sorted(customPacks + pack)
        save()
        selectPack(pack.id)
        return pack
    }

    fun renamePack(id: String, name: String) {
        if (id == DEFAULT_ID) throw SoundPackException("The default sound pack cannot be edited or deleted.")
        val trimmed = name.trim()
        if (trimmed.isEmpty()) throw SoundPackException("Enter a sound pack name.")
        val pack = pack(id) ?: throw SoundPackException("The sound pack could not be found.")
        pack.name = trimmed
        customPacks = sorted(customPacks)
        save()
        changed()
    }

    fun deletePack(id: String) {
        if (id == DEFAULT_ID) throw SoundPackException("The default sound pack cannot be edited or deleted.")
        customPacks = customPacks.filter { it.id != id }
        dir(id).deleteRecursively()
        if (selectedPackID == id) selectPack(DEFAULT_ID)
        save()
        changed()
    }

    fun deleteAllCustomPacks() {
        customPacks.forEach { dir(it.id).deleteRecursively() }
        customPacks = emptyList()
        selectPack(DEFAULT_ID)
        save()
    }

    fun setVersion(version: String, id: String) {
        val pack = pack(id) ?: return
        if (pack.version != version) {
            pack.version = version
            save()
        }
    }

    private fun customSound(sound: Sounds, packID: String): File? {
        if (packID == DEFAULT_ID) return null
        return extensions.map { File(dir(packID), "${sound.fileName}.$it") }.firstOrNull { it.exists() }
    }

    fun hasCustomSound(sound: Sounds, packID: String) = customSound(sound, packID) != null
    fun hasCustomSounds(packID: String) = Sounds.entries.any { hasCustomSound(it, packID) }

    /** The pack's own sounds, by file name such as `logged_on.wav`. */
    fun customSoundFiles(packID: String): List<Pair<String, File>> = Sounds.entries.mapNotNull { sound ->
        customSound(sound, packID)?.let { "${sound.fileName}.${it.extension.lowercase()}" to it }
    }

    /** The sound's file in a pack; null means the app's own sound. */
    fun soundFile(sound: Sounds, packID: String = selectedPackID) = customSound(sound, packID)

    private fun removeCustomSound(sound: Sounds, packID: String) {
        extensions.forEach { File(dir(packID), "${sound.fileName}.$it").delete() }
    }

    fun replaceSound(sound: Sounds, packID: String, input: InputStream, extension: String) {
        if (packID == DEFAULT_ID) throw SoundPackException("The default sound pack cannot be edited or deleted.")
        if (pack(packID) == null) throw SoundPackException("The sound pack could not be found.")
        val d = dir(packID).apply { mkdirs() }
        removeCustomSound(sound, packID)
        File(d, "${sound.fileName}.${extension.ifEmpty { "wav" }.lowercase()}").outputStream().use { input.copyTo(it) }
        changed()
    }

    fun resetSound(sound: Sounds, packID: String) {
        if (packID == DEFAULT_ID) throw SoundPackException("The default sound pack cannot be edited or deleted.")
        removeCustomSound(sound, packID)
        changed()
    }

    /** Put one sound (by file name, such as `logged_on.wav`) into a pack. */
    fun writeSound(data: ByteArray, fileName: String, packID: String) {
        val stem = fileName.substringBeforeLast('.')
        val sound = Sounds.entries.firstOrNull { it.fileName == stem } ?: return
        val d = dir(packID).apply { mkdirs() }
        removeCustomSound(sound, packID)
        File(d, fileName).writeBytes(data)
        changed()
    }

    fun removeSound(fileName: String, packID: String) {
        val stem = fileName.substringBeforeLast('.')
        Sounds.entries.firstOrNull { it.fileName == stem }?.let { removeCustomSound(it, packID); changed() }
    }

    fun exportPackArchive(id: String, into: File): File {
        val pack = pack(id)?.takeIf { !it.isDefault } ?: throw SoundPackException("The default sound pack cannot be edited or deleted.")
        val out = File(into, pack.name.replace(Regex("[/\\\\?%*|\"<>:]"), "-").ifBlank { "Sound Pack" } + ".zip")
        ZipOutputStream(out.outputStream()).use { zip ->
            customSoundFiles(id).forEach { (name, file) ->
                zip.putNextEntry(ZipEntry(name))
                file.inputStream().use { it.copyTo(zip) }
                zip.closeEntry()
            }
        }
        return out
    }

    /** The sounds in a zip, by normalized file name. */
    private fun readSounds(input: InputStream): Map<String, ByteArray> {
        val names = Sounds.entries.map { it.fileName }.toSet()
        val entries = LinkedHashMap<String, ByteArray>()
        ZipInputStream(input).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                if (entry.isDirectory) continue
                val file = entry.name.substringAfterLast('/')
                val stem = file.substringBeforeLast('.')
                val ext = file.substringAfterLast('.', "").lowercase()
                if (stem in names && ext in extensions) entries.getOrPut("$stem.$ext") { zip.readBytes() }
            }
        }
        if (entries.isEmpty()) throw SoundPackException("This ZIP archive does not contain any supported TeamTalk sound files.")
        return entries
    }

    private fun write(id: String, entries: Map<String, ByteArray>) {
        val d = dir(id)
        d.deleteRecursively()
        d.mkdirs()
        entries.forEach { (name, data) -> File(d, name).writeBytes(data) }
    }

    fun importArchive(input: InputStream, name: String): SoundPack {
        val entries = readSounds(input)
        val pack = SoundPack(UUID.randomUUID().toString(), uniqueName(name), createdAt = System.currentTimeMillis())
        write(pack.id, entries)
        customPacks = sorted(customPacks + pack)
        save()
        selectPack(pack.id)
        return pack
    }

    fun importCatalogArchive(input: InputStream, remote: RemoteSoundPack, selectAfter: Boolean = true): SoundPack {
        val entries = readSounds(input)
        val existing = installedPack(remote.id)
        val pack = SoundPack(existing?.id ?: UUID.randomUUID().toString(), remote.name, remote.author,
            existing?.createdAt ?: System.currentTimeMillis(), remote.id, remote.version)
        write(pack.id, entries)
        customPacks = sorted(customPacks.filter { it.id != pack.id } + pack)
        save()
        if (selectAfter) selectPack(pack.id) else changed()
        return pack
    }

    /** Puts back a pack from the NG Account, as it was on the device that backed it up. */
    fun restoreArchive(input: InputStream, id: String, name: String): SoundPack {
        val entries = readSounds(input)
        val pack = SoundPack(id, name, createdAt = pack(id)?.createdAt ?: System.currentTimeMillis())
        write(id, entries)
        customPacks = sorted(customPacks.filter { it.id != id } + pack)
        save()
        changed()
        return pack
    }

    private fun uniqueName(proposed: String): String {
        val trimmed = proposed.trim().ifEmpty { return "Imported Sound Pack" }
        val names = allPacks.map { it.name.lowercase() }.toSet()
        if (trimmed.lowercase() !in names) return trimmed
        var suffix = 2
        while ("$trimmed $suffix".lowercase() in names) suffix++
        return "$trimmed $suffix"
    }

    private fun sorted(list: List<SoundPack>) = list.sortedBy { it.name.lowercase() }

    private fun load() {
        selectedPackID = Prefs.string(SELECTED_KEY, DEFAULT_ID)
        val file = File(root, "metadata.json")
        customPacks = runCatching {
            val a = JSONArray(file.readText())
            sorted((0 until a.length()).map { i ->
                val j = a.getJSONObject(i)
                SoundPack(j.getString("id"), j.getString("name"), j.optString("author").ifEmpty { null },
                    j.optLong("createdAt"), j.optString("catalogID").ifEmpty { null }, j.optString("version").ifEmpty { null })
            })
        }.getOrDefault(emptyList())
        if (pack(selectedPackID) == null) selectedPackID = DEFAULT_ID
    }

    private fun save() {
        val a = JSONArray()
        customPacks.forEach {
            a.put(JSONObject().put("id", it.id).put("name", it.name).put("author", it.author ?: "")
                .put("createdAt", it.createdAt).put("catalogID", it.catalogID ?: "").put("version", it.version ?: ""))
        }
        File(root, "metadata.json").writeText(a.toString())
        revision.intValue++
    }
}

/** Plays event sounds alongside TeamTalk's audio, without taking audio focus. */
object SoundPlayer {
    private lateinit var context: Context
    private val attributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .build()

    fun init(appContext: Context) { context = appContext }

    /** Plays a sound; [done] runs when it has finished. */
    fun play(sound: Sounds, packID: String = SoundPackStore.selectedPackID, done: () -> Unit = {}) {
        runCatching {
            val player = MediaPlayer()
            player.setAudioAttributes(attributes)
            val file = SoundPackStore.soundFile(sound, packID)
            if (file != null) {
                player.setDataSource(file.path)
            } else {
                context.assets.openFd("sounds/${sound.fileName}.wav").use {
                    player.setDataSource(it.fileDescriptor, it.startOffset, it.length)
                }
            }
            player.setOnCompletionListener { it.release(); done() }
            player.setOnErrorListener { p, _, _ -> p.release(); done(); true }
            player.setOnPreparedListener { it.start() }
            player.prepareAsync()
        }.onFailure { done() }
    }
}

/** Plays a sound when its event is turned on. */
fun playSound(sound: Sounds) {
    if (sound.enabled) SoundPlayer.play(sound)
}
