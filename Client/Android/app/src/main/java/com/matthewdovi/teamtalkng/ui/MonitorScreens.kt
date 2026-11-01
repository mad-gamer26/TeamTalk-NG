/*
 * The monitors: the list, a monitored server shown the way a connected server
 * is, its conversations and messages, and the monitor's settings. Acting here
 * acts as the monitor.
 */
package com.matthewdovi.teamtalkng.ui

import android.text.format.DateFormat
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.PrimaryTabRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Tab
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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.collapse
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.expand
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import com.matthewdovi.teamtalkng.*
import dk.bearware.UserRight
import dk.bearware.UserType
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.util.Date

private fun connection(ref: String) = MonitorCenter.connection(ref)

/** Sounds and speech for a monitored server's events, as on a connected server. */
private object MonitorSpeech {
    private fun name(nickname: String, username: String, id: Int): String = when {
        Prefs.on(PREF_DISPLAY_SHOWUSERNAME, false) -> limitText(username)
        nickname.isEmpty() -> "Noname - #$id"
        else -> limitText(nickname)
    }

    private fun name(u: MonitorUser) = name(u.nickname, u.username, u.id)
    private fun name(u: MonitorUserRef) = name(u.nickname, u.username, u.id)

    private fun channelName(id: Int, path: String, model: MonitorServerModel?): String {
        val parent = model?.channel(id)?.parentId
        if (parent == 0 || (parent == null && (path.isEmpty() || path == "/"))) return "root"
        return (model?.channel(id)?.name ?: path.split("/").lastOrNull { it.isNotEmpty() }.orEmpty()).ifEmpty { "channel" }
    }

    private fun isMine(id: Int, model: MonitorServerModel?) = model?.me?.channelId?.let { it > 0 && it == id } == true

    fun sound(e: MonitorEvent, model: MonitorServerModel?): Sounds? = when {
        e is MonitorEvent.Joined && isMine(e.channelId, model) -> Sounds.JoinedChan
        e is MonitorEvent.Left && isMine(e.channelId, model) -> Sounds.LeftChan
        else -> MonitorEventText.sound(e)
    }

    fun utterance(e: MonitorEvent, model: MonitorServerModel?): String? = when (e) {
        is MonitorEvent.Connection -> when (e.status) {
            MonitorConnectionStatus.LoggedIn -> if (Prefs.on(PREF_TTSEVENT_USERLOGIN)) "Logged in to ${model?.summary?.displayName ?: "server"}" else null
            MonitorConnectionStatus.Disconnected -> if (Prefs.on(PREF_TTSEVENT_CONLOST)) "Connection lost" else null
            MonitorConnectionStatus.LoginFailed, MonitorConnectionStatus.SteppedAside -> if (Prefs.on(PREF_TTSEVENT_CONLOST)) MonitorEventText.describe(e, model) else null
            else -> null
        }
        is MonitorEvent.LoggedIn -> if (Prefs.on(PREF_TTSEVENT_USERLOGIN)) "${name(e.user)} has logged in" else null
        is MonitorEvent.LoggedOut -> if (Prefs.on(PREF_TTSEVENT_USERLOGOUT)) "${name(e.user)} has logged out" else null
        is MonitorEvent.Joined -> when {
            !Prefs.on(PREF_TTSEVENT_JOINEDCHAN) || e.user.id == model?.me?.userId -> null
            isMine(e.channelId, model) -> "${name(e.user)} joined channel"
            else -> "${name(e.user)} joined channel ${channelName(e.channelId, e.channelPath, model)}"
        }
        is MonitorEvent.Left -> when {
            !Prefs.on(PREF_TTSEVENT_LEFTCHAN) || e.user.id == model?.me?.userId -> null
            isMine(e.channelId, model) -> "${name(e.user)} left channel"
            else -> "${name(e.user)} left channel ${channelName(e.channelId, e.channelPath, model)}"
        }
        is MonitorEvent.MyChannel -> model?.channel(e.channelId)?.let {
            if (Prefs.on(PREF_TTSEVENT_JOINEDCHAN)) "Joined channel ${channelName(it.id, it.path, model)}" else null
        }
        is MonitorEvent.Kicked -> if (Prefs.on(PREF_TTSEVENT_CONLOST)) MonitorEventText.describe(e, model) else null
        is MonitorEvent.Message -> if (e.message.outgoing) null else {
            val from = limitText(name(e.message.from))
            when (e.message.kind) {
                MonitorMessageKind.User -> if (Prefs.on(PREF_TTSEVENT_TEXTMSG)) "Private text message from $from. ${e.message.text}" else null
                MonitorMessageKind.Channel -> if (Prefs.on(PREF_TTSEVENT_CHANTEXTMSG)) "Channel message from $from. ${e.message.text}" else null
                MonitorMessageKind.Broadcast -> if (Prefs.on(PREF_TTSEVENT_BROADCASTMSG)) "Broadcast message from $from: ${e.message.text}" else null
            }
        }
        else -> null
    }
}

/** Monitors belong to an NG Account, so they survive a new phone or reinstalling. */
@Composable
private fun MonitorsNeedAccount() {
    GroupedSection(footer = "Monitors need an NG Account, so they stay yours on a new phone or after reinstalling TeamTalk NG.") {
        NavRow("Sign In or Create Account") { Navigator.push(Screen.Account) }
    }
}

@Composable
fun MonitorsScreen() {
    MonitorCenter.revision.intValue
    NGAccountCenter.revision.intValue
    val scope = rememberCoroutineScope()
    val connection = MonitorCenter.connection
    val servers = connection?.servers.orEmpty()
    var adding by remember { mutableStateOf(false) }
    var noneToAdd by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        MonitorCenter.foreground()
        connection?.let { scope.launch { it.refreshServers() } }
    }
    ScreenFrame("Monitors", actions = {
        if (NGAccountCenter.isSignedIn) IconButton(onClick = {
            if (ServerStore.servers.any { MonitorCenter.monitored(it) == null }) adding = true else noneToAdd = true
        }) { Icon(Icons.Filled.Add, contentDescription = "Monitor a Saved Server") }
    }) {
        if (!NGAccountCenter.isSignedIn) {
            GroupedBody { MonitorsNeedAccount() }
            return@ScreenFrame
        }
        GroupedBody {
            val footer = when {
                servers.isEmpty() -> "The monitor stays logged in to your servers even when TeamTalk NG is closed. It notifies you when people log in or send you messages, and lets you reply and see who is on. Add a server with the + button, or choose Monitor This Server on a server in your list."
                connection != null && !connection.online -> connection.lastError
                else -> null
            }
            GroupedSection(header = if (servers.isEmpty()) null else "Monitored Servers", footer = footer) {
                servers.forEachIndexed { i, s ->
                    if (i > 0) RowDivider()
                    val details = buildList {
                        add(if (s.enabled) s.status.text else "Off")
                        if (s.status == MonitorConnectionStatus.LoggedIn) add("${maxOf(0, s.userCount - 1)} online")
                        else if (!s.reason.isNullOrEmpty() && s.status != MonitorConnectionStatus.Paused) add(s.reason)
                        if (s.unreadPrivateMessages > 0) add("${s.unreadPrivateMessages} unread")
                        if (connection?.isMutedByHand(s.id) == true) add("muted")
                    }.joinToString(", ")
                    ActionRow(emptyList(), onClick = { Navigator.push(Screen.MonitorSession(connection!!.account.ref, s.id)) }) {
                        Column(Modifier.fillMaxWidth().padding(RowPadding)) {
                            Text(s.displayName)
                            Text(details, style = MaterialTheme.typography.bodySmall, color = secondaryText())
                        }
                    }
                }
            }
            if (connection != null) GroupedSection {
                NavRow("Monitor Settings") { Navigator.push(Screen.MonitorNotificationSettings) }
            }
        }
    }
    if (adding) {
        ActionsDialog("Monitor a Saved Server", actions = ServerStore.servers.filter { MonitorCenter.monitored(it) == null }.map {
            it.name.ifEmpty { it.ipaddr } to { Navigator.push(Screen.MonitorSetUp(it)) }
        }) { adding = false }
    }
    if (noneToAdd) MessageDialog("No Servers to Add", "Every saved server is already monitored. Add a server to your server list first.") { noneToAdd = false }
}

