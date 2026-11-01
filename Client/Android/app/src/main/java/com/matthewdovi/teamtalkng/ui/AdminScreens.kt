/*
 * Managing a server: accounts, bans, its properties, and your own information.
 * The same screens serve a live connection and a monitor (MonitorAdmin.kt):
 * each gives them an AdminBackend.
 */
package com.matthewdovi.teamtalkng.ui

import android.content.ClipData
import android.content.ClipboardManager
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.core.content.getSystemService
import com.matthewdovi.teamtalkng.DEFAULT_TCPPORT
import com.matthewdovi.teamtalkng.DEFAULT_UDPPORT
import com.matthewdovi.teamtalkng.Server
import com.matthewdovi.teamtalkng.ServerFiles
import com.matthewdovi.teamtalkng.ServerSession
import com.matthewdovi.teamtalkng.announce
import dk.bearware.BannedUser
import dk.bearware.ClientEvent
import dk.bearware.ServerLogEvent
import dk.bearware.ServerProperties
import dk.bearware.UserAccount
import dk.bearware.UserRight
import dk.bearware.UserType
import java.io.File
import java.net.URLEncoder

enum class AccountKind(val title: String) {
    DefaultUser("Default User"), Administrator("Administrator"), Disabled("Disabled");

    val sdkType get() = when (this) {
        DefaultUser -> UserType.USERTYPE_DEFAULT
        Administrator -> UserType.USERTYPE_ADMIN
        Disabled -> UserType.USERTYPE_NONE
    }

    companion object {
        fun of(type: Int) = when {
            type and UserType.USERTYPE_ADMIN != 0 -> Administrator
            type and UserType.USERTYPE_DEFAULT != 0 -> DefaultUser
            else -> Disabled
        }
    }
}

data class AdminAccount(val username: String, val password: String, val note: String, val initChannel: String, val type: Int, val rights: Int, val raw: UserAccount? = null) {
    val kind get() = AccountKind.of(type)
}

data class AdminBan(val ipAddress: String, val username: String, val nickname: String, val channelPath: String, val banTime: String, val owner: String, val banTypes: Int) {
    val id get() = listOf(ipAddress, username, channelPath, banTime).joinToString("|")
}

class ServerPropertiesForm {
    var serverName by mutableStateOf("")
    var motd by mutableStateOf("")
    var maxUsers by mutableStateOf("")
    var maxLoginAttempts by mutableStateOf("")
    var maxLoginsPerIPAddress by mutableStateOf("")
    var maxVoiceTxPerSecond by mutableStateOf("")
    var maxVideoCaptureTxPerSecond by mutableStateOf("")
    var maxMediaFileTxPerSecond by mutableStateOf("")
    var maxDesktopTxPerSecond by mutableStateOf("")
    var maxTotalTxPerSecond by mutableStateOf("")
    var autoSave by mutableStateOf(false)
    var tcpPort by mutableStateOf("")
    var udpPort by mutableStateOf("")
    var userTimeout by mutableStateOf("")
    var loginDelayMSec by mutableStateOf("")
    var serverLogEvents by mutableIntStateOf(0)
}

/** How accounts, bans and properties reach the server. */
abstract class AdminBackend(val server: Server) {
    val accounts = mutableStateListOf<AdminAccount>()
    val bans = mutableStateListOf<AdminBan>()
    var status by mutableStateOf("")
    var loadingAccounts by mutableStateOf(false)
    var loadingBans by mutableStateOf(false)
    val form = ServerPropertiesForm()
    /** Run when the properties were saved. */
    var saved: () -> Unit = {}

    abstract fun refreshAccounts()
    abstract fun refreshBans()
    abstract fun createAccount(a: AdminAccount)
    abstract fun editAccount(original: AdminAccount, a: AdminAccount)
    abstract fun deleteAccount(a: AdminAccount)
    abstract fun unban(b: AdminBan)
    abstract fun loadProperties()
    abstract fun saveProperties()
    abstract fun publicServerName(): String
    open fun start() {}
    open fun stop() {}

