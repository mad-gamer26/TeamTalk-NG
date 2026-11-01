/*
 * The channel's files, the audio file controls, and recording.
 */
package com.matthewdovi.teamtalkng.ui

import android.content.ClipboardManager
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import androidx.core.content.getSystemService
import android.text.format.Formatter
import com.matthewdovi.teamtalkng.*
import dk.bearware.ClientEvent
import dk.bearware.FileTransfer
import dk.bearware.FileTransferStatus
import dk.bearware.RemoteFile
import dk.bearware.UserRight
import dk.bearware.UserType
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.text.DateFormat
import java.text.SimpleDateFormat
import java.util.Locale

private class TransferState(
    val download: Boolean, val fileName: String, var transferred: Long, var fileSize: Long,
    val local: File?, val startedAt: Long, val identity: String?,
)

private fun byteCount(bytes: Long) = Formatter.formatShortFileSize(appContext, bytes)

private val uploadFormats = listOf("yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss")

private fun parsedDate(value: String) = uploadFormats.firstNotNullOfOrNull { f ->
    runCatching { SimpleDateFormat(f, Locale.US).apply { isLenient = false }.parse(value) }.getOrNull()
}

/** Which downloaded file each channel file is, with its hash. */
private object DownloadRecords {
    private val file get() = File(appContext.filesDir, "channel-downloads.json")
    private fun load() = runCatching { JSONObject(file.readText()) }.getOrDefault(JSONObject())
    fun record(identity: String): Pair<String, String>? = load().optJSONObject(identity)?.let { it.str("fileName") to it.str("sha256") }
    fun save(identity: String, fileName: String, sha: String) {
        file.writeText(load().put(identity, JSONObject().put("fileName", fileName).put("sha256", sha)).toString())
    }
    fun remove(identity: String) { file.writeText(load().apply { remove(identity) }.toString()) }
}

private fun downloadsDirectory() = File(appContext.getExternalFilesDir(null) ?: appContext.filesDir, "Downloads").apply { mkdirs() }

private fun hashFile(file: File): String {
    val digest = MessageDigest.getInstance("SHA-256")
    file.inputStream().use { input ->
        val buffer = ByteArray(1024 * 1024)
        while (true) {
            val n = input.read(buffer)
            if (n < 0) break
            digest.update(buffer, 0, n)
        }
    }
    return digest.digest().joinToString("") { "%02x".format(it) }
}

private fun uniqueFile(folder: File, name: String): File {
    var file = File(folder, name)
    var i = 1
    while (file.exists()) {
        val stem = name.substringBeforeLast('.', name)
        val ext = name.substringAfterLast('.', "")
        file = File(folder, if (ext.isEmpty()) "$stem-$i" else "$stem-$i.$ext")
        i++
    }
    return file
}