private sealed interface MonitorRow {
    data class ChannelItem(val channel: MonitorChannel, val level: Int) : MonitorRow
    data class UserItem(val user: MonitorUser, val level: Int) : MonitorRow
}

/** The saved server for a monitored one: same address, preferring the same account. */
private fun savedServer(s: MonitorServerSummary?): Server? {
    s ?: return null
    val same = ServerStore.servers.filter { it.ipaddr.trim().equals(s.host.trim(), ignoreCase = true) && it.tcpport == s.tcpPort }
    return same.firstOrNull { it.username == s.username } ?: same.firstOrNull()
}

/** Runs a monitor request, showing what went wrong. */
private class MonitorRunner(val ref: String, val serverID: Int) {
    var problem by mutableStateOf<String?>(null)

    fun run(work: suspend (MonitorAPI, Int) -> Unit) {
        val api = connection(ref)?.api ?: return
        appScope.launch {
            try {
                work(api, serverID)
            } catch (e: Exception) {
                problem = e.message
            }
        }
    }
}

@Composable
private fun rememberMonitorModel(ref: String, serverID: Int, onLoadError: (String?) -> Unit = {}): MonitorServerModel? {
    MonitorCenter.revision.intValue
    val c = connection(ref)
    LaunchedEffect(ref, serverID) {
        runCatching { c?.model(serverID) }.onFailure { onLoadError(it.message) }
        MonitorCenter.revision.intValue++
    }
    return c?.models?.get(serverID)
}