    protected fun upsert(a: AdminAccount) {
        val i = accounts.indexOfFirst { it.username == a.username }
        if (i >= 0) accounts[i] = a else accounts.add(a)
        val sorted = accounts.sortedBy { it.username.lowercase() }
        accounts.clear()
        accounts.addAll(sorted)
    }

    protected fun upsert(b: AdminBan) {
        val i = bans.indexOfFirst { it.id == b.id }
        if (i >= 0) bans[i] = b else bans.add(b)
        val sorted = bans.sortedBy { it.ipAddress.lowercase() }
        bans.clear()
        bans.addAll(sorted)
    }

    fun ttLink(a: AdminAccount): String {
        fun esc(v: String) = URLEncoder.encode(v, "UTF-8").replace("+", "%20")
        val parts = buildList {
            if (server.tcpport != DEFAULT_TCPPORT) add("tcpport=${server.tcpport}")
            if (server.udpport != DEFAULT_UDPPORT) add("udpport=${server.udpport}")
            if (server.encrypted) add("encrypted=true")
            add("username=${esc(a.username)}")
            add("password=${esc(a.password)}")
            if (a.initChannel.isNotEmpty()) add("channel=${esc(a.initChannel)}")
        }
        return "tt://${server.ipaddr}?${parts.joinToString("&")}"
    }

    fun writeTTFile(a: AdminAccount, fileName: String, entryName: String): File {
        val clean = fileName.trim().replace(Regex("[/\\\\?%*|\"<>:]"), "-").ifEmpty { a.username.ifEmpty { "TeamTalk Server" } }
        val file = File(appContext.cacheDir, "$clean.tt")
        val host = server.copy(
            name = entryName.trim().ifEmpty { publicServerName() }, username = a.username, password = a.password,
            nickname = "", statusmsg = "", channel = a.initChannel, chanpasswd = "",
        )
        file.writeText(ServerFiles.export(listOf(host)))
        return file
    }
}

/** The connected server's accounts, bans and properties. */
class SessionAdmin(private val session: ServerSession) : AdminBackend(session.server) {
    private val tt get() = session.tt
    private var accountCmd = 0
    private var banCmd = 0
    private var updateCmd = 0
    private val mutations = mutableSetOf<Int>()
    private val pendingEdits = HashMap<Int, UserAccount>()
    private var properties = ServerProperties()

    private val listener: (dk.bearware.TTMessage) -> Unit = { m -> handle(m) }
    override fun start() { session.listeners.add(listener) }
    override fun stop() { session.listeners.remove(listener) }

    private fun raw(a: AdminAccount, base: UserAccount? = a.raw) = UserAccount().also { u ->
        base?.let { u.copy(it) }
        u.szUsername = a.username.trim()
        u.szPassword = a.password
        u.szNote = a.note
        u.szInitChannel = a.initChannel
        u.uUserType = a.kind.sdkType
        u.uUserRights = if (a.kind == AccountKind.DefaultUser) a.rights else 0
    }

    private fun parse(u: UserAccount) = AdminAccount(u.szUsername.orEmpty(), u.szPassword.orEmpty(), u.szNote.orEmpty(), u.szInitChannel.orEmpty(), u.uUserType, u.uUserRights, u)
    private fun parse(b: BannedUser) = AdminBan(b.szIPAddress.orEmpty(), b.szUsername.orEmpty(), b.szNickname.orEmpty(), b.szChannelPath.orEmpty(), b.szBanTime.orEmpty(), b.szOwner.orEmpty(), b.uBanTypes)

    override fun refreshAccounts() {
        accounts.clear()
        loadingAccounts = true
        accountCmd = tt.doListUserAccounts(0, 100_000)
        if (accountCmd < 0) { loadingAccounts = false; status = "Could not request accounts" }
    }

    override fun refreshBans() {
        bans.clear()
        loadingBans = true
        banCmd = tt.doListBans(0, 0, 100_000)
        if (banCmd < 0) { loadingBans = false; status = "Could not request bans" }
    }

    private fun track(id: Int, fallback: String) { if (id < 0) status = fallback else mutations.add(id) }

    override fun createAccount(a: AdminAccount) {
        if (a.username.isBlank()) { status = "Username is required"; return }
        track(tt.doNewUserAccount(raw(a)), "Could not create account")
    }