@Composable
fun FilesScreen(session: ServerSession) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val tt = session.tt
    val channelID = remember { tt.myChannelID }
    var files by remember { mutableStateOf(session.channelFiles(channelID)) }
    var query by remember { mutableStateOf("") }
    var status by remember { mutableStateOf("") }
    var sortMenu by remember { mutableStateOf(false) }
    val transfers = remember { HashMap<Int, TransferState>() }
    val uploads = remember { mutableSetOf<File>() }
    val canceled = remember { mutableSetOf<Int>() }
    /** The command asking for a transfer, until the transfer starts. */
    var pendingCommand by remember { mutableIntStateOf(0) }
    var pendingCanceled by remember { mutableStateOf(false) }
    var active by remember { mutableIntStateOf(0) }
    var shown by remember { mutableStateOf<TransferState?>(null) }
    var tick by remember { mutableIntStateOf(0) }
    var deleting by remember { mutableStateOf<RemoteFile?>(null) }
    Prefs.revision.intValue

    val isAdmin = session.myType and UserType.USERTYPE_ADMIN != 0
    fun right(flag: Int) = isAdmin || session.myRights and flag != 0
    val canUpload = right(UserRight.USERRIGHT_UPLOAD_FILES)
    val canDownload = right(UserRight.USERRIGHT_DOWNLOAD_FILES)
    fun canDelete(f: RemoteFile) = isAdmin || session.isOperator(session.myUserID, f.nChannelID) ||
        (!f.szUsername.isNullOrEmpty() && f.szUsername == session.myAccount.szUsername)

    fun refresh() { files = session.channelFiles(channelID) }
    fun identity(f: RemoteFile) = listOf(session.serverKey, f.nChannelID, f.nFileID, f.nFileSize, f.szUploadTime, f.szFileName).joinToString("|")

    fun finished(local: File, identity: String?) {
        scope.launch {
            val hash = withContext(Dispatchers.IO) { runCatching { hashFile(local) }.getOrNull() }
            if (identity != null && hash != null) DownloadRecords.save(identity, local.name, hash)
            announce("Download complete. ${local.name}")
            openFile(context, local)
        }
    }

    fun handleTransfer(incoming: FileTransfer) {
        val t = FileTransfer().also { if (!tt.getFileTransferInfo(incoming.nTransferID, it)) return@also }
            .takeIf { it.nTransferID != 0 } ?: incoming
        val id = t.nTransferID
        // The first event of a transfer: until now it was known by the
        // command that asked for it.
        val started = if (pendingCommand != 0) transfers.remove(pendingCommand) else null
        val dropped = pendingCanceled
        pendingCommand = 0
        pendingCanceled = false
        if (dropped) {
            canceled.add(id)
            tt.cancelFileTransfer(id)
        }
        val state = transfers[id] ?: started ?: TransferState(t.bInbound, t.szRemoteFileName.orEmpty(), t.nTransferred, t.nFileSize,
            t.szLocalFilePath?.let(::File), System.currentTimeMillis(), null)
        state.transferred = t.nTransferred
        state.fileSize = t.nFileSize
        transfers[id] = state
        fun done() {
            transfers.remove(id)
            canceled.remove(id)
            if (active == id) {
                active = 0
                shown = null
            }
        }
        when (t.nStatus) {
            FileTransferStatus.FILETRANSFER_FINISHED -> {
                done()
                status = ""
                if (state.download) {
                    state.local?.let { finished(it, state.identity) }
                    playSound(Sounds.FileTxComplete)
                } else {
                    state.local?.let { uploads.remove(it); it.delete() }
                    refresh()
                }
            }
            FileTransferStatus.FILETRANSFER_ERROR -> {
                done()
                status = ""
                if (!state.download) state.local?.let { uploads.remove(it); it.delete() }
            }
            FileTransferStatus.FILETRANSFER_ACTIVE -> {
                active = id
                shown = state
                tick++
            }
        }
    }

    SessionEvents(session) { m ->
        when (m.nClientEvent) {
            ClientEvent.CLIENTEVENT_CMD_FILE_NEW, ClientEvent.CLIENTEVENT_CMD_FILE_REMOVE -> if (m.remotefile.nChannelID == channelID) refresh()
            ClientEvent.CLIENTEVENT_FILETRANSFER -> handleTransfer(m.filetransfer)
            ClientEvent.CLIENTEVENT_CMD_ERROR -> {
                status = m.clienterrormsg.szErrorMsg.orEmpty()
                if (m.nSource == pendingCommand) {
                    // Refused, so no transfer is coming.
                    val state = transfers.remove(pendingCommand)
                    if (state?.download == false) state.local?.let { uploads.remove(it); it.delete() }
                    pendingCommand = 0
                    pendingCanceled = false
                    active = 0
                    shown = null
                }
            }
        }
    }
    LaunchedEffect(active) {
        while (active != 0) {
            delay(1000)
            val t = FileTransfer()
            if (pendingCommand == 0 && tt.getFileTransferInfo(active, t)) handleTransfer(t)
        }
    }
    DisposableEffect(Unit) {
        onDispose {
            uploads.forEach { it.delete() }
            uploads.clear()
        }
    }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        runCatching {
            val local = temporaryCopy(context, uri, "TeamTalk File")
            val id = tt.doSendFile(channelID, local.path)
            if (id < 0) {
                local.delete()
                status = "Could not upload file."
            } else {
                uploads.add(local)
                val state = TransferState(false, local.name, 0, local.length(), local, System.currentTimeMillis(), null)
                transfers[id] = state
                pendingCommand = id
                active = id
                shown = state
                status = ""
            }
        }.onFailure { status = it.message.orEmpty() }
    }

    fun beginDownload(f: RemoteFile, identity: String) {
        val safe = f.szFileName.orEmpty().substringAfterLast('/').ifBlank { "TeamTalk File" }
        val local = uniqueFile(downloadsDirectory(), safe)
        val id = tt.doRecvFile(f.nChannelID, f.nFileID, local.path)
        if (id < 0) {
            status = "Could not download file."
            return
        }
        val state = TransferState(true, f.szFileName.orEmpty(), 0, f.nFileSize, local, System.currentTimeMillis(), identity)
        transfers[id] = state
        pendingCommand = id
        active = id
        shown = state
        status = ""
    }

    fun download(f: RemoteFile) {
        if (!canDownload) return
        val id = identity(f)
        val record = DownloadRecords.record(id)
        val local = record?.let { File(downloadsDirectory(), it.first) }
        if (record != null && local != null && local.exists()) {
            status = "Checking downloaded file…"
            scope.launch {
                val hash = withContext(Dispatchers.IO) { runCatching { hashFile(local) }.getOrNull() }
                status = ""
                if (hash == record.second) openFile(context, local) else {
                    DownloadRecords.remove(id)
                    beginDownload(f, id)
                }
            }
        } else beginDownload(f, id)
    }

    val field = preferredFileSortField()
    val ascending = preferredFileSortAscending()
    val byName = compareBy<RemoteFile> { it.szFileName.orEmpty().lowercase() }
    val comparator: Comparator<RemoteFile> = when (field) {
        FileSortField.Name -> byName
        FileSortField.Size -> compareBy<RemoteFile> { it.nFileSize }.then(byName)
        FileSortField.Owner -> compareBy<RemoteFile> { it.szUsername.orEmpty().lowercase() }.then(byName)
        FileSortField.Date -> compareBy<RemoteFile> { parsedDate(it.szUploadTime.orEmpty())?.time ?: 0 }.then(byName)
    }
    val trimmedQuery = query.trim()
    val displayed = files.filter { trimmedQuery.isEmpty() || it.szFileName.orEmpty().contains(trimmedQuery, ignoreCase = true) }
        .sortedWith(if (ascending) comparator else comparator.reversed())

    ScreenFrame("Files", actions = {
        if (files.isNotEmpty()) {
            TextButton(onClick = { sortMenu = true }) { Text("Sort Files") }
            DropdownMenu(expanded = sortMenu, onDismissRequest = { sortMenu = false }) {
                FileSortField.entries.forEach {
                    DropdownMenuItem(text = { Text(if (it == field) "✓ ${it.name}" else it.name) },
                        onClick = { sortMenu = false; saveFileSortPreferences(it, ascending) })
                }
                listOf(true to "Ascending", false to "Descending").forEach { (value, label) ->
                    DropdownMenuItem(text = { Text(if (value == ascending) "✓ $label" else label) },
                        onClick = { sortMenu = false; saveFileSortPreferences(field, value) })
                }
            }
        }
        if (canUpload) IconButton(onClick = { picker.launch(arrayOf("*/*")) }) {
            Icon(Icons.Filled.Add, contentDescription = "Upload File")
        }
    }) {
        if (files.isNotEmpty()) {
            OutlinedTextField(query, { query = it }, label = { Text("Search Files") }, singleLine = true,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp))
        }
        if (status.isNotEmpty()) AnnouncedText(status, secondaryText(), Modifier.padding(16.dp))
        if (displayed.isEmpty()) {
            Column(Modifier.fillMaxWidth().padding(24.dp)) {
                Text(if (files.isEmpty()) "No files" else "No matching files", style = MaterialTheme.typography.titleMedium)
                Text(if (files.isEmpty()) "Files uploaded to this channel will appear here." else "Try a different search.", color = secondaryText())
            }
        } else {
            LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
                itemsIndexed(displayed, key = { _, f -> f.nFileID }) { i, f ->
                    val uploaded = f.szUploadTime.orEmpty().let { v ->
                        if (v.isEmpty()) "Unknown" else parsedDate(v)?.let { DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(it) } ?: v
                    }
                    ActionRow(
                        if (canDelete(f)) listOf(RowAction("Delete", destructive = true, swipe = true) { deleting = f }) else emptyList(),
                        shape = groupedItemShape(i, displayed.size),
                        onClick = if (canDownload) ({ download(f) }) else null,
                        onClickLabel = "Download and open",
                    ) {
                        Column(Modifier.fillMaxWidth().padding(RowPadding)) {
                            Text(f.szFileName.orEmpty(), style = MaterialTheme.typography.titleSmall)
                            Text(byteCount(f.nFileSize), style = MaterialTheme.typography.bodySmall, color = secondaryText())
                            Text("Uploaded by ${f.szUsername.orEmpty().ifEmpty { "Unknown" }} on $uploaded", style = MaterialTheme.typography.bodySmall, color = secondaryText())
                        }
                    }
                    if (i < displayed.size - 1) RowDivider()
                }
            }
        }
    }

    deleting?.let { f ->
        ConfirmationDialog("Delete ${f.szFileName}?", "Delete", onConfirm = {
            if (tt.doDeleteFile(f.nChannelID, f.nFileID) < 0) status = "Could not delete file."
        }, onDismiss = { deleting = null })
    }
    shown?.let { state ->
        tick
        val progress = if (state.fileSize > 0) (state.transferred.toFloat() / state.fileSize).coerceIn(0f, 1f) else 0f
        val elapsed = maxOf((System.currentTimeMillis() - state.startedAt) / 1000.0, 0.1)
        val done = if (state.download) "Downloaded" else "Uploaded"
        AlertDialog(
            onDismissRequest = {},
            title = { Text(if (state.download) "Downloading File" else "Uploading File") },
            text = {
                Column {
                    Text("File ${state.fileName}")
                    LinearProgressIndicator(progress = { progress }, modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp))
                    Text(if (state.fileSize > 0) "${(progress * 100).toInt()}%" else "Unknown")
                    Text(if (state.fileSize > 0) "$done ${byteCount(state.transferred)} of ${byteCount(state.fileSize)}" else "$done ${byteCount(state.transferred)}")
                    Text("Throughput ${byteCount((state.transferred / elapsed).toLong())}/s")
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    if (pendingCommand != 0) {
                        pendingCanceled = true
                    } else {
                        canceled.add(active)
                        tt.cancelFileTransfer(active)
                    }
                    active = 0
                    shown = null
                    status = ""
                }) { Text("Cancel") }
            },
        )
    }
    SessionAlertDialog(session)
}