@Composable
fun MonitorSessionScreen(ref: String, serverID: Int) {
    val c = connection(ref)
    var loadError by remember { mutableStateOf<String?>(null) }
    val model = rememberMonitorModel(ref, serverID) { loadError = it }
    val runner = remember { MonitorRunner(ref, serverID) }
    val expanded = remember { mutableStateListOf<Int>() }
    val moving = remember { mutableStateListOf<Int>() }
    var opened by remember { mutableStateOf(false) }
    var passwordFor by remember { mutableStateOf<MonitorChannel?>(null) }
    var settings by remember { mutableStateOf(false) }
    var manage by remember { mutableStateOf(false) }
    var compose by remember { mutableStateOf<Pair<String, (String) -> Unit>?>(null) }
    val summary = c?.servers?.firstOrNull { it.id == serverID } ?: model?.summary

    DisposableEffect(ref, serverID) {
        MonitorNotifications.visibleServer = ref to serverID
        val listener: (MonitorStoredEvent, Boolean) -> Unit = { e, catchUp ->
            if (e.serverId == serverID && !catchUp) {
                val m = c?.models?.get(serverID)
                MonitorSpeech.sound(e.event, m)?.let { playSound(it) }
                MonitorSpeech.utterance(e.event, m)?.let { newUtterance(it) }
            }
        }
        c?.eventListeners?.add(listener)
        onDispose {
            c?.eventListeners?.remove(listener)
            // Its other screens are still this server, which keeps speaking its events.
            val stillHere = Navigator.stack.any { it is Screen.MonitorSession && it.serverID == serverID }
            if (!stillHere) MonitorNotifications.visibleServer = null
        }
    }

    LaunchedEffect(model != null) {
        if (model != null && !opened) {
            opened = true
            model.channels.filter { it.parentId == 0 }.forEach { expanded.add(it.id) }
            model.users.forEach { u ->
                var id = u.channelId
                while (id != null && id != 0) {
                    if (id !in expanded) expanded.add(id)
                    id = model.channel(id)?.parentId
                }
            }
        }
    }

    val rights = model?.me?.userRights ?: 0
    val isAdmin = (model?.me?.userType ?: 0) and UserType.USERTYPE_ADMIN != 0
    fun has(flag: Int) = isAdmin || rights and flag != 0
    val canBroadcast = has(UserRight.USERRIGHT_TEXTMESSAGE_BROADCAST)
    val connectTarget = savedServer(summary) ?: summary?.let {
        Server(name = it.displayName, ipaddr = it.host.trim(), tcpport = it.tcpPort, udpport = it.tcpPort, encrypted = it.encrypted)
    }

    @Composable
    fun Tool(label: String, icon: ImageVector, stateText: String? = null, onClick: () -> Unit) {
        IconButton(onClick = onClick, modifier = Modifier.semantics { if (stateText != null) stateDescription = stateText }) {
            Icon(icon, contentDescription = label, tint = MaterialTheme.colorScheme.primary)
        }
    }

    ScreenFrame(
        summary?.displayName ?: "Server",
        bottom = {
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 8.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Tool("Monitor Settings", Icons.Filled.Settings) { settings = true }
                if (connectTarget != null) Tool("Connect", Icons.Filled.Call) {
                    Navigator.popToRoot()
                    Navigator.show(SessionManager.connect(connectTarget))
                }
                if (model?.me?.channelId != null) {
                    Tool("Messages", Icons.Filled.Notifications) { Navigator.push(Screen.MonitorChannelChat(ref, serverID)) }
                }
                val unread = summary?.unreadPrivateMessages ?: 0
                Tool("Private Messages", Icons.Filled.Email, if (unread > 0) "$unread unread" else null) { Navigator.push(Screen.MonitorConversations(ref, serverID)) }
                if (isAdmin) Box {
                    Tool("Manage Server", Icons.Filled.Build) { manage = true }
                    DropdownMenu(expanded = manage, onDismissRequest = { manage = false }) {
                        listOf("Accounts", "Bans", "Edit Server Properties").forEachIndexed { i, label ->
                            DropdownMenuItem(text = { Text(label) }, onClick = { manage = false; Navigator.push(Screen.MonitorAdmin(ref, serverID, i)) })
                        }
                    }
                }
                if (canBroadcast) Tool("Broadcast Message", Icons.Filled.Person) {
                    compose = "Broadcast Message" to { text -> runner.run { api, id -> api.sendBroadcast(id, text) } }
                }
            }
        },
    ) {
        val m = model
        if (m == null || m.summary.status != MonitorConnectionStatus.LoggedIn) {
            Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("The monitor is not on this server right now", style = MaterialTheme.typography.titleMedium)
                    Text(listOfNotNull(summary?.status?.text, summary?.reason).filter { it.isNotEmpty() }.joinToString(": "), color = secondaryText())
                }
            }
        } else {
            val rows = buildList {
                fun tree(c2: MonitorChannel, level: Int) {
                    add(MonitorRow.ChannelItem(c2, level))
                    if (c2.id !in expanded) return
                    m.users(c2.id).forEach { add(MonitorRow.UserItem(it, level + 1)) }
                    m.channels.filter { it.parentId == c2.id }.sortedBy { it.name.lowercase() }.forEach { tree(it, level + 1) }
                }
                m.users.filter { it.channelId == null }.forEach { add(MonitorRow.UserItem(it, 0)) }
                m.channels.filter { it.parentId == 0 }.forEach { tree(it, 0) }
            }
            LazyColumn(Modifier.fillMaxSize()) {
                items(rows, key = {
                    when (it) {
                        is MonitorRow.ChannelItem -> "c${it.channel.id}"
                        is MonitorRow.UserItem -> "u${it.user.id}"
                    }
                }) { row ->
                    when (row) {
                        is MonitorRow.ChannelItem -> {
                            val ch = row.channel
                            val isExpanded = ch.id in expanded
                            fun users(id: Int): Int = m.users(id).size + m.channels.filter { it.parentId == id }.sumOf { users(it.id) }
                            val title = if (ch.parentId == 0) m.info.name.ifEmpty { m.summary.displayName } else "${ch.name} (${users(ch.id)})"
                            val actions = buildList<Pair<String, () -> Unit>> {
                                if (moving.isNotEmpty()) add("Move users here" to {
                                    val ids = moving.toList()
                                    moving.clear()
                                    runner.run { api, id -> ids.forEach { u -> api.act(id, "move", JSONObject().put("user_id", u).put("channel_id", ch.id)) } }
                                })
                                if (ch.id == m.me.channelId) add("Leave channel" to { runner.run { api, id -> api.act(id, "leave") } })
                                else add("Join channel" to {
                                    if (ch.passwordProtected) passwordFor = ch
                                    else runner.run { api, id -> api.act(id, "join", JSONObject().put("channel_id", ch.id)) }
                                })
                            }
                            MonitorTreeRow(title, ch.topic, row.level, isExpanded, actions) {
                                if (isExpanded) expanded.remove(ch.id) else expanded.add(ch.id)
                            }
                        }
                        is MonitorRow.UserItem -> {
                            val u = row.user
                            val op = m.channel(u.channelId)?.operators?.contains(m.me.userId) == true
                            val chat = MonitorPrivateChat(u.id, null, u.displayName)
                            val actions = buildList<Pair<String, () -> Unit>> {
                                add("Send private message" to { Navigator.push(Screen.MonitorChat(ref, serverID, chat)) })
                                if (has(UserRight.USERRIGHT_MOVE_USERS)) add("Move user" to { if (u.id !in moving) moving.add(u.id) })
                                if (has(UserRight.USERRIGHT_KICK_USERS) || op) add("Kick user" to {
                                    runner.run { api, id ->
                                        api.act(id, "kick", JSONObject().put("user_id", u.id).also { j -> u.channelId?.let { j.put("channel_id", it) } })
                                    }
                                })
                                if (has(UserRight.USERRIGHT_BAN_USERS) || op) add("Ban user" to {
                                    runner.run { api, id ->
                                        api.act(id, "ban", JSONObject().put("user_id", u.id))
                                        api.act(id, "kick", JSONObject().put("user_id", u.id))
                                    }
                                })
                            }
                            MonitorUserRow(u, row.level, actions) { Navigator.push(Screen.MonitorUser(ref, serverID, u.id)) }
                        }
                    }
                    RowDivider()
                }
            }
        }
    }

    passwordFor?.let { ch ->
        TextEntryDialog("Enter Password", "Password", "Join", onDismiss = { passwordFor = null }) { password ->
            runner.run { api, id -> api.act(id, "join", JSONObject().put("channel_id", ch.id).put("password", password)) }
        }
    }
    if (settings) {
        val muted = c?.isMutedByHand(serverID) == true
        ActionsDialog("Monitor Settings", actions = listOf(
            "Server Settings" to { Navigator.push(Screen.MonitorServerSettings(ref, serverID)) },
            (if (muted) "Unmute Notifications" else "Mute Notifications") to {
                appScope.launch {
                    runCatching { MonitorCenter.setMuted(serverID, !muted) }
                        .onSuccess { announce(if (muted) "Notifications unmuted" else "Notifications muted") }
                        .onFailure { runner.problem = it.message }
                }
                Unit
            },
            "Change Nickname" to {
                compose = "Nickname" to { text ->
                    runner.run { api, id ->
                        api.act(id, "nickname", JSONObject().put("nickname", text))
                        c?.refreshServers()
                    }
                }
            },
            "Change Status Message" to {
                compose = "Status Message" to { text ->
                    // Keep the monitor's gender, which shares the status mode.
                    val mode = m_statusMode(model)
                    runner.run { api, id ->
                        api.act(id, "status", JSONObject().put("status_mode", mode and (MonitorGender.FEMALE or MonitorGender.NEUTRAL)).put("status_msg", text))
                    }
                }
            },
        )) { settings = false }
    }
    compose?.let { (title, send) ->
        TextEntryDialog(title, title, "OK", onDismiss = { compose = null }) { send(it) }
    }
    loadError?.let { MessageDialog("Could Not Load the Server", it) { loadError = null } }
    runner.problem?.let { MessageDialog("The Monitor Could Not Do That", it) { runner.problem = null } }
}

private fun m_statusMode(model: MonitorServerModel?) = model?.user(model.me.userId)?.statusMode ?: 0

@Composable
private fun MonitorTreeRow(title: String, topic: String, level: Int, isExpanded: Boolean, actions: List<Pair<String, () -> Unit>>, toggle: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier
                .fillMaxWidth()
                .heightIn(min = 52.dp)
                .clickable(onClick = toggle)
                .longPressOnly { menu = true }
                .semantics(mergeDescendants = true) {
                    heading()
                    role = Role.Button
                    if (isExpanded) collapse { toggle(); true } else expand { toggle(); true }
                    customActions = actions.map { (label, perform) -> CustomAccessibilityAction(label) { perform(); true } }
                }
                .padding(start = (8 + level * 20).dp, end = 16.dp, top = 8.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(if (isExpanded) Icons.Filled.KeyboardArrowDown else Icons.Filled.KeyboardArrowRight, contentDescription = null, tint = secondaryText())
            Column {
                Text(limitText(title))
                if (topic.isNotEmpty()) Text(topic, style = MaterialTheme.typography.bodySmall, color = secondaryText())
            }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            actions.forEach { (label, perform) -> DropdownMenuItem(text = { Text(label) }, onClick = { menu = false; perform() }) }
        }
    }
}