    override fun editAccount(original: AdminAccount, a: AdminAccount) {
        if (a.username.isBlank()) { status = "Username is required"; return }
        val id = tt.doDeleteUserAccount(original.username)
        if (id < 0) status = "Could not edit account" else pendingEdits[id] = raw(a, original.raw)
    }

    override fun deleteAccount(a: AdminAccount) = track(tt.doDeleteUserAccount(a.username), "Could not delete account")

    override fun unban(b: AdminBan) {
        val banned = BannedUser().apply { szIPAddress = b.ipAddress; szUsername = b.username; uBanTypes = b.banTypes }
        track(tt.doUnBanUserEx(banned), "Could not remove ban")
    }

    override fun publicServerName(): String {
        val p = ServerProperties()
        val name = if (tt.getServerProperties(p)) p.szServerName.orEmpty().trim() else ""
        return name.ifEmpty { server.name.trim().ifEmpty { server.ipaddr } }
    }

    override fun loadProperties() {
        if (!tt.getServerProperties(properties)) { status = "Could not load server properties"; return }
        val p = properties
        form.serverName = p.szServerName.orEmpty()
        form.motd = p.szMOTDRaw.orEmpty()
        form.maxUsers = "${p.nMaxUsers}"
        form.maxLoginAttempts = "${p.nMaxLoginAttempts}"
        form.maxLoginsPerIPAddress = "${p.nMaxLoginsPerIPAddress}"
        form.maxVoiceTxPerSecond = "${p.nMaxVoiceTxPerSecond}"
        form.maxVideoCaptureTxPerSecond = "${p.nMaxVideoCaptureTxPerSecond}"
        form.maxMediaFileTxPerSecond = "${p.nMaxMediaFileTxPerSecond}"
        form.maxDesktopTxPerSecond = "${p.nMaxDesktopTxPerSecond}"
        form.maxTotalTxPerSecond = "${p.nMaxTotalTxPerSecond}"
        form.autoSave = p.bAutoSave
        form.tcpPort = "${p.nTcpPort}"
        form.udpPort = "${p.nUdpPort}"
        form.userTimeout = "${p.nUserTimeout}"
        form.loginDelayMSec = "${p.nLoginDelayMSec}"
        form.serverLogEvents = p.uServerLogEvents
    }

    override fun saveProperties() {
        fun n(v: String) = v.trim().toIntOrNull() ?: 0
        val p = properties
        p.szServerName = form.serverName
        p.szMOTDRaw = form.motd
        p.nMaxUsers = n(form.maxUsers)
        p.nMaxLoginAttempts = n(form.maxLoginAttempts)
        p.nMaxLoginsPerIPAddress = n(form.maxLoginsPerIPAddress)
        p.nMaxVoiceTxPerSecond = n(form.maxVoiceTxPerSecond)
        p.nMaxVideoCaptureTxPerSecond = n(form.maxVideoCaptureTxPerSecond)
        p.nMaxMediaFileTxPerSecond = n(form.maxMediaFileTxPerSecond)
        p.nMaxDesktopTxPerSecond = n(form.maxDesktopTxPerSecond)
        p.nMaxTotalTxPerSecond = n(form.maxTotalTxPerSecond)
        p.bAutoSave = form.autoSave
        p.nTcpPort = n(form.tcpPort)
        p.nUdpPort = n(form.udpPort)
        p.nUserTimeout = n(form.userTimeout)
        p.nLoginDelayMSec = n(form.loginDelayMSec)
        p.uServerLogEvents = form.serverLogEvents
        updateCmd = tt.doUpdateServer(p)
        status = if (updateCmd < 0) "Could not update server properties" else "Updating server properties"
    }

    private fun complete(id: Int) {
        if (id == accountCmd) { loadingAccounts = false; accountCmd = 0 }
        if (id == banCmd) { loadingBans = false; banCmd = 0 }
        if (id == updateCmd) updateCmd = 0
        if (mutations.remove(id)) { refreshAccounts(); refreshBans() }
        pendingEdits.remove(id)?.let { track(tt.doNewUserAccount(it), "Could not edit account") }
    }