/** The audio file controls. */
@Composable
fun AudioFileScreen(session: ServerSession) {
    val context = LocalContext.current
    val streaming = session.streaming
    session.tick.intValue
    Prefs.revision.intValue
    var choosing by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val allowed = streaming.isStreamingFile || streaming.canStreamAudioFiles()

    fun stream(uri: Uri, fallback: String) {
        runCatching { streaming.streamFile(temporaryCopy(context, uri, fallback)) }
            .onSuccess { problem -> error = problem }
            .onFailure { error = it.message ?: "Could not load audio from the clipboard." }
    }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> uri?.let { stream(it, "TeamTalk Audio") } }

    fun fromClipboard() {
        val clip = context.getSystemService<ClipboardManager>()?.primaryClip
        val uri = clip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.uri
        if (uri != null && (context.contentResolver.getType(uri)?.startsWith("audio") == true)) stream(uri, "Clipboard Audio")
        else error = "No audio was found on the clipboard."
    }

    ScreenFrame("Audio File") {
        GroupedBody {
            GroupedSection(footer = if (allowed) null else "You do not have permission to stream audio files on this server.") {
                if (streaming.isStreamingFile) {
                    TextRow(if (streaming.isFilePaused) "Resume Audio File" else "Pause Audio File", onClick = streaming::togglePause)
                    RowDivider()
                    TextRow("Stop Audio File", color = MaterialTheme.colorScheme.error, onClick = streaming::stopFile)
                } else {
                    TextRow("Stream Audio File", enabled = allowed, onClick = { choosing = true })
                }
            }
            GroupedSection(footer = "The audio file starts again from the beginning when it ends, until you stop it.") {
                ToggleRow("Loop", streaming.loops) { streaming.setLoops(it) }
            }
            GroupedSection(footer = "How loud the audio file is for everyone in the channel. 50 % leaves it as it is.") {
                PercentSlider("Streaming Volume", streamVolumePercent(PREF_STREAM_FILE_VOLUME).toInt() / 10 * 10) { streaming.setFileVolume(it.toDouble()) }
            }
        }
    }
    if (choosing) {
        ActionsDialog("Stream Audio File", actions = listOf(
            "Select File" to { picker.launch(arrayOf("audio/*")) },
            "Detect Clipboard" to { fromClipboard() },
        )) { choosing = false }
    }
    error?.let { MessageDialog("Audio File", it) { error = null } }
    SessionAlertDialog(session)
}