@Composable
private fun MonitorUserRow(u: MonitorUser, level: Int, actions: List<Pair<String, () -> Unit>>, open: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    val gender = when (MonitorGender.index(u.statusMode)) { 1 -> "Female"; 2 -> "Neutral"; else -> "Male" }
    Box {
        Row(
            Modifier
                .fillMaxWidth()
                .heightIn(min = 52.dp)
                .clickable(onClick = open)
                .longPressOnly { menu = true }
                .clearAndSetSemantics {
                    contentDescription = listOf(u.displayName, u.statusMsg, gender, if (u.isAdministrator) "Administrator" else "").filter { it.isNotEmpty() }.joinToString(", ")
                    role = Role.Button
                    customActions = actions.map { (label, perform) -> CustomAccessibilityAction(label) { perform(); true } }
                }
                .padding(start = (8 + level * 20).dp, end = 16.dp, top = 6.dp, bottom = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Filled.Person, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(28.dp))
            Spacer(Modifier.width(8.dp))
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(u.displayName)
                    if (u.isAdministrator) Icon(Icons.Filled.Star, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(14.dp))
                }
                Text(u.statusMsg.ifEmpty { "Available" }, style = MaterialTheme.typography.bodySmall, color = secondaryText())
            }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            actions.forEach { (label, perform) -> DropdownMenuItem(text = { Text(label) }, onClick = { menu = false; perform() }) }
        }
    }
}

@Composable
fun MonitorUserScreen(ref: String, serverID: Int, userID: Int) {
    val model = rememberMonitorModel(ref, serverID)
    val user = model?.user(userID)
    val runner = remember { MonitorRunner(ref, serverID) }
    val isAdmin = (model?.me?.userType ?: 0) and UserType.USERTYPE_ADMIN != 0
    ScreenFrame(user?.displayName ?: "User") {
        if (user != null) GroupedBody {
            GroupedSection(header = "General") {
                val channel = when {
                    user.channelId == null || user.channelId <= 0 -> "No channel"
                    else -> model.channel(user.channelId)?.let { if (it.parentId == 0) "root" else it.name } ?: user.channelId.toString()
                }
                InfoRows(buildList {
                    add("Nickname" to user.nickname)
                    add("Username" to user.username)
                    add("User ID" to user.id.toString())
                    add("Status Message" to user.statusMsg)
                    add("Channel" to channel)
                    add("Client" to listOf(user.clientName, user.version).filter { it.isNotBlank() }.joinToString(" "))
                    add("User Type" to if (user.isAdministrator) "Administrator" else "User")
                    if (isAdmin) add("IP Address" to user.ipAddress.orEmpty())
                })
            }
            GroupedSection(header = "Actions") {
                TextRow("Send Private Message", onClick = { Navigator.push(Screen.MonitorChat(ref, serverID, MonitorPrivateChat(user.id, null, user.displayName))) })
                TextRow("Kick User", color = MaterialTheme.colorScheme.error, onClick = {
                    runner.run { api, id -> api.act(id, "kick", JSONObject().put("user_id", user.id).also { j -> user.channelId?.let { j.put("channel_id", it) } }) }
                })
                TextRow("Kick and Ban User", color = MaterialTheme.colorScheme.error, onClick = {
                    runner.run { api, id ->
                        api.act(id, "ban", JSONObject().put("user_id", user.id))
                        api.act(id, "kick", JSONObject().put("user_id", user.id))
                    }
                })
            }
        }
    }
    runner.problem?.let { MessageDialog("The Monitor Could Not Do That", it) { runner.problem = null } }
}

@Composable
private fun MonitorMessageRow(message: String, sender: String, time: Date, mine: Boolean, log: Boolean) {
    val clock = DateFormat.getTimeFormat(appContext).format(time)
    Column(
        Modifier.fillMaxWidth().clearAndSetSemantics {
            contentDescription = if (log) "$message, $clock" else "$sender, $message, $clock"
        }.padding(vertical = 4.dp),
        horizontalAlignment = if (mine) Alignment.End else Alignment.Start,
    ) {
        Text(if (log) clock else "$sender, $clock", style = MaterialTheme.typography.labelSmall, color = secondaryText())
        Surface(shape = RoundedCornerShape(16.dp), color = if (mine) MaterialTheme.colorScheme.primary else if (log) Color.Transparent else MaterialTheme.colorScheme.surface) {
            Text(message, color = if (mine) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp))
        }
    }
}

private class ShownMessage(val text: String, val sender: String, val date: Date, val mine: Boolean, val log: Boolean)

@Composable
private fun ComposeBar(onSend: (String) -> Unit) {
    var draft by remember { mutableStateOf("") }
    Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
        OutlinedTextField(draft, { draft = it }, label = { Text("Message text") }, modifier = Modifier.weight(1f), maxLines = 4)
        TextButton(onClick = {
            val content = draft.trim()
            draft = ""
            if (content.isNotEmpty()) onSend(content)
        }) { Text("Send") }
    }
}

private fun channelScreenMessage(e: MonitorStoredEvent, model: MonitorServerModel?): ShownMessage? {
    fun log(text: String) = ShownMessage(text, "", e.date, mine = false, log = true)
    return when (val ev = e.event) {
        is MonitorEvent.Message -> when (ev.message.kind) {
            MonitorMessageKind.Channel -> ShownMessage(ev.message.text, if (ev.message.outgoing) "Your Message" else ev.message.from.nickname, e.date, ev.message.outgoing, false)
            MonitorMessageKind.Broadcast -> ShownMessage(ev.message.text, ev.message.from.nickname, e.date, false, false)
            MonitorMessageKind.User -> null
        }
        is MonitorEvent.LoggedIn -> log("${ev.user.displayName} has logged in")
        is MonitorEvent.LoggedOut -> log("${ev.user.displayName} has logged out")
        is MonitorEvent.Joined -> log(if (ev.user.id == model?.me?.userId) "Joined channel ${ev.channelPath}" else "${ev.user.displayName} joined channel ${ev.channelPath}")
        is MonitorEvent.Left -> log(if (ev.user.id == model?.me?.userId) "Left channel ${ev.channelPath}" else "${ev.user.displayName} left channel ${ev.channelPath}")
        is MonitorEvent.Connection -> if (ev.status == MonitorConnectionStatus.LoggedIn) log("Logged in to server") else MonitorEventText.describe(ev, model)?.let(::log)
        is MonitorEvent.Kicked -> MonitorEventText.describe(ev, model)?.let(::log)
        else -> null
    }
}

