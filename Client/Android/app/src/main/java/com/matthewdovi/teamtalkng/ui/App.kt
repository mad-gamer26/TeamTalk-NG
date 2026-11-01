/*
 * The app's frame: the stack of screens, like the iPhone app's navigation
 * controller, and what every screen shares.
 */
package com.matthewdovi.teamtalkng.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import com.matthewdovi.teamtalkng.ServerLink
import com.matthewdovi.teamtalkng.MonitorPrivateChat
import com.matthewdovi.teamtalkng.Server
import com.matthewdovi.teamtalkng.ServerSession
import com.matthewdovi.teamtalkng.SessionManager
import com.matthewdovi.teamtalkng.TeamTalkApp
import dk.bearware.Channel
import java.io.File

sealed interface Screen {
    data object Settings : Screen
    data object SoundDevices : Screen
    data object SoundEvents : Screen
    data object SoundPacks : Screen
    data class SoundPackDetail(val packID: String) : Screen
    data object SoundCatalog : Screen
    data object TextToSpeechEvents : Screen
    data object SpeechVoices : Screen
    data object Account : Screen
    data object AccountDevices : Screen
    data class EditServer(val server: Server?) : Screen
    data object ReorderServers : Screen
    data class LinkDetails(val link: ServerLink) : Screen
    data class Session(val session: ServerSession) : Screen
    data class Messages(val session: ServerSession, val userID: Int) : Screen
    data class ChannelDetail(val session: ServerSession, val channel: Channel) : Screen
    data class UserDetail(val session: ServerSession, val userID: Int) : Screen
    data class MyInformation(val session: ServerSession) : Screen
    data class Files(val session: ServerSession) : Screen
    data class AudioFile(val session: ServerSession) : Screen
    data class AudioNet(val session: ServerSession) : Screen
    data class Recording(val session: ServerSession) : Screen
    data class Recordings(val folder: File) : Screen
    data class AudioControls(val session: ServerSession) : Screen
    data class AdminAccounts(val session: ServerSession) : Screen
    data class AdminBans(val session: ServerSession) : Screen
    data class ServerProperties(val session: ServerSession) : Screen
    data object Monitors : Screen
    data class MonitorSession(val ref: String, val serverID: Int) : Screen
    data class MonitorChat(val ref: String, val serverID: Int, val chat: MonitorPrivateChat) : Screen
    data class MonitorChannelChat(val ref: String, val serverID: Int) : Screen
    data class MonitorUser(val ref: String, val serverID: Int, val userID: Int) : Screen
    data class MonitorServerSettings(val ref: String, val serverID: Int) : Screen
    data class MonitorAdmin(val ref: String, val serverID: Int, val section: Int) : Screen
    data class MonitorConversations(val ref: String, val serverID: Int) : Screen
    data class MonitorSetUp(val server: Server) : Screen
    data object MonitorNotificationSettings : Screen
}

/** The stack of screens over the server list. It outlives the activity. */
object Navigator {
    val stack = mutableStateListOf<Screen>()
    /** A file or link waiting for the server list to deal with it. */
    val pendingImport = mutableStateOf<Uri?>(null)

    fun push(screen: Screen) { stack.add(screen) }
    fun pop() { if (stack.isNotEmpty()) stack.removeAt(stack.lastIndex) }
    fun popToRoot() { stack.clear() }

    /** Shows a session, as the only thing over the server list. */
    fun show(session: ServerSession) {
        SessionManager.active = session
        stack.clear()
        stack.add(Screen.Session(session))
    }

    /** A closed session's screens go. */
    fun closed(session: ServerSession) {
        stack.removeAll {
            when (it) {
                is Screen.Session -> it.session === session
                is Screen.Messages -> it.session === session
                is Screen.ChannelDetail -> it.session === session
                is Screen.UserDetail -> it.session === session
                is Screen.MyInformation -> it.session === session
                is Screen.Files -> it.session === session
                is Screen.AudioFile -> it.session === session
                is Screen.AudioNet -> it.session === session
                is Screen.Recording -> it.session === session
                is Screen.AudioControls -> it.session === session
                is Screen.AdminAccounts -> it.session === session
                is Screen.AdminBans -> it.session === session
                is Screen.ServerProperties -> it.session === session
                else -> false
            }
        }
    }
}

