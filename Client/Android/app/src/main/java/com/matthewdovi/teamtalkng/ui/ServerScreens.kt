/*
 * The server list, a server's details, reordering, and tt:// links.
 */
package com.matthewdovi.teamtalkng.ui

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import com.matthewdovi.teamtalkng.MonitorCenter
import com.matthewdovi.teamtalkng.Server
import com.matthewdovi.teamtalkng.ServerFiles
import com.matthewdovi.teamtalkng.ServerLink
import com.matthewdovi.teamtalkng.ServerStore
import com.matthewdovi.teamtalkng.SessionManager
import com.matthewdovi.teamtalkng.updateShortcuts

private fun connect(server: Server) {
    Navigator.show(SessionManager.connect(server))
}

@Composable
fun ServerListScreen() {
    val context = LocalContext.current
    val servers = ServerStore.servers.filter { !SessionManager.isConnected(it) }
    var menu by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf<Server?>(null) }
    var deleteAll by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<Pair<String, String>?>(null) }
    var monitoring by remember { mutableStateOf<Server?>(null) }

    fun import(uri: Uri) {
        val text = runCatching { context.contentResolver.openInputStream(uri)?.use { String(it.readBytes()) } }.getOrNull()
        if (text == null) {
            message = "Import Complete" to "Unable to open .TT file."
            return
        }
        val imported = runCatching { ServerFiles.parse(text) }.getOrNull()?.filter { it.ipaddr.isNotEmpty() }
        when {
            imported == null -> message = "Import Complete" to "Unable to read .TT file."
            imported.isEmpty() -> message = "Import Complete" to "No servers found in .TT file."
            else -> {
                val keys = ServerStore.servers.map { "${it.name}|${it.ipaddr}|${it.tcpport}|${it.udpport}" }.toMutableSet()
                val new = imported.filter { keys.add("${it.name}|${it.ipaddr}|${it.tcpport}|${it.udpport}") }
                ServerStore.save(ServerStore.servers + new)
                message = "Import Complete" to "Imported ${new.size} servers from .TT file."
            }
        }
    }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> uri?.let(::import) }

    // Export goes through the system "save" picker, so the file can be kept anywhere (Downloads,
    // Drive, a USB drive…). The share sheet can't save files on most phones.
    val exporter = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        val toExport = ServerStore.servers.filter { !SessionManager.isConnected(it) }
        val saved = runCatching {
            context.contentResolver.openOutputStream(uri, "wt")?.use { it.write(ServerFiles.export(toExport).toByteArray()) }
        }.getOrNull()
        message = if (saved != null) {
            "Export Complete" to "Saved ${toExport.size} ${if (toExport.size == 1) "server" else "servers"} to .TT file."
        } else {
            "Export Failed" to "Unable to save .TT file."
        }
    }
    LaunchedEffect(Navigator.pendingImport.value) {
        Navigator.pendingImport.value?.let {
            Navigator.pendingImport.value = null
            import(it)
        }
    }
    LaunchedEffect(ServerStore.servers.size) { updateShortcuts(context) }

    ScreenFrame(
        "Servers",
        canGoBack = false,
        actions = {
            IconButton(onClick = { Navigator.push(Screen.Settings) }) {
                Icon(Icons.Filled.Settings, contentDescription = "Settings")
            }
            Box {
                IconButton(onClick = { menu = true }) { Icon(Icons.Filled.Menu, contentDescription = "Actions") }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text("Add Server") }, onClick = { menu = false; Navigator.push(Screen.EditServer(null)) })
                    DropdownMenuItem(text = { Text("Import from .TT File") }, onClick = { menu = false; picker.launch(arrayOf("*/*")) })
                    if (ServerStore.servers.size > 1) {
                        DropdownMenuItem(text = { Text("Reorder Servers") }, onClick = { menu = false; Navigator.push(Screen.ReorderServers) })
                    }
                    if (servers.isNotEmpty()) {
                        DropdownMenuItem(text = { Text("Export Server List") }, onClick = {
                            menu = false
                            exporter.launch("TeamTalk Servers.tt")
                        })
                        DropdownMenuItem(text = { Text("Delete All Servers") }, onClick = { menu = false; deleteAll = true })
                    }
                }
            }
        },
        bottom = {
            Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                TextButton(onClick = { Navigator.push(Screen.Monitors) }) { Text("Monitors") }
                if (SessionManager.sessions.isNotEmpty()) {
                    TextButton(onClick = {
                        (SessionManager.active ?: SessionManager.sessions.last()).let { Navigator.show(it) }
                    }) { Text("Connected Servers") }
                }
            }
        },
    ) {
        if (servers.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("No Servers", style = MaterialTheme.typography.titleMedium, color = secondaryText())
            }
        } else {
            LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
                itemsIndexed(servers, key = { _, s -> s.syncID }) { index, server ->
                    ActionRow(
                        actions = listOf(
                            RowAction("Edit") { Navigator.push(Screen.EditServer(server)) },
                            RowAction("Monitor This Server") {
                                if (MonitorCenter.monitored(server) != null) monitoring = server else Navigator.push(Screen.MonitorSetUp(server))
                            },
                            RowAction("Delete", destructive = true, swipe = true) { deleting = server },
                        ),
                        shape = groupedItemShape(index, servers.size),
                        onClick = { connect(server) },
                        onClickLabel = "Connect",
                    ) {
                        Column(Modifier.fillMaxWidth().padding(RowPadding)) {
                            Text(server.displayName, style = MaterialTheme.typography.bodyLarge)
                            Text("${server.ipaddr}:${server.tcpport}", style = MaterialTheme.typography.bodySmall, color = secondaryText())
                        }
                    }
                    if (index < servers.size - 1) RowDivider()
                }
            }
        }
    }

    deleting?.let { server ->
        ConfirmationDialog(
            title = "Are you sure you wish to delete ${server.displayName} from your server list?",
            confirmLabel = "Delete",
            onConfirm = { ServerStore.save(ServerStore.servers.filter { it !== server }) },
            onDismiss = { deleting = null },
        )
    }
    if (deleteAll) {
        ConfirmationDialog(
            title = "Are you sure you wish to delete all the servers in your server list?",
            confirmLabel = "Delete All Servers",
            onConfirm = { ServerStore.save(emptyList()) },
            onDismiss = { deleteAll = false },
        )
    }
    message?.let { (title, text) -> MessageDialog(title, text) { message = null } }
    monitoring?.let { server ->
        MessageDialog("${server.displayName} Is Already Monitored", "") { monitoring = null }
    }
}