@Composable
fun RecordingScreen(session: ServerSession) {
    val recorder = session.recorder
    Prefs.revision.intValue
    var error by remember { mutableStateOf<String?>(null) }
    val choices = RecordingChoices.current
    val status = when {
        recorder.isRecording -> buildString {
            append("Recording ${recorder.channelName} since ${DateFormat.getTimeInstance(DateFormat.SHORT).format(recorder.since!!)}.")
            recorder.channelFile?.let { append(" File: ${it.name}.") }
            recorder.userFolder?.let { append(" Each person's files: ${it.name}.") }
        }
        recorder.wanted -> "Recording starts when you join a channel."
        else -> "Not recording."
    }
    ScreenFrame("Record") {
        GroupedBody {
            GroupedSection(footer = recorder.problem()) {
                // Starting and stopping are announced by the recorder.
                Text(status, modifier = Modifier.padding(RowPadding))
                RowDivider()
                if (recorder.wanted) {
                    TextRow("Stop Recording", color = MaterialTheme.colorScheme.error, onClick = { recorder.stop() })
                } else {
                    TextRow("Start Recording", onClick = { error = recorder.start() })
                }
            }
            GroupedSection(header = "What to Record", footer = "Your own voice is included. Changes apply to the next recording.") {
                ToggleRow("One file for the whole channel", choices.channelFile) { Prefs.set(PREF_RECORD_CHANNEL_FILE, it) }
                if (choices.channelFile) ToggleRow("Include Media Files", choices.mediaFiles) { Prefs.set(PREF_RECORD_MEDIA_FILES, it) }
                ToggleRow("A separate file for each person", choices.userFiles) { Prefs.set(PREF_RECORD_USER_FILES, it) }
            }
            GroupedSection { NavRow("Recordings") { Navigator.push(Screen.Recordings(recordingsDirectory())) } }
        }
    }
    error?.let { MessageDialog("Record", it) { error = null } }
    SessionAlertDialog(session)
}