@Composable
fun TeamTalkNGApp() {
    TeamTalkTheme {
        Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surfaceContainerHigh)) {
            val screen = Navigator.stack.lastOrNull()
            BackHandler(enabled = screen != null) { Navigator.pop() }
            when (screen) {
                null -> ServerListScreen()
                Screen.Settings -> SettingsScreen()
                Screen.SoundDevices -> SoundDevicesScreen()
                Screen.SoundEvents -> SoundEventsScreen()
                Screen.SoundPacks -> SoundPacksScreen()
                is Screen.SoundPackDetail -> SoundPackDetailScreen(screen.packID)
                Screen.SoundCatalog -> SoundCatalogScreen()
                Screen.TextToSpeechEvents -> TextToSpeechEventsScreen()
                Screen.SpeechVoices -> SpeechVoicesScreen()
                Screen.Account -> AccountScreen()
                Screen.AccountDevices -> AccountDevicesScreen()
                is Screen.EditServer -> ServerDetailScreen(screen.server)
                Screen.ReorderServers -> ReorderServersScreen()
                is Screen.LinkDetails -> ServerLinkScreen(screen.link)
                is Screen.Session -> SessionScreen(screen.session)
                is Screen.Messages -> MessagesScreen(screen.session, screen.userID)
                is Screen.ChannelDetail -> ChannelDetailScreen(screen.session, screen.channel)
                is Screen.UserDetail -> UserDetailScreen(screen.session, screen.userID)
                is Screen.MyInformation -> MyInformationScreen(screen.session)
                is Screen.Files -> FilesScreen(screen.session)
                is Screen.AudioFile -> AudioFileScreen(screen.session)
                is Screen.AudioNet -> com.matthewdovi.teamtalkng.AudioNetContent(screen.session)
                is Screen.Recording -> RecordingScreen(screen.session)
                is Screen.Recordings -> RecordingsScreen(screen.folder)
                is Screen.AudioControls -> AudioControlsScreen(screen.session)
                is Screen.AdminAccounts -> AdminAccountsScreen(screen.session)
                is Screen.AdminBans -> AdminBansScreen(screen.session)
                is Screen.ServerProperties -> ServerPropertiesScreen(screen.session)
                Screen.Monitors -> MonitorsScreen()
                is Screen.MonitorSession -> MonitorSessionScreen(screen.ref, screen.serverID)
                is Screen.MonitorChat -> MonitorChatScreen(screen.ref, screen.serverID, screen.chat)
                is Screen.MonitorChannelChat -> MonitorChannelChatScreen(screen.ref, screen.serverID)
                is Screen.MonitorUser -> MonitorUserScreen(screen.ref, screen.serverID, screen.userID)
                is Screen.MonitorServerSettings -> MonitorServerEditScreen(screen.ref, screen.serverID, null)
                is Screen.MonitorAdmin -> MonitorAdminScreen(screen.ref, screen.serverID, screen.section)
                is Screen.MonitorConversations -> MonitorConversationsScreen(screen.ref, screen.serverID)
                is Screen.MonitorSetUp -> MonitorServerEditScreen(null, null, screen.server)
                Screen.MonitorNotificationSettings -> MonitorNotificationSettingsScreen()
            }
        }
    }
}

/** A screen with its title bar. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ScreenFrame(
    title: String,
    canGoBack: Boolean = true,
    onBack: () -> Unit = { Navigator.pop() },
    actions: @Composable RowScope.() -> Unit = {},
    bottom: @Composable ColumnScope.() -> Unit = {},
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().imePadding()) {
        TopAppBar(
            title = { Text(title, modifier = Modifier.semantics { heading() }) },
            navigationIcon = {
                if (canGoBack) {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                }
            },
            actions = actions,
            windowInsets = androidx.compose.foundation.layout.WindowInsets(0),
            colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh),
        )
        Column(Modifier.weight(1f)) { content() }
        bottom()
    }
}

/** The usual screen body: grouped sections, scrolling. */
@Composable
fun GroupedBody(content: @Composable ColumnScope.() -> Unit) {
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(PaddingValues(horizontal = 16.dp, vertical = 8.dp)),
        verticalArrangement = Arrangement.spacedBy(18.dp),
        content = content,
    )
}

/** Shares a file of this app's. */
fun shareFile(context: Context, file: File, mime: String) {
    val uri = FileProvider.getUriForFile(context, context.packageName + ".files", file)
    val send = Intent(Intent.ACTION_SEND).setType(mime).putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    context.startActivity(Intent.createChooser(send, file.name))
}

/** Opens a file of this app's in whatever plays or shows it. */
fun openFile(context: Context, file: File) {
    val uri = FileProvider.getUriForFile(context, context.packageName + ".files", file)
    val mime = context.contentResolver.getType(uri) ?: "*/*"
    val view = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    runCatching { context.startActivity(Intent.createChooser(view, file.name)) }
}

fun displayName(context: Context, uri: Uri): String? =
    context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
        if (it.moveToFirst()) it.getString(0) else null
    }

/** A temporary copy of a picked file, under its own name, not overwriting another. */
fun temporaryCopy(context: Context, uri: Uri, fallback: String): File {
    val name = (displayName(context, uri) ?: fallback).substringAfterLast('/').ifBlank { fallback }
    val folder = File(context.cacheDir, "picked").apply { mkdirs() }
    var file = File(folder, name)
    var index = 1
    while (file.exists()) {
        val stem = name.substringBeforeLast('.', name)
        val ext = name.substringAfterLast('.', "")
        file = File(folder, if (ext.isEmpty()) "$stem-$index" else "$stem-$index.$ext")
        index++
    }
    context.contentResolver.openInputStream(uri)!!.use { input -> file.outputStream().use { input.copyTo(it) } }
    return file
}

val appContext: Context get() = TeamTalkApp.context