@Composable
private fun Field(
    label: String,
    value: String,
    keyboard: KeyboardOptions = KeyboardOptions.Default,
    secret: Boolean = false,
    onChange: (String) -> Unit,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        label = { Text(label) },
        singleLine = true,
        keyboardOptions = keyboard,
        visualTransformation = if (secret) PasswordVisualTransformation() else VisualTransformation.None,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
    )
}

private val plainKeyboard = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false)

@Composable
fun ServerDetailScreen(existing: Server?) {
    var s by remember { mutableStateOf(existing?.copy() ?: Server()) }
    var tcp by remember { mutableStateOf(s.tcpport.toString()) }
    var udp by remember { mutableStateOf(s.udpport.toString()) }
    var showPassword by remember { mutableStateOf(false) }
    var showChannelPassword by remember { mutableStateOf(false) }

    fun save() {
        val saved = s.copy(
            username = s.username.trim(), channel = s.channel.trim(),
            tcpport = tcp.toIntOrNull() ?: s.tcpport, udpport = udp.toIntOrNull() ?: s.udpport,
        )
        val list = ServerStore.servers.toMutableList()
        val at = existing?.let { e -> list.indexOfFirst { it === e } } ?: -1
        val sameName = list.indexOfFirst { it.name == saved.name }
        when {
            at >= 0 -> list[at] = saved
            sameName >= 0 -> list[sameName] = saved.copy(syncID = list[sameName].syncID)
            else -> list.add(saved)
        }
        ServerStore.save(list)
        Navigator.pop()
    }

    ScreenFrame(
        if (existing == null) "Add Server" else existing.displayName,
        actions = { TextButton(onClick = ::save) { Text("Save") } },
    ) {
        GroupedBody {
            GroupedSection(header = "Server List Entry") {
                Field("Name", s.name) { s = s.copy(name = it) }
            }
            GroupedSection(header = "Connection") {
                Field("Host address", s.ipaddr, KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false)) { s = s.copy(ipaddr = it) }
                Field("TCP Port", tcp, KeyboardOptions(keyboardType = KeyboardType.Number)) { tcp = it.filter(Char::isDigit) }
                Field("UDP Port", udp, KeyboardOptions(keyboardType = KeyboardType.Number)) { udp = it.filter(Char::isDigit) }
                ToggleRow("Encrypted", s.encrypted) { s = s.copy(encrypted = it) }
            }
            GroupedSection(header = "Authentication") {
                Field("Username", s.username, plainKeyboard) { s = s.copy(username = it) }
                Field("Password", s.password, plainKeyboard, secret = !showPassword) { s = s.copy(password = it) }
                ToggleRow("Show Password", showPassword) { showPassword = it }
                ToggleRow("Sync Passwords with NG Account", s.syncPassword) { s = s.copy(syncPassword = it) }
            }
            GroupedSection(header = "User Display") {
                Field("Nickname", s.nickname, plainKeyboard) { s = s.copy(nickname = it) }
                Field("Status Message", s.statusmsg) { s = s.copy(statusmsg = it) }
            }
            GroupedSection(header = "Join Channel") {
                Field("Channel", s.channel, plainKeyboard) { s = s.copy(channel = it) }
                Field("Password", s.chanpasswd, plainKeyboard, secret = !showChannelPassword) { s = s.copy(chanpasswd = it) }
                ToggleRow("Show Channel Password", showChannelPassword) { showChannelPassword = it }
            }
        }
    }
}