    private fun handle(m: dk.bearware.TTMessage) {
        when (m.nClientEvent) {
            ClientEvent.CLIENTEVENT_CMD_USERACCOUNT, ClientEvent.CLIENTEVENT_CMD_USERACCOUNT_NEW -> upsert(parse(m.useraccount))
            ClientEvent.CLIENTEVENT_CMD_BANNEDUSER -> upsert(parse(m.banneduser))
            ClientEvent.CLIENTEVENT_CMD_USERACCOUNT_REMOVE -> {
                accounts.removeAll { it.username == m.useraccount.szUsername }
                status = "Deleted ${m.useraccount.szUsername}"
            }
            ClientEvent.CLIENTEVENT_CMD_SERVER_UPDATE -> if (updateCmd != 0) {
                properties = m.serverproperties
                loadProperties()
                status = "Server properties updated"
                updateCmd = 0
                saved()
            }
            ClientEvent.CLIENTEVENT_CMD_PROCESSING -> if (!m.bActive) complete(m.nSource)
            ClientEvent.CLIENTEVENT_CMD_ERROR -> {
                pendingEdits.remove(m.nSource)
                if (m.nSource == updateCmd) updateCmd = 0
                complete(m.nSource)
                status = m.clienterrormsg.szErrorMsg.orEmpty()
            }
        }
    }
}

private val defaultRegularRights = UserRight.USERRIGHT_MULTI_LOGIN or UserRight.USERRIGHT_VIEW_ALL_USERS or
    UserRight.USERRIGHT_CREATE_TEMPORARY_CHANNEL or UserRight.USERRIGHT_UPLOAD_FILES or UserRight.USERRIGHT_DOWNLOAD_FILES or
    UserRight.USERRIGHT_TRANSMIT_VOICE or UserRight.USERRIGHT_TRANSMIT_VIDEOCAPTURE or UserRight.USERRIGHT_TRANSMIT_DESKTOP or
    UserRight.USERRIGHT_TRANSMIT_DESKTOPINPUT or UserRight.USERRIGHT_TRANSMIT_MEDIAFILE_AUDIO or UserRight.USERRIGHT_TRANSMIT_MEDIAFILE_VIDEO or
    UserRight.USERRIGHT_TEXTMESSAGE_USER or UserRight.USERRIGHT_TEXTMESSAGE_CHANNEL

private class RightOption(val title: String, val flag: Int, val inverted: Boolean = false)

private val rightOptions = listOf(
    RightOption("Log in multiple times", UserRight.USERRIGHT_MULTI_LOGIN),
    RightOption("Change nickname", UserRight.USERRIGHT_LOCKED_NICKNAME, true),
    RightOption("See users in all channels", UserRight.USERRIGHT_VIEW_ALL_USERS),
    RightOption("See hidden channels", UserRight.USERRIGHT_VIEW_HIDDEN_CHANNELS),
    RightOption("Create/modify all channels", UserRight.USERRIGHT_MODIFY_CHANNELS),
    RightOption("Create temporary channels", UserRight.USERRIGHT_CREATE_TEMPORARY_CHANNEL),
    RightOption("Edit server properties", UserRight.USERRIGHT_UPDATE_SERVERPROPERTIES),
    RightOption("Kick users off the server", UserRight.USERRIGHT_KICK_USERS),
    RightOption("Ban users from server", UserRight.USERRIGHT_BAN_USERS),
    RightOption("Move users between channels", UserRight.USERRIGHT_MOVE_USERS),
    RightOption("Make other users channel operator", UserRight.USERRIGHT_OPERATOR_ENABLE),
    RightOption("Upload files", UserRight.USERRIGHT_UPLOAD_FILES),
    RightOption("Download files", UserRight.USERRIGHT_DOWNLOAD_FILES),
    RightOption("Record voice in all channels", UserRight.USERRIGHT_RECORD_VOICE),
    RightOption("Transmit voice data (microphone)", UserRight.USERRIGHT_TRANSMIT_VOICE),
    RightOption("Transmit video data (webcam)", UserRight.USERRIGHT_TRANSMIT_VIDEOCAPTURE),
    RightOption("Transmit desktop sessions (shared desktop)", UserRight.USERRIGHT_TRANSMIT_DESKTOP),
    RightOption("Get remote access to desktop sessions", UserRight.USERRIGHT_TRANSMIT_DESKTOPINPUT),
    RightOption("Stream audio files (wav, mp3 files)", UserRight.USERRIGHT_TRANSMIT_MEDIAFILE_AUDIO),
    RightOption("Stream video files (avi, mp4 files)", UserRight.USERRIGHT_TRANSMIT_MEDIAFILE_VIDEO),
    RightOption("Send private text messages", UserRight.USERRIGHT_TEXTMESSAGE_USER),
    RightOption("Send channel text messages", UserRight.USERRIGHT_TEXTMESSAGE_CHANNEL),
    RightOption("Send broadcast text messages", UserRight.USERRIGHT_TEXTMESSAGE_BROADCAST),
)

