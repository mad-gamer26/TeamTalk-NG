/*
 * Settings, sound devices, sound events, sound packs and spoken events.
 */
package com.matthewdovi.teamtalkng.ui

import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.matthewdovi.teamtalkng.*
import dk.bearware.Subscription
import dk.bearware.TeamTalkBase
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

@Composable
private fun PrefToggle(label: String, key: String, default: Boolean = true, changed: (Boolean) -> Unit = {}) {
    Prefs.revision.intValue
    ToggleRow(label, Prefs.on(key, default)) {
        Prefs.set(key, it)
        changed(it)
    }
}

private fun saveAudioFileVolume(percent: Int) {
    Prefs.set(PREF_MEDIAFILE_VOLUME, percent / 100f)
    SessionManager.sessions.forEach { it.applyAudioFileVolumeToEveryone() }
}

@Composable
fun AudioFileVolumeSlider() {
    Prefs.revision.intValue
    val percent = (preferredAudioFileVolumePercent() ?: 50.0).toInt() / 10 * 10
    PercentSlider("Media File Volume", percent) { saveAudioFileVolume(it) }
}

@Composable
fun SettingsScreen() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var expanded by remember { mutableStateOf(setOf<String>()) }
    var nickname by remember { mutableStateOf(Prefs.string(PREF_GENERAL_NICKNAME)) }
    var statusMessage by remember { mutableStateOf(preferredStatusMessage()) }
    var limit by remember { mutableStateOf(Prefs.int(PREF_DISPLAY_LIMITTEXT, DEFAULT_LIMIT_TEXT).coerceIn(1, DEFAULT_LIMIT_TEXT).toString()) }
    var pinning by remember { mutableStateOf(false) }
    var shareLogs by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    Prefs.revision.intValue
    NGAccountCenter.revision.intValue
    val connected = SessionManager.sessions.any { it.isConnected }

    @Composable
    fun Section(title: String, footer: String? = null, content: @Composable () -> Unit) {
        DisclosureSection(title, title in expanded, { expanded = if (it) expanded + title else expanded - title }) {
            content()
            if (footer != null) Text(footer, style = MaterialTheme.typography.bodySmall, color = secondaryText())
        }
    }

    @Composable
    fun Sub(label: String, key: String) = SwitchRow(label, Prefs.on(key), { Prefs.set(key, it) })

    ScreenFrame("Settings") {
        GroupedBody {
            Section("General") {
                OutlinedTextField(nickname, {
                    nickname = it
                    Prefs.set(PREF_GENERAL_NICKNAME, it)
                    SessionManager.sessions.forEach { s -> if (s.isConnected) s.tt.doChangeNickname(it) }
                }, label = { Text("Nickname") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(statusMessage, {
                    statusMessage = it
                    Prefs.set(PREF_GENERAL_STATUSMESSAGE, it)
                    SessionManager.sessions.forEach { s -> s.applyPreferredStatus() }
                }, label = { Text("Status Message") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                ChoiceRow("Gender", listOf(0 to "Male", 1 to "Female", 2 to "Neutral"), preferredGenderIndex()) {
                    Prefs.set(PREF_GENERAL_GENDER, it)
                    SessionManager.sessions.forEach { s -> s.applyPreferredStatus() }
                }
                SwitchRow("Unmute by Default", Prefs.on(PREF_GENERAL_PTTLOCK, false), { Prefs.set(PREF_GENERAL_PTTLOCK, it) })
                SwitchRow("Return Sends Message", Prefs.on(PREF_GENERAL_SENDONRETURN), { Prefs.set(PREF_GENERAL_SENDONRETURN, it) })
            }
            Section("Display") {
                SwitchRow("Show Text Messages Instantly", Prefs.on(PREF_DISPLAY_POPUPTXTMSG), { Prefs.set(PREF_DISPLAY_POPUPTXTMSG, it) })
                OutlinedTextField(limit, {
                    limit = it.filter(Char::isDigit)
                    limit.toIntOrNull()?.let { n -> Prefs.set(PREF_DISPLAY_LIMITTEXT, n.coerceIn(1, DEFAULT_LIMIT_TEXT)) }
                }, label = { Text("Maximum Text Length") }, singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), modifier = Modifier.fillMaxWidth())
                SwitchRow("Show Usernames Instead of Nicknames", Prefs.on(PREF_DISPLAY_SHOWUSERNAME, false), { Prefs.set(PREF_DISPLAY_SHOWUSERNAME, it) })
                ChoiceRow("Sort Channels", listOf(CHANSORT_ASCENDING to "Ascending", CHANSORT_POPULARITY to "Popularity"),
                    Prefs.int(PREF_DISPLAY_SORTCHANNELS, CHANSORT_ASCENDING)) { Prefs.set(PREF_DISPLAY_SORTCHANNELS, it) }
                ChoiceRow("Sort Files By", FileSortField.entries.map { it to it.name }, preferredFileSortField()) {
                    saveFileSortPreferences(it, preferredFileSortAscending())
                }
                ChoiceRow("Order", listOf(true to "Ascending", false to "Descending"), preferredFileSortAscending()) {
                    saveFileSortPreferences(preferredFileSortField(), it)
                }
            }
            // While connected these are per server, under Audio Controls.
            if (!connected) Section("Sound System") {
                PercentSlider("Master Volume", Prefs.int(PREF_MASTER_VOLUME, DEFAULT_AUDIO_LEVEL_PERCENT)) { Prefs.set(PREF_MASTER_VOLUME, it) }
                PercentSlider("Input Gain", Prefs.int(PREF_MICROPHONE_GAIN, DEFAULT_AUDIO_LEVEL_PERCENT)) { Prefs.set(PREF_MICROPHONE_GAIN, it) }
                AudioFileVolumeSlider()
                TextRow("Sound Devices", horizontalPadding = 0.dp, onClick = { Navigator.push(Screen.SoundDevices) })
            }
            Section("Sound Events") {
                TextRow("Sound Events", horizontalPadding = 0.dp, onClick = { Navigator.push(Screen.SoundEvents) })
                TextRow("Sound Packs", horizontalPadding = 0.dp, onClick = { Navigator.push(Screen.SoundPacks) })
            }
            Section("Text To Speech Events") {
                SwitchRow("Use TalkBack when Available", Prefs.on(PREF_TTSEVENT_USE_VOICEOVER), { Prefs.set(PREF_TTSEVENT_USE_VOICEOVER, it) })
                val voice = Prefs.string(PREF_TTSEVENT_VOICEID).removePrefix("language:").ifEmpty { "Default" }
                NavRow("Voice", voice) { Navigator.push(Screen.SpeechVoices) }
                val rate = Prefs.float(PREF_TTSEVENT_RATE, 0.5f)
                SliderRow("Speech Rate", rate, 0f, 1f, 0, "${(rate * 100).toInt()} %") { Prefs.set(PREF_TTSEVENT_RATE, it) }
                val volume = Prefs.float(PREF_TTSEVENT_VOL, 1f)
                SliderRow("Speech Volume", volume, 0f, 1f, 0, "${(volume * 100).toInt()} %") { Prefs.set(PREF_TTSEVENT_VOL, it) }
                TextRow("Text to Speech Events", horizontalPadding = 0.dp, onClick = { Navigator.push(Screen.TextToSpeechEvents) })
            }
            Section("Connection") {
                SwitchRow("Join Root Channel", Prefs.on(PREF_JOINROOTCHANNEL), { Prefs.set(PREF_JOINROOTCHANNEL, it) })
            }
            Section("Default Subscriptions") {
                Sub("User Messages", PREF_SUB_USERMSG)
                Sub("Channel Messages", PREF_SUB_CHANMSG)
                Sub("Broadcast Messages", PREF_SUB_BROADCAST)
                Sub("Voice", PREF_SUB_VOICE)
                Sub("WebCam", PREF_SUB_VIDEOCAP)
                Sub("Media File", PREF_SUB_MEDIAFILE)
                Sub("Desktop", PREF_SUB_DESKTOP)
            }
            Section("Shortcuts", "Your saved servers appear when you hold down the app's icon. A shortcut on your home screen quickly connects to one.") {
                TextRow("Add Shortcut", horizontalPadding = 0.dp, onClick = {
                    if (ServerStore.servers.none { it.name.isNotBlank() }) message = "No saved servers are available." else pinning = true
                })
            }
            Section("Sync") {
                NavRow("NG Account", NGAccountCenter.email ?: "Not Signed In") { Navigator.push(Screen.Account) }
            }
            Section("About") {
                ValueRow("App Version", "TeamTalk NG v${BuildConfig.VERSION_NAME} Build ${BuildConfig.VERSION_CODE}, Library v${TeamTalkBase.getVersion()}")
                TextRow("Share Diagnostic Logs", horizontalPadding = 0.dp, onClick = { shareLogs = true })
                TextRow("Check for Updates", horizontalPadding = 0.dp, onClick = {
                    scope.launch { message = Updater.check(context) }
                })
            }
        }
    }

    if (pinning) {
        ActionsDialog("Select a Shortcut", actions = ServerStore.servers.filter { it.name.isNotBlank() }.map { server ->
            "Connect to ${server.name}" to {
                if (!pinShortcut(context, server)) message = "This launcher can't add shortcuts."
                Unit
            }
        }) { pinning = false }
    }
    if (shareLogs) {
        ConfirmationDialog(
            "Diagnostic logs may contain sensitive information, including server addresses, usernames, file names, and error details. Only share them with people you trust.",
            "Share", destructive = false,
            onConfirm = {
                scope.launch {
                    val result = runCatching { withContext(Dispatchers.IO) { exportDiagnosticLogs() } }
                    result.onSuccess { shareFile(context, it, "application/zip") }.onFailure { message = it.message }
                }
            },
            onDismiss = { shareLogs = false },
        )
    }
    message?.let { MessageDialog("TeamTalk NG", it) { message = null } }
}

/** This app's log, zipped. */
private fun exportDiagnosticLogs(): File {
    val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
    val log = ProcessBuilder("logcat", "-d", "-v", "threadtime", "--pid=${android.os.Process.myPid()}")
        .redirectErrorStream(true).start().inputStream.bufferedReader().readText()
    val metadata = "TeamTalk NG ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})\nLibrary ${TeamTalkBase.getVersion()}\n" +
        "${Build.MANUFACTURER} ${Build.MODEL}, Android ${Build.VERSION.RELEASE} (${Build.VERSION.SDK_INT})\n"
    val file = File(appContext.cacheDir, "TTNG_Logs_$stamp.zip")
    ZipOutputStream(file.outputStream()).use { zip ->
        for ((name, text) in listOf("metadata.txt" to metadata, "app.log" to log)) {
            zip.putNextEntry(ZipEntry(name))
            zip.write(text.toByteArray())
            zip.closeEntry()
        }
    }
    return file
}

/** Where sound goes, voice processing and microphones. */
@Composable
private fun SoundSettings() {
    Prefs.revision.intValue
    AudioRouting.revision.intValue
    GroupedSection(footer = "Automatic plays as media: through headphones or Bluetooth when connected, otherwise the speaker. Choosing a device, using Voice Preprocessing or choosing a microphone puts the phone in call audio, which is mono and lower quality on Bluetooth.") {
        ChoiceRow("Audio Output", AudioRouting.outputs().map { it.key to it.name }, AudioRouting.selectedOutput) {
            Prefs.set(PREF_AUDIO_OUTPUT, it)
            SessionManager.restoreSoundDevices()
        }
    }
    GroupedSection(footer = AudioRouting.processingDescription()) {
        PrefToggle("Voice Preprocessing", PREF_VOICE_PROCESSING, false) { SessionManager.restoreSoundDevices() }
    }
    GroupedSection(footer = "In call audio Android uses one device for input and output, so a headset microphone also takes the sound, whatever Audio Output says.") {
        ChoiceRow("Microphone", AudioRouting.microphones().map { it.key to it.name }, AudioRouting.selectedMicrophone) {
            Prefs.set(PREF_SNDINPUT_DEVICE, it)
            SessionManager.restoreSoundDevices()
        }
    }
}

@Composable
fun SoundDevicesScreen() {
    ScreenFrame("Sound Devices") { GroupedBody { SoundSettings() } }
}

@Composable
fun AudioControlsScreen(session: ServerSession) {
    val many = SessionManager.sessions.size > 1
    var output by remember { mutableIntStateOf(if (many) refVolumeToPercent(session.tt.soundOutputVolume) else Prefs.int(PREF_MASTER_VOLUME, DEFAULT_AUDIO_LEVEL_PERCENT)) }
    var input by remember { mutableIntStateOf(if (many) refVolumeToPercent(session.tt.soundInputGainLevel) else Prefs.int(PREF_MICROPHONE_GAIN, DEFAULT_AUDIO_LEVEL_PERCENT)) }
    ScreenFrame("Audio Controls") {
        GroupedBody {
            GroupedSection {
                PercentSlider("Master Volume", output / 10 * 10) {
                    output = it
                    session.tt.setSoundOutputVolume(refVolume(it.toDouble()))
                    if (!many) Prefs.set(PREF_MASTER_VOLUME, it)
                }
                PercentSlider("Input Gain", input / 10 * 10) {
                    input = it
                    session.tt.setSoundInputGainLevel(refVolume(it.toDouble()))
                    if (!many) Prefs.set(PREF_MICROPHONE_GAIN, it)
                }
                AudioFileVolumeSlider()
            }
            if (many) Text("Global Settings", style = MaterialTheme.typography.titleSmall)
            SoundSettings()
        }
    }
}

private val soundEventDetails = listOf(
    Sounds.SrvLost, Sounds.TxOn, Sounds.TxOff, Sounds.UserMsg, Sounds.ChanMsg, Sounds.BroadcastMsg, Sounds.LoggedIn,
    Sounds.LoggedOut, Sounds.JoinedChan, Sounds.LeftChan, Sounds.TransmitOn, Sounds.TransmitOff, Sounds.InterceptStart,
    Sounds.InterceptEnd, Sounds.FileUpdate, Sounds.FileTxComplete,
)

/** Rows of things to turn on and off, with Enable All and Disable All. */
@Composable
private fun <T> CheckList(title: String, sectionTitle: String, rows: List<T>, name: (T) -> String, on: (T) -> Boolean, set: (T, Boolean) -> Unit, preview: ((T) -> Unit)? = null) {
    Prefs.revision.intValue
    val all = rows.all(on)
    ScreenFrame(title, actions = {
        TextButton(onClick = { rows.forEach { set(it, !all) } }) { Text(if (all) "Disable All" else "Enable All") }
    }) {
        GroupedBody {
            GroupedSection(header = sectionTitle) {
                rows.forEachIndexed { i, row ->
                    if (i > 0) RowDivider()
                    val checked = on(row)
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .heightIn(min = 48.dp)
                            .clickable { set(row, !checked) }
                            .semantics(mergeDescendants = true) {
                                role = Role.Checkbox
                                stateDescription = if (checked) "Checked" else "Not checked"
                                if (preview != null) customActions = listOf(CustomAccessibilityAction("Preview") { preview(row); true })
                            }
                            .padding(horizontal = 16.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(name(row), modifier = Modifier.weight(1f))
                        if (checked) SelectedTick()
                        if (preview != null) TextButton(onClick = { preview(row) }, modifier = Modifier.clearAndSetSemantics {}) { Text("▶") }
                    }
                }
            }
        }
    }
}

@Composable
fun SoundEventsScreen() {
    CheckList("Sound Events", "Sound Events", soundEventDetails, { it.title }, { it.enabled },
        { sound, on -> Prefs.set(sound.prefKey, on) }, { SoundPlayer.play(it) })
}

private val speechEvents = listOf(
    "User logged in" to PREF_TTSEVENT_USERLOGIN,
    "User logged out" to PREF_TTSEVENT_USERLOGOUT,
    "User joins channel" to PREF_TTSEVENT_JOINEDCHAN,
    "User leaves channel" to PREF_TTSEVENT_LEFTCHAN,
    "Connection lost" to PREF_TTSEVENT_CONLOST,
    "Private Text Message" to PREF_TTSEVENT_TEXTMSG,
    "Channel Text Message" to PREF_TTSEVENT_CHANTEXTMSG,
    "Broadcast Text Message" to PREF_TTSEVENT_BROADCASTMSG,
    "Subscription Changes" to PREF_TTSEVENT_SUBSCRIPTIONS,
    "Interception Started" to PREF_TTSEVENT_INTERCEPTION_START,
    "Interception Ended" to PREF_TTSEVENT_INTERCEPTION_END,
    "Channel File Updates" to PREF_TTSEVENT_FILEUPDATE,
)

@Composable
fun TextToSpeechEventsScreen() {
    CheckList("Text to Speech Events", "Announcements", speechEvents, { it.first },
        { (_, key) ->
            when (key) {
                PREF_TTSEVENT_INTERCEPTION_START, PREF_TTSEVENT_INTERCEPTION_END -> Prefs.enabled(key, PREF_TTSEVENT_INTERCEPTION)
                else -> Prefs.on(key)
            }
        },
        { (_, key), on -> Prefs.set(key, on) })
}

@Composable
fun SpeechVoicesScreen() {
    LaunchedEffect(Unit) { Speech.prepare() }
    Prefs.revision.intValue
    val selected = Prefs.string(PREF_TTSEVENT_VOICEID)
    val choices = Speech.choices
    ScreenFrame("Voice") {
        GroupedBody {
            if (Speech.engines.size > 1) GroupedSection(footer = "Engines are the speech apps installed on this phone.") {
                ChoiceRow("Speech Engine", listOf("" to "Phone's default") + Speech.engines.map { it.packageName to it.label },
                    Prefs.string(PREF_TTSEVENT_ENGINE)) { Speech.useEngine(it) }
            }
            GroupedSection(footer = when (Speech.state) {
                Speech.State.Failed -> "This speech engine didn't start. Choose another, or check it in Android's text to speech settings."
                Speech.State.Ready -> if (choices.isEmpty()) "This speech engine doesn't list any voices." else null
                else -> "Loading voices"
            }) {
                ChoiceRow("Voice", listOf("" to "Default") + choices.map { it.id to it.label }, selected) { id ->
                    val choice = choices.firstOrNull { it.id == id }
                    if (choice == null) {
                        Prefs.remove(PREF_TTSEVENT_VOICEID)
                        Prefs.remove(PREF_TTSEVENT_VOICELANG)
                        Speech.preview("You have selected Default")
                    } else {
                        Prefs.set(PREF_TTSEVENT_VOICEID, choice.id)
                        Prefs.set(PREF_TTSEVENT_VOICELANG, choice.languageTag)
                        Speech.preview("You have selected ${choice.label}")
                    }
                }
            }
        }
    }
}

// MARK: Sound packs

@Composable
fun SoundPacksScreen() {
    val context = LocalContext.current
    SoundPackStore.revision.intValue
    var creating by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf<SoundPack?>(null) }
    var deleteAll by remember { mutableStateOf(false) }
    var naming by remember { mutableStateOf<SoundPack?>(null) }
    var error by remember { mutableStateOf<String?>(null) }

    fun attempt(work: () -> Unit) = runCatching(work).onFailure { error = it.message }

    val importer = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) attempt {
            val name = displayName(context, uri)?.substringBeforeLast('.') ?: "Imported Sound Pack"
            context.contentResolver.openInputStream(uri)!!.use { naming = SoundPackStore.importArchive(it, name) }
        }
    }

    ScreenFrame("Sound Packs") {
        GroupedBody {
            GroupedSection(header = "Sound Packs") {
                SoundPackStore.allPacks.forEach { pack ->
                    val actions = if (pack.isDefault) emptyList() else listOf(
                        RowAction("Edit") { Navigator.push(Screen.SoundPackDetail(pack.id)) },
                        RowAction("Export") {
                            attempt {
                                shareFile(context, SoundPackStore.exportPackArchive(pack.id, context.cacheDir), "application/zip")
                            }
                        },
                        RowAction("Delete", destructive = true, swipe = true) { deleting = pack },
                    )
                    ActionRow(actions, onClick = { SoundPackStore.selectPack(pack.id) }, selected = pack.id == SoundPackStore.selectedPackID) {
                        Row(Modifier.fillMaxWidth().padding(RowPadding), verticalAlignment = Alignment.CenterVertically) {
                            Text(pack.name, modifier = Modifier.weight(1f))
                            if (pack.id == SoundPackStore.selectedPackID) SelectedTick()
                        }
                    }
                    RowDivider()
                }
                TextRow("Create Sound Pack", onClick = { creating = true })
                TextRow("Import Sound Pack", onClick = { importer.launch(arrayOf("application/zip", "application/octet-stream")) })
                TextRow("Browse Sound Packs", onClick = { Navigator.push(Screen.SoundCatalog) })
                if (SoundPackStore.customPacks.isNotEmpty()) {
                    TextRow("Delete All Custom Sound Packs", color = MaterialTheme.colorScheme.error, onClick = { deleteAll = true })
                }
            }
        }
    }
    if (creating) {
        TextEntryDialog("New Sound Pack", "Sound Pack Name", "Create", onDismiss = { creating = false }) {
            attempt { Navigator.push(Screen.SoundPackDetail(SoundPackStore.createPack(it).id)) }
        }
    }
    naming?.let { pack ->
        TextEntryDialog("Sound Pack Name", "Sound Pack Name", "OK", pack.name,
            "You can optionally choose a new name for this sound pack. Leave blank to keep the name of the zip file.",
            onDismiss = { naming = null }) { name ->
            if (name.isNotBlank()) attempt { SoundPackStore.renamePack(pack.id, name) }
        }
    }
    deleting?.let { pack ->
        val inAccount = NGPackSync.accountPack(pack.id)
        val note = when {
            inAccount?.public == true -> " It's also deleted from your NG Account and your other devices, and leaves the catalog (people who installed it keep their copy)."
            inAccount != null -> " It's also deleted from your NG Account and your other devices."
            else -> ""
        }
        ConfirmationDialog("Delete ${pack.name}?$note", "Delete", onConfirm = { attempt { SoundPackStore.deletePack(pack.id) } }, onDismiss = { deleting = null })
    }
    if (deleteAll) {
        val inAccount = SoundPackStore.customPacks.count { NGPackSync.accountPack(it.id) != null }
        val note = if (inAccount > 0) " $inAccount of them are in your NG Account and will be deleted from it and your other devices too." else ""
        ConfirmationDialog("This deletes every sound pack except the default one.$note", "Delete All",
            onConfirm = { attempt { SoundPackStore.deleteAllCustomPacks() } }, onDismiss = { deleteAll = false })
    }
    error?.let { MessageDialog("Sound Pack Error", it) { error = null } }
}