/** Reorders the server list. Each change is saved straight away. */
@Composable
fun ReorderServersScreen() {
    val servers = ServerStore.servers
    fun move(from: Int, to: Int) {
        val list = servers.toMutableList()
        val item = list.removeAt(from)
        list.add(to, item)
        ServerStore.save(list)
        announceMoved(item.displayName, to, list.size)
    }
    ScreenFrame("Reorder Servers") {
        LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
            itemsIndexed(servers, key = { _, s -> s.syncID }) { index, server ->
                Row(
                    Modifier
                        .fillMaxWidth()
                        .padding(vertical = 2.dp)
                        .semantics(mergeDescendants = true) {
                            customActions = buildList {
                                if (index > 0) add(CustomAccessibilityAction("Move up") { move(index, index - 1); true })
                                if (index < servers.size - 1) add(CustomAccessibilityAction("Move down") { move(index, index + 1); true })
                            }
                        },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f).padding(RowPadding)) {
                        Text(server.displayName, style = MaterialTheme.typography.bodyLarge)
                        Text("${server.ipaddr}:${server.tcpport}", style = MaterialTheme.typography.bodySmall, color = secondaryText())
                    }
                    TextButton(enabled = index > 0, onClick = { move(index, index - 1) }, modifier = Modifier.clearAndSetSemantics {}) { Text("Up") }
                    TextButton(enabled = index < servers.size - 1, onClick = { move(index, index + 1) }, modifier = Modifier.clearAndSetSemantics {}) { Text("Down") }
                }
                RowDivider()
            }
        }
    }
}

private fun announceMoved(name: String, index: Int, count: Int) {
    com.matthewdovi.teamtalkng.announce("$name moved to position ${index + 1} of $count")
}

/** What a tt:// link says, before connecting. */
@Composable
fun ServerLinkScreen(link: ServerLink) {
    var saving by remember { mutableStateOf(false) }
    var saved by remember { mutableStateOf(ServerStore.isSaved(link.server)) }
    ScreenFrame(
        "Server Link",
        actions = {
            if (!saved) TextButton(onClick = { saving = true }) { Text("Save Server") }
            TextButton(onClick = {
                Navigator.popToRoot()
                connect(link.server)
            }) { Text("Connect") }
        },
    ) {
        GroupedBody {
            GroupedSection {
                link.details.forEachIndexed { i, (label, value) ->
                    if (i > 0) RowDivider()
                    ValueRow(label, value)
                }
            }
        }
    }
    if (saving) {
        TextEntryDialog("Save Server", "Server Name", "Save", link.server.name.ifEmpty { link.server.ipaddr },
            "Enter a name for this server.", onDismiss = { saving = false }) { name ->
            ServerStore.saveNamed(link.server, name.trim().ifEmpty { link.server.ipaddr })
            saved = true
        }
    }
}