private val logEventOptions = listOf(
    "User connected" to ServerLogEvent.SERVERLOGEVENT_USER_CONNECTED,
    "User disconnected" to ServerLogEvent.SERVERLOGEVENT_USER_DISCONNECTED,
    "User logged in" to ServerLogEvent.SERVERLOGEVENT_USER_LOGGEDIN,
    "User logged out" to ServerLogEvent.SERVERLOGEVENT_USER_LOGGEDOUT,
    "User login failed" to ServerLogEvent.SERVERLOGEVENT_USER_LOGINFAILED,
    "User timed out" to ServerLogEvent.SERVERLOGEVENT_USER_TIMEDOUT,
    "User kicked" to ServerLogEvent.SERVERLOGEVENT_USER_KICKED,
    "User banned" to ServerLogEvent.SERVERLOGEVENT_USER_BANNED,
    "User unbanned" to ServerLogEvent.SERVERLOGEVENT_USER_UNBANNED,
    "User updated" to ServerLogEvent.SERVERLOGEVENT_USER_UPDATED,
    "User joined channel" to ServerLogEvent.SERVERLOGEVENT_USER_JOINEDCHANNEL,
    "User left channel" to ServerLogEvent.SERVERLOGEVENT_USER_LEFTCHANNEL,
    "User moved" to ServerLogEvent.SERVERLOGEVENT_USER_MOVED,
    "Private text message" to ServerLogEvent.SERVERLOGEVENT_USER_TEXTMESSAGE_PRIVATE,
    "Custom text message" to ServerLogEvent.SERVERLOGEVENT_USER_TEXTMESSAGE_CUSTOM,
    "Channel text message" to ServerLogEvent.SERVERLOGEVENT_USER_TEXTMESSAGE_CHANNEL,
    "Broadcast text message" to ServerLogEvent.SERVERLOGEVENT_USER_TEXTMESSAGE_BROADCAST,
    "Channel created" to ServerLogEvent.SERVERLOGEVENT_CHANNEL_CREATED,
    "Channel updated" to ServerLogEvent.SERVERLOGEVENT_CHANNEL_UPDATED,
    "Channel removed" to ServerLogEvent.SERVERLOGEVENT_CHANNEL_REMOVED,
    "File uploaded" to ServerLogEvent.SERVERLOGEVENT_FILE_UPLOADED,
    "File downloaded" to ServerLogEvent.SERVERLOGEVENT_FILE_DOWNLOADED,
    "File deleted" to ServerLogEvent.SERVERLOGEVENT_FILE_DELETED,
    "Server updated" to ServerLogEvent.SERVERLOGEVENT_SERVER_UPDATED,
    "Server configuration saved" to ServerLogEvent.SERVERLOGEVENT_SERVER_SAVECONFIG,
    "User encryption error" to 0x02000000, // SERVERLOGEVENT_USER_CRYPTERROR, not in the Java SDK
    "User new stream" to 0x04000000, // SERVERLOGEVENT_USER_NEW_STREAM, not in the Java SDK
)

private fun copyLink(text: String) {
    appContext.getSystemService<ClipboardManager>()?.setPrimaryClip(ClipData.newPlainText("TeamTalk", text))
    announce("Link copied.")
}