@Composable
fun SoundPackDetailScreen(packID: String) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    SoundPackStore.revision.intValue
    NGAccountCenter.revision.intValue
    val pack = SoundPackStore.pack(packID)
    var renaming by remember { mutableStateOf(false) }
    var replacing by remember { mutableStateOf<Sounds?>(null) }
    var publishing by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    if (pack == null) {
        LaunchedEffect(Unit) { Navigator.pop() }
        return
    }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        val sound = replacing
        replacing = null
        if (uri != null && sound != null) runCatching {
            val extension = displayName(context, uri)?.substringAfterLast('.', "wav") ?: "wav"
            context.contentResolver.openInputStream(uri)!!.use { SoundPackStore.replaceSound(sound, packID, it, extension) }
        }.onFailure { error = it.message }
    }
    val owned = NGPackSync.owns(pack.catalogID)
    ScreenFrame(pack.name) {
        GroupedBody {
            GroupedSection { NavRow("Name", pack.name) { renaming = true } }
            GroupedSection(header = "Sounds") {
                Sounds.entries.forEachIndexed { i, sound ->
                    val custom = SoundPackStore.hasCustomSound(sound, packID)
                    if (i > 0) RowDivider()
                    ActionRow(
                        buildList {
                            add(RowAction("Replace") { replacing = sound; picker.launch(arrayOf("audio/*")) })
                            if (custom) add(RowAction("Reset to Default", destructive = true) {
                                runCatching { SoundPackStore.resetSound(sound, packID) }.onFailure { error = it.message }
                            })
                        },
                        onClick = { SoundPlayer.play(sound, packID) },
                        onClickLabel = "Preview",
                    ) {
                        Row(Modifier.fillMaxWidth().padding(RowPadding)) {
                            Text(sound.title, modifier = Modifier.weight(1f))
                            Text(if (custom) "Custom" else "Default", color = secondaryText())
                        }
                    }
                }
            }
            GroupedSection(
                header = "NG Account",
                footer = when {
                    owned -> "This catalog pack is yours. Sounds you change here are published as a new version for everyone who installed it."
                    NGAccountCenter.isSignedIn -> "Your packs are backed up to your NG Account. Publish one to share it in the catalog."
                    else -> "Sign in to your NG Account to back up your packs and share them in the catalog."
                },
            ) {
                TextRow(
                    when {
                        owned -> "Manage in Catalog"
                        NGAccountCenter.isSignedIn -> "Publish to Catalog"
                        else -> "Sign In or Create Account"
                    },
                    onClick = { if (NGAccountCenter.isSignedIn) publishing = true else Navigator.push(Screen.Account) },
                )
            }
        }
    }
    if (renaming) {
        TextEntryDialog("Name", "Sound Pack Name", "OK", pack.name, onDismiss = { renaming = false }) {
            runCatching { SoundPackStore.renamePack(packID, it) }.onFailure { e -> error = e.message }
        }
    }
    if (publishing) {
        PublishPackDialog(pack, onDismiss = { publishing = false }) { problem -> error = problem }
    }
    error?.let { MessageDialog("Sound Pack Error", it) { error = null } }
}