/** The monitor's channel messages and server events. */
@Composable
fun MonitorChannelChatScreen(ref: String, serverID: Int) {
    val model = rememberMonitorModel(ref, serverID)
    val c = connection(ref)
    val messages = remember { mutableStateListOf<ShownMessage>() }
    var through by remember { mutableStateOf(0L) }
    var tab by remember { mutableIntStateOf(0) }
    var error by remember { mutableStateOf<String?>(null) }
    val listState = rememberLazyListState()
    LaunchedEffect(Unit) {
        runCatching { c?.api?.recentEvents(serverID, 300) }.onSuccess { events ->
            events ?: return@onSuccess
            through = maxOf(through, events.maxOfOrNull { it.seq } ?: 0)
            messages.addAll(0, events.mapNotNull { channelScreenMessage(it, model) })
        }.onFailure { messages.add(ShownMessage(it.message.orEmpty(), "", Date(), false, true)) }
    }
    DisposableEffect(c) {
        val listener: (MonitorStoredEvent, Boolean) -> Unit = { e, _ ->
            if (e.serverId == serverID && e.seq > through) {
                through = e.seq
                channelScreenMessage(e, c?.models?.get(serverID))?.let { messages.add(it) }
            }
        }
        c?.eventListeners?.add(listener)
        onDispose { c?.eventListeners?.remove(listener) }
    }
    val visible = messages.filter { if (tab == 0) !it.log else it.log }
    LaunchedEffect(visible.size) { if (visible.isNotEmpty()) listState.scrollToItem(visible.size - 1) }
    ScreenFrame("Messages", actions = {
        if (messages.isNotEmpty()) TextButton(onClick = { messages.clear() }) { Text("Clear") }
    }, bottom = {
        ComposeBar { text ->
            appScope.launch {
                runCatching { c?.api?.sendChannelMessage(serverID, null, text) }.onFailure { error = it.message }
            }
        }
    }) {
        PrimaryTabRow(selectedTabIndex = tab) {
            listOf("User Messages", "Server Events").forEachIndexed { i, title ->
                Tab(selected = i == tab, onClick = { tab = i }, text = { Text(title) })
            }
        }
        if (visible.isEmpty()) {
            Text(if (tab == 0) "Channel messages will appear here." else "Server events will appear here.", color = secondaryText(), modifier = Modifier.padding(24.dp))
        } else {
            LazyColumn(Modifier.fillMaxSize().padding(horizontal = 12.dp), state = listState) {
                items(visible) { MonitorMessageRow(it.text, it.sender, it.date, it.mine, it.log) }
            }
        }
    }
    error?.let { MessageDialog("Message Not Sent", it) { error = null } }
}

/** A private conversation through the monitor. */
@Composable
fun MonitorChatScreen(ref: String, serverID: Int, start: MonitorPrivateChat) {
    val c = connection(ref)
    val api = c?.api
    var chat by remember { mutableStateOf(start) }
    val messages = remember { mutableStateListOf<ShownMessage>() }
    var through by remember { mutableStateOf(0L) }
    var ended by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<Pair<String, String>?>(null) }
    val listState = rememberLazyListState()

    fun markRead() {
        val id = chat.conversationID ?: return
        appScope.launch { runCatching { api?.markRead(serverID, id) } }
    }

    LaunchedEffect(Unit) {
        runCatching {
            if (api == null) return@runCatching
            // From a person in the channel list: their conversation during this login, if there is one yet.
            if (chat.conversationID == null) {
                chat = chat.copy(conversationID = api.conversations(serverID).firstOrNull { it.userId == chat.userID && it.active }?.id)
            }
            chat.conversationID?.let { id ->
                val r = api.messages(serverID, id)
                messages.addAll(0, r.messages.map {
                    ShownMessage(it.text, if (it.outgoing) "Your Message" else r.conversation.nickname, it.date, it.outgoing, false)
                })
                through = maxOf(through, r.seq)
                if (!r.conversation.active) {
                    ended = true
                    messages.add(ShownMessage("${r.conversation.nickname} has logged out", "", Date(), false, true))
                }
                markRead()
                c.clearUnread(serverID)
            }
        }.onFailure { messages.add(ShownMessage(it.message.orEmpty(), "", Date(), false, true)) }
    }

    DisposableEffect(c) {
        val listener: (MonitorStoredEvent, Boolean) -> Unit = listener@{ e, _ ->
            if (e.serverId != serverID || e.seq <= through) return@listener
            through = e.seq
            when (val ev = e.event) {
                is MonitorEvent.Message -> {
                    val m = ev.message
                    if (m.kind != MonitorMessageKind.User || m.intercepted || ended) return@listener
                    val other = if (m.outgoing) m.to else m.from
                    if (other?.id != chat.userID) return@listener
                    messages.add(ShownMessage(m.text, if (m.outgoing) "Your Message" else m.from.nickname, e.date, m.outgoing, false))
                    if (chat.conversationID == null) {
                        // The first message started the conversation: learn it.
                        appScope.launch {
                            val id = runCatching { api?.conversations(serverID) }.getOrNull()?.firstOrNull { it.userId == chat.userID && it.active }?.id
                            if (id != null) { chat = chat.copy(conversationID = id); markRead() }
                        }
                    } else if (!m.outgoing) markRead()
                }
                is MonitorEvent.LoggedOut -> if (ev.user.id == chat.userID && !ended) {
                    ended = true
                    messages.add(ShownMessage("${ev.user.displayName} has logged out", "", e.date, false, true))
                }
                else -> {}
            }
        }
        c?.eventListeners?.add(listener)
        onDispose { c?.eventListeners?.remove(listener) }
    }
    LaunchedEffect(messages.size) { if (messages.isNotEmpty()) listState.scrollToItem(messages.size - 1) }

    ScreenFrame(chat.nickname, actions = {
        if (chat.conversationID != null) TextButton(onClick = { deleting = true }) { Text("Delete") }
    }, bottom = {
        ComposeBar { text ->
            appScope.launch {
                // The monitor's own message comes back as an event and is shown then.
                runCatching { api?.sendPrivateMessage(serverID, chat.userID, chat.conversationID, text) }
                    .onFailure { error = "Message Not Sent" to it.message.orEmpty() }
            }
        }
    }) {
        if (messages.isEmpty()) Text("Private messages will appear here.", color = secondaryText(), modifier = Modifier.padding(24.dp))
        else LazyColumn(Modifier.fillMaxSize().padding(horizontal = 12.dp), state = listState) {
            items(messages) { MonitorMessageRow(it.text, it.sender, it.date, it.mine, it.log) }
        }
    }
    if (deleting) {
        ConfirmationDialog("This deletes your conversation with ${chat.nickname} and its messages from the monitor.", "Delete", onConfirm = {
            appScope.launch {
                runCatching { api?.deleteConversation(serverID, chat.conversationID!!) }
                    .onSuccess { Navigator.pop() }.onFailure { error = "Conversation Not Deleted" to it.message.orEmpty() }
            }
        }, onDismiss = { deleting = false })
    }
    error?.let { (title, text) -> MessageDialog(title, text) { error = null } }
}