@Composable
private fun ExportDialog(admin: AdminBackend, account: AdminAccount, onDismiss: () -> Unit) {
    val context = LocalContext.current
    var name by remember { mutableStateOf(account.username.ifEmpty { "TeamTalk Server" }) }
    var entry by remember { mutableStateOf(admin.publicServerName()) }
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Export TT File") },
        text = {
            Column {
                OutlinedTextField(name, { name = it }, label = { Text("File Name") }, singleLine = true)
                OutlinedTextField(entry, { entry = it }, label = { Text("Server Entry Name") }, singleLine = true)
            }
        },
        confirmButton = {
            TextButton(onClick = {
                onDismiss()
                shareFile(context, admin.writeTTFile(account, name, entry), "application/octet-stream")
            }) { Text("Export") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun AdminLifetime(admin: AdminBackend) {
    DisposableEffect(admin) {
        admin.start()
        onDispose { admin.stop() }
    }
}

@Composable
fun AdminAccountsScreen(session: ServerSession) {
    val admin = remember { SessionAdmin(session) }
    AdminAccountsView(admin)
    SessionAlertDialog(session)
}

@Composable
fun AdminAccountsView(admin: AdminBackend) {
    AdminLifetime(admin)
    LaunchedEffect(admin) { admin.refreshAccounts() }
    var search by remember { mutableStateOf("") }
    var editing by remember { mutableStateOf<AdminAccount?>(null) }
    var creating by remember { mutableStateOf(false) }
    var exporting by remember { mutableStateOf<AdminAccount?>(null) }
    val current = editing
    if (creating || current != null) {
        AccountEditor(admin, current) {
            creating = false
            editing = null
        }
        return
    }
    val q = search.trim()
    val shown = admin.accounts.filter {
        q.isEmpty() || it.username.contains(q, true) || it.note.contains(q, true) || it.initChannel.contains(q, true)
    }
    ScreenFrame("Accounts", actions = {
        IconButton(onClick = admin::refreshAccounts) { Icon(Icons.Filled.Refresh, contentDescription = "Refresh") }
        IconButton(onClick = { creating = true }) { Icon(Icons.Filled.Add, contentDescription = "Add Account") }
    }) {
        OutlinedTextField(search, { search = it }, label = { Text("Search Accounts") }, singleLine = true,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp))
        LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
            if (admin.loadingAccounts) item { Text("Loading Accounts", modifier = Modifier.padding(16.dp)) }
            if (shown.isEmpty() && !admin.loadingAccounts) item { Text("No Accounts", color = secondaryText(), modifier = Modifier.padding(16.dp)) }
            items(shown, key = { it.username }) { a ->
                ActionRow(listOf(
                    RowAction("Edit Account") { editing = a },
                    RowAction("Copy TT Link") { copyLink(admin.ttLink(a)) },
                    RowAction("Export TT File") { exporting = a },
                    RowAction("Delete Account", destructive = true, swipe = true) { admin.deleteAccount(a) },
                ), onClick = { editing = a }, onClickLabel = "Edit Account") {
                    Column(Modifier.fillMaxWidth().padding(RowPadding)) {
                        Text(a.username, style = MaterialTheme.typography.titleSmall)
                        Text(a.kind.title, style = MaterialTheme.typography.bodySmall, color = secondaryText())
                        if (a.initChannel.isNotEmpty()) Text(a.initChannel, style = MaterialTheme.typography.bodySmall, color = secondaryText())
                    }
                }
                RowDivider()
            }
            if (admin.status.isNotEmpty()) item { AnnouncedText(admin.status, secondaryText(), Modifier.padding(16.dp)) }
        }
    }
    exporting?.let { ExportDialog(admin, it) { exporting = null } }
}

@Composable
private fun AccountEditor(admin: AdminBackend, account: AdminAccount?, done: () -> Unit) {
    var username by remember { mutableStateOf(account?.username.orEmpty()) }
    var password by remember { mutableStateOf(account?.password.orEmpty()) }
    var note by remember { mutableStateOf(account?.note.orEmpty()) }
    var channel by remember { mutableStateOf(account?.initChannel.orEmpty()) }
    var kind by remember { mutableStateOf(account?.kind ?: AccountKind.DefaultUser) }
    var rights by remember { mutableIntStateOf(if (account?.kind == AccountKind.DefaultUser) account.rights else defaultRegularRights) }
    fun save() {
        val a = AdminAccount(username, password, note, channel, kind.sdkType, rights, account?.raw)
        if (account != null) admin.editAccount(account, a) else admin.createAccount(a)
        done()
    }
    androidx.activity.compose.BackHandler(onBack = done)
    ScreenFrame(if (account == null) "Add Account" else "Edit Account", onBack = done,
        actions = { TextButton(onClick = ::save) { Text(if (account == null) "Add" else "Save") } }) {
        GroupedBody {
            GroupedSection(header = "Account") {
                LabeledField("Username", username) { username = it }
                LabeledField("Password", password) { password = it }
                ChoiceRow("User Type", AccountKind.entries.map { it to it.title }, kind) { kind = it }
            }
            if (kind == AccountKind.DefaultUser) GroupedSection(header = "User Rights") {
                rightOptions.forEach { o ->
                    val has = rights and o.flag != 0
                    ToggleRow(o.title, if (o.inverted) !has else has) { on ->
                        val set = if (o.inverted) !on else on
                        rights = if (set) rights or o.flag else rights and o.flag.inv()
                    }
                }
            }
            GroupedSection(header = "Optional") {
                LabeledField("Initial Channel", channel) { channel = it }
                LabeledField("Note", note) { note = it }
            }
        }
    }
}

@Composable
private fun LabeledField(label: String, value: String, number: Boolean = false, onChange: (String) -> Unit) {
    OutlinedTextField(value, onChange, label = { Text(label) }, singleLine = true,
        keyboardOptions = if (number) KeyboardOptions(keyboardType = KeyboardType.Number) else KeyboardOptions.Default,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp))
}