/** A pack's name, maker and description in the catalog. */
@Composable
private fun PublishPackDialog(pack: SoundPack, onDismiss: () -> Unit, failed: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    val account = NGPackSync.accountPack(pack.id) ?: pack.catalogID?.let { NGPackSync.ownedCatalogPacks[it] }
    var name by remember { mutableStateOf(account?.name ?: pack.name) }
    var author by remember { mutableStateOf(account?.author.orEmpty()) }
    var description by remember { mutableStateOf(account?.description.orEmpty()) }
    val published = account?.public == true
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (published) "Manage in Catalog" else "Publish to Catalog") },
        text = {
            Column {
                if (account == null) Text("This pack hasn't been backed up to your NG Account yet. Try again in a moment.")
                OutlinedTextField(name, { name = it }, label = { Text("Pack Name") }, singleLine = true)
                OutlinedTextField(author, { author = it }, label = { Text("Your Name") }, singleLine = true)
                OutlinedTextField(description, { description = it }, label = { Text("Description") })
            }
        },
        confirmButton = {
            TextButton(enabled = account != null, onClick = {
                onDismiss()
                scope.launch {
                    runCatching {
                        NGAccountCenter.signed { it.changePack(account!!.id, name, author, description, true) }
                        NGPackSync.syncNow()
                    }.onFailure { failed(it.message ?: "The pack could not be published.") }
                }
            }) { Text(if (published) "Save" else "Publish") }
        },
        dismissButton = {
            if (published) TextButton(onClick = {
                onDismiss()
                scope.launch {
                    runCatching {
                        NGAccountCenter.signed { it.changePack(account!!.id, public = false) }
                        NGPackSync.syncNow()
                    }.onFailure { failed(it.message ?: "The pack could not be unpublished.") }
                }
            }) { Text("Unpublish") } else TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

/** Browsing the catalog, and updating installed packs. */
@Composable
fun SoundCatalogScreen() {
    val scope = rememberCoroutineScope()
    SoundPackStore.revision.intValue
    var packs by remember { mutableStateOf<List<RemoteSoundPack>?>(null) }
    var busy by remember { mutableStateOf(setOf<String>()) }
    var reporting by remember { mutableStateOf<RemoteSoundPack?>(null) }
    var signInNote by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        runCatching { SoundCatalog.catalog() }.onSuccess { packs = it }.onFailure { error = it.message; packs = emptyList() }
    }

    suspend fun install(pack: RemoteSoundPack, select: Boolean) {
        busy = busy + pack.id
        runCatching {
            val data = SoundCatalog.download(pack)
            SoundPackStore.importCatalogArchive(data.inputStream(), pack, select)
            NGAccountAPI(null).countInstall(pack.id)
        }.onFailure { error = it.message }
        busy = busy - pack.id
    }

    val list = packs
    val updates = list?.let { SoundPackStore.updatesAvailable(it) }.orEmpty()
    val missing = list.orEmpty().filter { SoundPackStore.installedPack(it.id) == null }
    ScreenFrame("Browse Sound Packs", actions = {
        if (updates.isNotEmpty()) TextButton(onClick = { scope.launch { updates.forEach { install(it, false) } } }) { Text("Update All") }
        else if (missing.isNotEmpty()) TextButton(onClick = {
            scope.launch {
                val selected = SoundPackStore.selectedPackID
                missing.forEach { install(it, false) }
                SoundPackStore.selectPack(selected)
            }
        }) { Text("Download All") }
    }) {
        GroupedBody {
            GroupedSection(header = "Sound Packs") {
                when {
                    list == null -> Row(Modifier.padding(RowPadding), verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.padding(end = 12.dp))
                        Text("Retrieving Sound Packs...")
                    }
                    list.isEmpty() -> Text("No packs available.", modifier = Modifier.padding(RowPadding))
                    else -> list.forEachIndexed { i, pack ->
                        if (i > 0) RowDivider()
                        val installed = SoundPackStore.installedPack(pack.id)
                        val state = when {
                            pack.id in busy -> "Downloading..."
                            installed == null -> "Download"
                            installed.version != pack.version -> "Update"
                            else -> "Installed"
                        }
                        ActionRow(
                            listOf(RowAction("Report", destructive = true) {
                                if (NGAccountCenter.isSignedIn) reporting = pack else signInNote = true
                            }),
                            onClick = { if (state == "Download" || state == "Update") scope.launch { install(pack, true) } },
                            onClickLabel = state,
                        ) {
                            Column(Modifier.fillMaxWidth().padding(RowPadding)) {
                                Text("${pack.name} - $state")
                                Text(
                                    (if (pack.official) "Official · " else "") + "Created by ${pack.author}, Version ${pack.version}" +
                                        (pack.description?.let { "\n$it" } ?: ""),
                                    style = MaterialTheme.typography.bodySmall, color = secondaryText(),
                                )
                            }
                        }
                    }
                }
            }
        }
    }
    reporting?.let { pack ->
        TextEntryDialog("Report ${pack.name}", "Reason", "Report", message = "What's wrong with this pack?", onDismiss = { reporting = null }) { reason ->
            scope.launch {
                runCatching { NGAccountCenter.signed { it.report(pack.id, reason) } }
                    .onSuccess { announce("Reported. Thank you.") }.onFailure { error = it.message }
            }
        }
    }
    if (signInNote) MessageDialog("Sign In to Report", "Reporting a pack needs an NG Account.") { signInNote = false }
    error?.let { MessageDialog("Sound Pack Error", it) { error = null } }
}