/** The monitor's private conversations on one server, including with people who have logged out. */
@Composable
fun MonitorConversationsScreen(ref: String, serverID: Int) {
    val c = connection(ref)
    var list by remember { mutableStateOf<List<MonitorConversation>>(emptyList()) }
    var deleting by remember { mutableStateOf<MonitorConversation?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    fun load() {
        appScope.launch { runCatching { c?.api?.conversations(serverID) }.getOrNull()?.let { list = it } }
    }
    LaunchedEffect(Unit) { load() }
    DisposableEffect(c) {
        val listener: (MonitorStoredEvent, Boolean) -> Unit = { _, _ -> load() }
        c?.eventListeners?.add(listener)
        onDispose { c?.eventListeners?.remove(listener) }
    }
    ScreenFrame("Private Messages") {
        if (list.isEmpty()) {
            Column(Modifier.padding(24.dp)) {
                Text("No messages", style = MaterialTheme.typography.titleMedium)
                Text("Private messages to the monitor will appear here.", color = secondaryText())
            }
        } else {
            LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
                itemsIndexed(list, key = { _, x -> x.id }) { i, x ->
                    ActionRow(
                        listOf(RowAction("Delete Conversation", destructive = true, swipe = true) { deleting = x }),
                        shape = groupedItemShape(i, list.size),
                        onClick = { Navigator.push(Screen.MonitorChat(ref, serverID, MonitorPrivateChat(x.userId, x.id, x.nickname))) },
                    ) {
                        Column(Modifier.fillMaxWidth().padding(RowPadding)) {
                            Text(x.nickname + (if (x.active) "" else " (logged out)") + (if (x.unread > 0) ", ${x.unread} unread" else ""))
                            Text((if (x.lastOutgoing) "Your Message: " else "") + x.lastText, maxLines = 2, style = MaterialTheme.typography.bodySmall, color = secondaryText())
                        }
                    }
                    if (i < list.size - 1) RowDivider()
                }
            }
        }
    }
    deleting?.let { x ->
        ConfirmationDialog("This deletes your conversation with ${x.nickname} and its messages from the monitor.", "Delete", onConfirm = {
            appScope.launch {
                runCatching { c?.api?.deleteConversation(serverID, x.id) }
                    .onSuccess { announce("Conversation deleted"); load() }.onFailure { error = it.message }
            }
        }, onDismiss = { deleting = null })
    }
    error?.let { MessageDialog("Conversation Not Deleted", it) { error = null } }
}

@Composable
fun MonitorNotificationSettingsScreen() {
    val c = MonitorCenter.connection
    MonitorCenter.revision.intValue
    var prefs by remember { mutableStateOf<MonitorPrefs?>(null) }
    var loadError by remember { mutableStateOf<String?>(null) }
    var saveError by remember { mutableStateOf<String?>(null) }
    var pausing by remember { mutableStateOf(false) }
    var stopping by remember { mutableStateOf(false) }
    var adding by remember { mutableStateOf(false) }
    var editList by remember { mutableStateOf<Triple<String, String, Pair<List<String>, (List<String>) -> MonitorPrefs>>?>(null) }
    var soundChoice by remember { mutableStateOf(MonitorNotificationSounds.choice) }
    LaunchedEffect(Unit) {
        runCatching { c?.api?.prefs() }.onSuccess { prefs = it; loadError = null }.onFailure { loadError = it.message }
        c?.refreshServers()
    }
    fun save(next: MonitorPrefs) {
        prefs = next
        appScope.launch { runCatching { c?.api?.setPrefs(next) }.onFailure { saveError = it.message } }
    }
    val presence = listOf("all" to "Everyone", "watched" to "Watched People", "none" to "Nobody")

    ScreenFrame("Monitor Settings") {
        GroupedBody {
            GroupedSection(header = "Notification Sound", footer = "For this phone. Sound Pack plays your sound pack's sounds, and stays quiet for sound events you have turned off.") {
                ChoiceRow("Sound", MonitorNotificationSounds.Choice.entries.map { it to it.title }, soundChoice) {
                    soundChoice = it
                    MonitorNotificationSounds.choice = it
                }
            }
            prefs?.let { p ->
                val muted = (p.mutedUntil ?: 0) > System.currentTimeMillis()
                GroupedSection(header = "Notify Me About", footer = loadError ?: "These settings apply on all your devices.") {
                    NavRow("Pause Notifications", if (muted) "Until ${DateFormat.getTimeFormat(appContext).format(Date(p.mutedUntil!!))}" else "Off") { pausing = true }
                    ToggleRow("Private Messages", p.privateMessages) { save(p.copy(privateMessages = it)) }
                    ChoiceRow("Channel Messages", listOf("all" to "All", "mentions" to "When Mentioned", "none" to "None"), p.channelMessages) { save(p.copy(channelMessages = it)) }
                    ChoiceRow("Logins", presence, p.logins) { save(p.copy(logins = it)) }
                    ChoiceRow("Logouts", presence, p.logouts) { save(p.copy(logouts = it)) }
                    ToggleRow("Broadcasts", p.broadcasts) { save(p.copy(broadcasts = it)) }
                    ToggleRow("Monitor Lost a Server", p.connection) { save(p.copy(connection = it)) }
                }
                GroupedSection(header = "People") {
                    fun listRow(list: List<String>) = if (list.isEmpty()) "None" else list.joinToString(", ")
                    NavRow("Watched People", listRow(p.watched)) {
                        editList = Triple("Watched People", "Usernames or nicknames, separated by commas. With logins set to Watched People, only these people's logins notify you.", p.watched to { w -> p.copy(watched = w) })
                    }
                    NavRow("Ignored People", listRow(p.ignored)) {
                        editList = Triple("Ignored People", "Usernames or nicknames, separated by commas. Nothing these people do notifies you.", p.ignored to { w -> p.copy(ignored = w) })
                    }
                    NavRow("Mention Words", listRow(p.mentionWords)) {
                        editList = Triple("Mention Words", "Words, separated by commas, that count as mentioning you in a channel, besides the monitor's nickname.", p.mentionWords to { w -> p.copy(mentionWords = w) })
                    }
                }
            }
            if (c != null) GroupedSection(header = "Monitored Servers", footer = "The monitor logs in to these servers and stays logged in.") {
                c.servers.forEach { s ->
                    NavRow(s.displayName, if (s.enabled) "${s.host}:${s.tcpPort}" else "Off") { Navigator.push(Screen.MonitorServerSettings(c.account.ref, s.id)) }
                    RowDivider()
                }
                TextRow("Add Server", onClick = { adding = true })
            }
            GroupedSection(footer = "Logs the monitor out of every server and deletes your servers, logins and messages from the monitor service.") {
                TextRow("Stop Monitoring All Servers", color = MaterialTheme.colorScheme.error, onClick = { stopping = true })
            }
        }
    }
    val p = prefs
    if (pausing && p != null) {
        val now = System.currentTimeMillis()
        ActionsDialog("Pause Notifications", actions = listOf(
            "For 1 Hour" to { save(p.copy(mutedUntil = now + 3_600_000)) },
            "For 8 Hours" to { save(p.copy(mutedUntil = now + 8 * 3_600_000)) },
            "For 24 Hours" to { save(p.copy(mutedUntil = now + 24 * 3_600_000)) },
            "Resume Now" to { save(p.copy(mutedUntil = null)) },
        )) { pausing = false }
    }
    editList?.let { (title, help, data) ->
        TextEntryDialog(title, title, "Save", data.first.joinToString(", "), help, onDismiss = { editList = null }) { text ->
            save(data.second(text.split(",").map { it.trim() }.filter { it.isNotEmpty() }))
        }
    }
    if (adding) {
        ActionsDialog("Monitor a Saved Server", actions = ServerStore.servers.filter { MonitorCenter.monitored(it) == null }.map {
            it.name.ifEmpty { it.ipaddr } to { Navigator.push(Screen.MonitorSetUp(it)) }
        }) { adding = false }
    }
    if (stopping) {
        ConfirmationDialog("You will no longer get notifications from the monitor, and its record of your servers and messages is deleted.", "Stop Monitoring", onConfirm = {
            appScope.launch {
                runCatching { MonitorCenter.stopEverything() }.onSuccess { Navigator.pop() }.onFailure { saveError = it.message }
            }
        }, onDismiss = { stopping = false })
    }
    saveError?.let { MessageDialog("Not Saved", it) { saveError = null } }
}