@Composable
fun AdminBansScreen(session: ServerSession) {
    val admin = remember { SessionAdmin(session) }
    AdminBansView(admin)
    SessionAlertDialog(session)
}

@Composable
fun AdminBansView(admin: AdminBackend) {
    AdminLifetime(admin)
    LaunchedEffect(admin) { admin.refreshBans() }
    var search by remember { mutableStateOf("") }
    val q = search.trim()
    val shown = admin.bans.filter {
        q.isEmpty() || listOf(it.ipAddress, it.username, it.nickname, it.channelPath, it.owner).any { v -> v.contains(q, true) }
    }
    ScreenFrame("Bans", actions = {
        IconButton(onClick = admin::refreshBans) { Icon(Icons.Filled.Refresh, contentDescription = "Refresh") }
    }) {
        OutlinedTextField(search, { search = it }, label = { Text("Search Bans") }, singleLine = true,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp))
        LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
            if (admin.loadingBans) item { Text("Loading Bans", modifier = Modifier.padding(16.dp)) }
            if (shown.isEmpty() && !admin.loadingBans) item { Text("No Bans", color = secondaryText(), modifier = Modifier.padding(16.dp)) }
            items(shown, key = { it.id }) { b ->
                ActionRow(listOf(RowAction("Remove Ban", destructive = true, swipe = true) { admin.unban(b) })) {
                    Column(Modifier.fillMaxWidth().padding(RowPadding)) {
                        Text(b.ipAddress.ifEmpty { b.username }, style = MaterialTheme.typography.titleSmall)
                        if (b.nickname.isNotEmpty()) Text(b.nickname, style = MaterialTheme.typography.bodySmall, color = secondaryText())
                        if (b.channelPath.isNotEmpty()) Text(b.channelPath, style = MaterialTheme.typography.bodySmall, color = secondaryText())
                    }
                }
                RowDivider()
            }
            if (admin.status.isNotEmpty()) item { AnnouncedText(admin.status, secondaryText(), Modifier.padding(16.dp)) }
        }
    }
}

@Composable
fun ServerPropertiesScreen(session: ServerSession) {
    val admin = remember { SessionAdmin(session) }
    ServerPropertiesView(admin)
    SessionAlertDialog(session)
}