/** The recordings in a folder, newest first: play, share or delete them. */
@Composable
fun RecordingsScreen(folder: File) {
    val context = LocalContext.current
    var revision by remember { mutableIntStateOf(0) }
    var chosen by remember { mutableStateOf<File?>(null) }
    val items = remember(revision, folder) { folder.listFiles().orEmpty().sortedByDescending { it.lastModified() } }

    fun delete(file: File) {
        if (file.deleteRecursively()) announce("Deleted ${file.name}.") else announce("The recording could not be deleted. It may still be recording.")
        revision++
    }

    ScreenFrame(folder.name) {
        if (items.isEmpty()) Text("No recordings yet.", modifier = Modifier.padding(24.dp))
        else LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
            itemsIndexed(items, key = { _, f -> f.path }) { i, file ->
                ActionRow(
                    listOf(RowAction("Delete", destructive = true, swipe = true) { delete(file) }),
                    shape = groupedItemShape(i, items.size),
                    onClick = { if (file.isDirectory) Navigator.push(Screen.Recordings(file)) else chosen = file },
                ) {
                    Column(Modifier.fillMaxWidth().padding(RowPadding)) {
                        Text(file.name)
                        Text(if (file.isDirectory) "Folder, ${file.list()?.size ?: 0} files" else byteCount(file.length()),
                            style = MaterialTheme.typography.bodySmall, color = secondaryText())
                    }
                }
                if (i < items.size - 1) RowDivider()
            }
        }
    }
    chosen?.let { file ->
        ActionsDialog(file.name, actions = listOf(
            "Play" to { openFile(context, file) },
            "Share" to { shareFile(context, file, "audio/wav") },
            "Delete" to { delete(file) },
        )) { chosen = null }
    }
}