/** The monitor's settings for a server: set up before it starts, or changed later. */
@Composable
fun MonitorServerEditScreen(ref: String?, serverID: Int?, saved: Server?) {
    NGAccountCenter.revision.intValue
    if (!NGAccountCenter.isSignedIn) {
        ScreenFrame("Monitor This Server") { GroupedBody { MonitorsNeedAccount() } }
        return
    }
    val c = ref?.let(::connection)
    val isNew = serverID == null
    val summary = serverID?.let { id -> c?.servers?.firstOrNull { it.id == id } }
    val input = saved?.let { MonitorCenter.input(it) }
    var name by remember { mutableStateOf(input?.name ?: summary?.name.orEmpty()) }
    var host by remember { mutableStateOf(input?.host ?: summary?.host.orEmpty()) }
    var port by remember { mutableStateOf((input?.tcpPort ?: summary?.tcpPort ?: DEFAULT_TCPPORT).toString()) }
    var nickname by remember { mutableStateOf(input?.nickname ?: summary?.nickname.orEmpty()) }
    var username by remember { mutableStateOf(input?.username ?: summary?.username.orEmpty()) }
    var password by remember { mutableStateOf(input?.password.orEmpty()) }
    var status by remember { mutableStateOf("") }
    var channel by remember { mutableStateOf("") }
    var channelPassword by remember { mutableStateOf("") }
    var encrypted by remember { mutableStateOf(input?.encrypted ?: summary?.encrypted ?: false) }
    var enabled by remember { mutableStateOf(summary?.enabled ?: true) }
    val wasMuted = remember { serverID?.let { c?.isMutedByHand(it) } ?: false }
    var muted by remember { mutableStateOf(wasMuted) }
    var gender by remember { mutableIntStateOf(preferredGenderIndex()) }
    var error by remember { mutableStateOf<String?>(null) }
    var removing by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        if (serverID != null) runCatching { c?.api?.serverConfig(serverID) }.getOrNull()?.let { cfg ->
            username = cfg.username
            status = cfg.statusMsg
            cfg.statusMode?.let { gender = MonitorGender.index(it) }
            channel = cfg.channel
        }
    }

    fun save() {
        if (host.trim().isEmpty()) {
            error = "Enter the server's address."
            return
        }
        val out = MonitorServerInput(name.trim().ifEmpty { host.trim() }, host.trim(), port.trim().toIntOrNull() ?: DEFAULT_TCPPORT, encrypted,
            nickname.trim(), username.trim(), password, status.trim(), MonitorGender.statusMode(gender), channel.trim(), channelPassword, enabled)
        busy = true
        appScope.launch {
            try {
                if (serverID != null && c != null) {
                    c.api.updateServer(serverID, out)
                    if (muted != wasMuted) MonitorCenter.setMuted(serverID, muted)
                    c.refreshServers()
                } else {
                    MonitorCenter.monitor(out)
                    announce("Now monitoring ${out.name}")
                }
                Navigator.pop()
            } catch (e: Exception) {
                error = e.message
            } finally {
                busy = false
            }
        }
    }

    @Composable
    fun F(label: String, value: String, placeholder: String? = null, set: (String) -> Unit) {
        OutlinedTextField(value, set, label = { Text(label) }, singleLine = true,
            placeholder = placeholder?.let { { Text(it) } },
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp))
    }

    ScreenFrame(if (isNew) "Monitor ${saved?.name?.ifEmpty { saved.ipaddr }.orEmpty()}" else "Server Settings", actions = {
        TextButton(enabled = !busy, onClick = ::save) { Text(if (isNew) "Monitor" else "Save") }
    }) {
        GroupedBody {
            if (isNew) Text("TeamTalk NG's monitor service stays logged in to this server for you, even when the app is closed, and notifies you when people log in or send you messages. You can reply from the notification. Other people on the server see the monitor as a text-only user, with the nickname below.",
                style = MaterialTheme.typography.bodySmall, color = secondaryText())
            GroupedSection(header = "Monitor", footer = "What other people on the server see.") {
                F("Nickname", nickname) { nickname = it }
                F("Status Message (optional)", status) { status = it }
                ChoiceRow("Gender", listOf(0 to "Male", 1 to "Female", 2 to "Neutral"), gender) { gender = it }
            }
            GroupedSection(header = "After Login", footer = "To read a channel's messages and reply there, the monitor must be in it.") {
                F("Channel to Join", channel, "None (stay out of channels)") { channel = it }
                F("Channel Password", channelPassword, if (isNew) null else "Unchanged") { channelPassword = it }
            }
            GroupedSection(header = "Monitor's Login", footer = "Use an account of its own for the monitor if the server allows only one login per account.") {
                F("Username", username) { username = it }
                F("Password", password, if (isNew) null else "Unchanged") { password = it }
            }
            GroupedSection(header = "Server") {
                F("Name", name) { name = it }
                F("Address", host) { host = it }
                F("TCP Port", port) { port = it.filter(Char::isDigit) }
            }
            GroupedSection(footer = if (isNew) null else "Mute Notifications keeps the monitor watching this server, but you get no notifications from it.") {
                ToggleRow("Encrypted", encrypted) { encrypted = it }
                if (!isNew) {
                    ToggleRow("Monitoring On", enabled) { enabled = it }
                    ToggleRow("Mute Notifications", muted) { muted = it }
                }
            }
            if (!isNew) GroupedSection {
                TextRow("Stop Monitoring This Server", color = MaterialTheme.colorScheme.error, onClick = { removing = true })
            }
        }
    }
    if (removing) {
        ConfirmationDialog("The monitor logs out and forgets the server and its message history.", "Stop Monitoring", onConfirm = {
            appScope.launch {
                runCatching {
                    c?.api?.removeServer(serverID!!)
                    c?.refreshServers()
                }.onSuccess {
                    val at = Navigator.stack.indexOfLast { it == Screen.Monitors }
                    if (at >= 0) while (Navigator.stack.size > at + 1) Navigator.pop() else Navigator.pop()
                }.onFailure { error = it.message }
            }
        }, onDismiss = { removing = false })
    }
    error?.let { MessageDialog(if (isNew) "Could Not Monitor This Server" else "Not Saved", it) { error = null } }
}