@Composable
fun ServerPropertiesView(admin: AdminBackend) {
    AdminLifetime(admin)
    LaunchedEffect(admin) {
        admin.saved = { Navigator.pop() }
        admin.loadProperties()
    }
    val f = admin.form
    ScreenFrame("Edit Server Properties", actions = { TextButton(onClick = admin::saveProperties) { Text("Save") } }) {
        GroupedBody {
            GroupedSection(header = "General") {
                LabeledField("Server Name", f.serverName) { f.serverName = it }
                LabeledField("Message of the Day", f.motd) { f.motd = it }
                ToggleRow("Auto Save", f.autoSave) { f.autoSave = it }
            }
            GroupedSection(header = "User Limits") {
                LabeledField("Maximum Users", f.maxUsers, true) { f.maxUsers = it }
                LabeledField("Maximum Login Attempts", f.maxLoginAttempts, true) { f.maxLoginAttempts = it }
                LabeledField("Maximum Logins Per IP Address", f.maxLoginsPerIPAddress, true) { f.maxLoginsPerIPAddress = it }
                LabeledField("User Timeout", f.userTimeout, true) { f.userTimeout = it }
                LabeledField("Login Delay", f.loginDelayMSec, true) { f.loginDelayMSec = it }
            }
            GroupedSection(header = "Ports") {
                LabeledField("TCP Port", f.tcpPort, true) { f.tcpPort = it }
                LabeledField("UDP Port", f.udpPort, true) { f.udpPort = it }
            }
            GroupedSection(header = "Bandwidth Limits") {
                LabeledField("Voice Bytes Per Second", f.maxVoiceTxPerSecond, true) { f.maxVoiceTxPerSecond = it }
                LabeledField("Video Bytes Per Second", f.maxVideoCaptureTxPerSecond, true) { f.maxVideoCaptureTxPerSecond = it }
                LabeledField("Audio File Bytes Per Second", f.maxMediaFileTxPerSecond, true) { f.maxMediaFileTxPerSecond = it }
                LabeledField("Desktop Bytes Per Second", f.maxDesktopTxPerSecond, true) { f.maxDesktopTxPerSecond = it }
                LabeledField("Total Bytes Per Second", f.maxTotalTxPerSecond, true) { f.maxTotalTxPerSecond = it }
            }
            GroupedSection(header = "Server Log Events") {
                logEventOptions.forEach { (title, flag) ->
                    ToggleRow(title, f.serverLogEvents and flag != 0) {
                        f.serverLogEvents = if (it) f.serverLogEvents or flag else f.serverLogEvents and flag.inv()
                    }
                }
            }
            if (admin.status.isNotEmpty()) AnnouncedText(admin.status, secondaryText())
        }
    }
}

/** Your own account on this server, view only. */
@Composable
fun MyInformationScreen(session: ServerSession) {
    val admin = remember { SessionAdmin(session) }
    val raw = session.myAccount
    val account = AdminAccount(raw.szUsername.orEmpty(), session.server.password, raw.szNote.orEmpty(), raw.szInitChannel.orEmpty(), raw.uUserType, raw.uUserRights, raw)
    var exporting by remember { mutableStateOf(false) }
    fun show(v: String) = v.ifEmpty { "None" }
    ScreenFrame("My Information") {
        GroupedBody {
            GroupedSection(header = "Account") {
                ValueRow("Username", show(account.username))
                ValueRow("Password", show(account.password))
                ValueRow("User Type", account.kind.title)
            }
            if (account.kind == AccountKind.DefaultUser) GroupedSection(header = "User Rights") {
                rightOptions.forEach { o ->
                    val has = account.rights and o.flag != 0
                    ValueRow(o.title, if (if (o.inverted) !has else has) "Yes" else "No")
                }
            }
            GroupedSection(header = "Optional") {
                ValueRow("Initial Channel", show(account.initChannel))
                ValueRow("Note", show(account.note))
            }
            GroupedSection {
                TextRow("Export TT File", onClick = { exporting = true })
                RowDivider()
                TextRow("Copy TT Link", onClick = { copyLink(admin.ttLink(account)) })
            }
        }
    }
    if (exporting) ExportDialog(admin, account) { exporting = false }
    SessionAlertDialog(session)
}