/** Accounts, bans and properties of a monitored server. */
private class MonitorAdmin(private val c: MonitorConnection, private val serverID: Int, server: Server) : AdminBackend(server) {
    private fun text(j: JSONObject, key: String) = j.opt(key)?.takeIf { it != JSONObject.NULL }?.toString().orEmpty()

    private suspend fun admin(command: String, params: JSONObject = JSONObject()) = c.api.admin(serverID, command, params)

    private fun change(work: suspend () -> Unit) {
        appScope.launch {
            try {
                work()
            } catch (e: Exception) {
                status = e.message.orEmpty()
            }
            refreshAccounts()
            refreshBans()
        }
    }

    private fun parse(j: JSONObject) = AdminAccount(text(j, "username"), text(j, "password"), text(j, "note"), text(j, "initchan"), j.optInt("usertype"), j.optLong("userrights").toInt())

    override fun refreshAccounts() {
        loadingAccounts = true
        appScope.launch {
            try {
                val lines = admin("listaccounts", JSONObject().put("index", 0).put("count", 100_000))
                val found = lines.filter { it.str("type") == "useraccount" }.map(::parse).sortedBy { it.username.lowercase() }
                accounts.clear()
                accounts.addAll(found)
            } catch (e: Exception) {
                status = e.message.orEmpty()
            }
            loadingAccounts = false
        }
    }

    override fun refreshBans() {
        loadingBans = true
        appScope.launch {
            try {
                val lines = admin("listbans", JSONObject().put("index", 0).put("count", 100_000))
                val found = lines.filter { it.str("type") == "userbanned" }.map {
                    AdminBan(text(it, "ipaddr"), text(it, "username"), text(it, "nickname"), text(it, "channel"), text(it, "bantime"), text(it, "owner"), it.optInt("bantype"))
                }.sortedBy { it.ipAddress.lowercase() }
                bans.clear()
                bans.addAll(found)
            } catch (e: Exception) {
                status = e.message.orEmpty()
            }
            loadingBans = false
        }
    }

    private fun params(a: AdminAccount): JSONObject? {
        val name = a.username.trim()
        if (name.isEmpty()) {
            status = "Username is required"
            return null
        }
        return JSONObject().put("username", name).put("password", a.password).put("note", a.note).put("initchan", a.initChannel)
            .put("usertype", a.kind.sdkType).put("userrights", if (a.kind == AccountKind.DefaultUser) a.rights else 0)
    }

    override fun createAccount(a: AdminAccount) {
        val p = params(a) ?: return
        change { admin("newaccount", p) }
    }

    override fun editAccount(original: AdminAccount, a: AdminAccount) {
        val p = params(a) ?: return
        // As on a connected server: the old account goes, the changed one is created.
        change {
            admin("delaccount", JSONObject().put("username", original.username))
            admin("newaccount", p)
        }
    }

    override fun deleteAccount(a: AdminAccount) = change {
        admin("delaccount", JSONObject().put("username", a.username))
        status = "Deleted ${a.username}"
    }

    override fun unban(b: AdminBan) {
        val p = JSONObject().put("bantype", b.banTypes)
        if (b.ipAddress.isNotEmpty()) p.put("ipaddr", b.ipAddress)
        if (b.username.isNotEmpty()) p.put("username", b.username)
        change { admin("unban", p) }
    }

    override fun publicServerName() = c.models[serverID]?.summary?.displayName ?: server.name

    private fun apply(p: JSONObject) {
        fun n(key: String) = p.optLong(key).toString()
        form.serverName = text(p, "servername")
        form.motd = text(p, "motdraw")
        form.maxUsers = n("maxusers")
        form.maxLoginAttempts = n("maxloginattempts")
        form.maxLoginsPerIPAddress = n("maxiplogins")
        form.maxVoiceTxPerSecond = n("voicetxlimit")
        form.maxVideoCaptureTxPerSecond = n("videotxlimit")
        form.maxMediaFileTxPerSecond = n("mediafiletxlimit")
        form.maxDesktopTxPerSecond = n("desktoptxlimit")
        form.maxTotalTxPerSecond = n("totaltxlimit")
        form.autoSave = p.optInt("autosave") != 0
        form.tcpPort = n("tcpport")
        form.udpPort = n("udpport")
        form.userTimeout = n("usertimeout")
        form.loginDelayMSec = n("logindelay")
        form.serverLogEvents = p.optInt("logevents")
    }

    override fun loadProperties() {
        val p = c.models[serverID]?.info?.properties
        if (p == null || p.length() == 0) status = "Could not load server properties" else apply(p)
    }

    override fun saveProperties() {
        fun n(v: String) = v.trim().toIntOrNull() ?: 0
        val f = form
        val params = JSONObject().put("servername", f.serverName).put("motdraw", f.motd).put("maxusers", n(f.maxUsers))
            .put("maxloginattempts", n(f.maxLoginAttempts)).put("maxiplogins", n(f.maxLoginsPerIPAddress))
            .put("voicetxlimit", n(f.maxVoiceTxPerSecond)).put("videotxlimit", n(f.maxVideoCaptureTxPerSecond))
            .put("mediafiletxlimit", n(f.maxMediaFileTxPerSecond)).put("desktoptxlimit", n(f.maxDesktopTxPerSecond))
            .put("totaltxlimit", n(f.maxTotalTxPerSecond)).put("autosave", if (f.autoSave) 1 else 0)
            .put("tcpport", n(f.tcpPort)).put("udpport", n(f.udpPort)).put("usertimeout", n(f.userTimeout))
            .put("logindelay", n(f.loginDelayMSec)).put("logevents", f.serverLogEvents)
        status = "Updating server properties"
        appScope.launch {
            try {
                admin("updateserver", params).firstOrNull { it.str("type") == "serverupdate" }?.let(::apply)
                status = "Server properties updated"
                saved()
            } catch (e: Exception) {
                status = e.message.orEmpty()
            }
        }
    }
}

@Composable
fun MonitorAdminScreen(ref: String, serverID: Int, section: Int) {
    val c = connection(ref) ?: return
    val admin = remember {
        val s = c.servers.firstOrNull { it.id == serverID }
        val server = savedServer(s) ?: Server(name = s?.displayName.orEmpty(), ipaddr = s?.host.orEmpty(), tcpport = s?.tcpPort ?: DEFAULT_TCPPORT, encrypted = s?.encrypted ?: false)
        MonitorAdmin(c, serverID, server)
    }
    when (section) {
        0 -> AdminAccountsView(admin)
        1 -> AdminBansView(admin)
        else -> ServerPropertiesView(admin)
    }
}
