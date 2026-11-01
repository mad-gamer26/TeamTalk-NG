/*
 * A connected server: the channel tree and its bottom toolbar, messages,
 * and a channel's and a person's details.
 */
package com.matthewdovi.teamtalkng.ui

import android.content.ClipData
import android.content.ClipboardManager
import androidx.compose.foundation.background
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
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Build
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
import androidx.compose.material3.ScrollableTabRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
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
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.core.content.getSystemService
import com.matthewdovi.teamtalkng.BuildConfig
import com.matthewdovi.teamtalkng.ChannelRow
import com.matthewdovi.teamtalkng.MsgType
import com.matthewdovi.teamtalkng.MyTextMessage
import com.matthewdovi.teamtalkng.PREF_GENERAL_SENDONRETURN
import com.matthewdovi.teamtalkng.Prefs
import com.matthewdovi.teamtalkng.R
import com.matthewdovi.teamtalkng.STATUSMODE_FEMALE
import com.matthewdovi.teamtalkng.STATUSMODE_NEUTRAL
import com.matthewdovi.teamtalkng.ServerSession
import com.matthewdovi.teamtalkng.ServerStore
import com.matthewdovi.teamtalkng.SessionManager
import com.matthewdovi.teamtalkng.announce
import com.matthewdovi.teamtalkng.preferredGenderIndex
import com.matthewdovi.teamtalkng.refVolume
import com.matthewdovi.teamtalkng.refVolumeToPercent
import dk.bearware.AudioCodec
import dk.bearware.Channel
import dk.bearware.ChannelType
import dk.bearware.ClientEvent
import dk.bearware.Codec
import dk.bearware.OpusConstants
import dk.bearware.SpeexConstants
import dk.bearware.StreamType
import dk.bearware.Subscription
import dk.bearware.TTMessage
import dk.bearware.User
import dk.bearware.UserAccount
import dk.bearware.UserRight
import dk.bearware.UserState
import dk.bearware.UserType

/** Listens to a session's events while this screen is on. */
@Composable
fun SessionEvents(session: ServerSession, handler: (TTMessage) -> Unit) {
    DisposableEffect(session) {
        session.listeners.add(handler)
        onDispose { session.listeners.remove(handler) }
    }
}

/** A session's pending alert, on whichever of its screens is showing. */
@Composable
fun SessionAlertDialog(session: ServerSession) {
    session.alert?.let { alert ->
        MessageDialog(alert.title, alert.message) {
            session.alert = null
            alert.dismissed()
        }
    }
}

@Composable
private fun ToolButton(label: String, painter: Painter, tint: Color = MaterialTheme.colorScheme.primary, stateText: String? = null, onClick: () -> Unit) {
    IconButton(
        onClick = onClick,
        modifier = Modifier.semantics { if (stateText != null) stateDescription = stateText },
    ) {
        Icon(painter, contentDescription = label, tint = tint)
    }
}

@Composable
private fun SessionToolbar(session: ServerSession) {
    session.tick.intValue // follows the flags below
    val streaming = session.streaming
    val canVoice = session.canUseVoiceTx()
    val inChannel = session.isInChannel
    val hasAudio = inChannel && session.channelSupportsAudio(session.myChannel)
    var broadcast by remember { mutableStateOf(false) }
    var manage by remember { mutableStateOf(false) }

    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        if (canVoice && !streaming.audioBlockStreamingActive()) {
            val on = session.isTransmitting
            ToolButton(if (on) "Mute" else "Unmute", painterResource(if (on) R.drawable.ic_mic else R.drawable.ic_mic_off),
                onClick = session::toggleVoiceTransmission)
        }
        if (canVoice) ToolButton("Audio Controls", painterResource(R.drawable.ic_volume)) { Navigator.push(Screen.AudioControls(session)) }
        ToolButton("App Settings", rememberVectorPainter(Icons.Filled.Settings)) { Navigator.push(Screen.Settings) }
        if (inChannel) {
            ToolButton("Messages", painterResource(R.drawable.ic_message)) { Navigator.push(Screen.Messages(session, 0)) }
            if (hasAudio) {
                ToolButton("Audio File", painterResource(R.drawable.ic_audio_file)) { Navigator.push(Screen.AudioFile(session)) }
                if (BuildConfig.HAS_AUDIONET) ToolButton("AudioNet", painterResource(R.drawable.ic_audionet)) { Navigator.push(Screen.AudioNet(session)) }
            }
            // Only where there is audio you may record; while recording (or waiting to) it stays.
            val recorder = session.recorder
            if ((hasAudio && recorder.problem() == null) || recorder.wanted) {
                ToolButton("Record", painterResource(R.drawable.ic_record),
                    tint = if (recorder.isRecording) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary,
                    stateText = if (recorder.isRecording) "Recording" else null) { Navigator.push(Screen.Recording(session)) }
            }
            ToolButton("Files", painterResource(R.drawable.ic_folder)) { Navigator.push(Screen.Files(session)) }
        }
        if (session.isAdmin) {
            Box {
                ToolButton("Manage Server", rememberVectorPainter(Icons.Filled.Build)) { manage = true }
                DropdownMenu(expanded = manage, onDismissRequest = { manage = false }) {
                    DropdownMenuItem(text = { Text("Accounts") }, onClick = { manage = false; Navigator.push(Screen.AdminAccounts(session)) })
                    DropdownMenuItem(text = { Text("Bans") }, onClick = { manage = false; Navigator.push(Screen.AdminBans(session)) })
                    DropdownMenuItem(text = { Text("Edit Server Properties") }, onClick = { manage = false; Navigator.push(Screen.ServerProperties(session)) })
                }
            }
        } else {
            ToolButton("View My Information", rememberVectorPainter(Icons.Filled.Person)) { Navigator.push(Screen.MyInformation(session)) }
        }
        if (session.canBroadcast) {
            ToolButton("Broadcast Message", rememberVectorPainter(Icons.Filled.Notifications)) { broadcast = true }
        }
    }
    if (broadcast) {
        TextEntryDialog("Broadcast Message", "Message", "Send", onDismiss = { broadcast = false }) {
            val content = it.trim()
            if (content.isNotEmpty()) session.sendBroadcast(content)
        }
    }
}

/** Connected servers side by side when there are two or more. */
@Composable
private fun SessionTabs(session: ServerSession) {
    if (!SessionManager.showsSessionTabs) return
    val index = SessionManager.sessions.indexOf(session).coerceAtLeast(0)
    ScrollableTabRow(selectedTabIndex = index, edgePadding = 8.dp, modifier = Modifier.semantics { contentDescription = "Connected Servers" }) {
        SessionManager.sessions.forEachIndexed { i, s ->
            Tab(selected = i == index, onClick = { Navigator.show(s) }, text = { Text(s.displayName) })
        }
    }
}

@Composable
fun SessionScreen(session: ServerSession) {
    val context = LocalContext.current
    var passwordFor by remember { mutableStateOf<Channel?>(null) }
    var saving by remember { mutableStateOf(false) }
    var confirmDisconnect by remember { mutableStateOf(false) }
    LaunchedEffect(session) {
        session.openConversation = { id ->
            // The conversation comes up over this server's screens.
            Navigator.push(Screen.Messages(session, id))
        }
    }

    ScreenFrame(
        session.displayName,
        onBack = { Navigator.popToRoot() },
        actions = {
            if (!ServerStore.isSaved(session.server)) TextButton(onClick = { saving = true }) { Text("Save Server") }
            TextButton(onClick = { confirmDisconnect = true }) { Text("Disconnect") }
        },
        bottom = { SessionToolbar(session) },
    ) {
        SessionTabs(session)
        val rows = session.rows()
        if (rows.isEmpty()) {
            Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("No channels yet", style = MaterialTheme.typography.titleMedium)
                    Text("Connect to a server to see channels and users here.", color = secondaryText())
                }
            }
        } else {
            LazyColumn(Modifier.fillMaxSize()) {
                items(rows, key = {
                    when (it) {
                        is ChannelRow.ChannelItem -> "c${it.channel.nChannelID}"
                        is ChannelRow.UserItem -> "u${it.user.nUserID}"
                    }
                }) { row ->
                    when (row) {
                        is ChannelRow.ChannelItem -> ChannelRowView(session, row.channel, row.level) { passwordFor = it }
                        is ChannelRow.UserItem -> UserRowView(session, row.user, row.level)
                    }
                    RowDivider()
                }
            }
        }
    }

    passwordFor?.let { channel ->
        TextEntryDialog("Enter Password", "Password", "Join", session.rememberedPassword(channel.nChannelID),
            onDismiss = { passwordFor = null }) { session.joinChannel(channel, it) }
    }
    if (saving) {
        TextEntryDialog("Save Server", "Server Name", "Save", session.publicServerName.ifEmpty { "Server" },
            "Enter a name for this server.", onDismiss = { saving = false }) { name ->
            val named = name.trim().ifEmpty { session.displayName }
            ServerStore.saveNamed(session.server.copy(), named)
            session.server = session.server.copy(name = named)
        }
    }
    if (confirmDisconnect) {
        ConfirmationDialog("Disconnect from ${session.displayName}?", "Disconnect", onConfirm = { session.disconnect() }, onDismiss = { confirmDisconnect = false })
    }
    SessionAlertDialog(session)
}

@Composable
private fun ChannelRowView(session: ServerSession, channel: Channel, level: Int, askPassword: (Channel) -> Unit) {
    val id = channel.nChannelID
    val isExpanded = id in session.expanded
    val expandable = session.channelHasExpandableRows(channel)
    var menu by remember { mutableStateOf(false) }
    val title = limitTitle(session.channelTitle(channel))
    val topic = channel.szTopic.orEmpty()

    fun join() = if (channel.bPassword) askPassword(channel) else session.joinChannel(channel)
    val actions = buildList<Pair<String, () -> Unit>> {
        if (session.moveUsers.isNotEmpty()) add("Move users here" to { session.moveInto(id) })
        if (id == session.myChannel.nChannelID) add("Leave channel" to { session.leaveCurrentChannel() })
        else add("Join channel" to { join() })
        add("Create Channel" to {
            val parent = if (id == 0) session.channels.values.firstOrNull { it.nParentID == 0 }?.nChannelID ?: 0 else id
            Navigator.push(Screen.ChannelDetail(session, Channel(true, true).apply { nParentID = parent }))
        })
        add(session.channelEditActionTitle(channel) to { Navigator.push(Screen.ChannelDetail(session, channelForEdit(session, id))) })
    }

    Box {
        Row(
            Modifier
                .fillMaxWidth()
                .heightIn(min = 52.dp)
                .clickable(onClick = { session.toggleChannelExpanded(id) })
                .longPressOnly { menu = true }
                .semantics(mergeDescendants = true) {
                    heading()
                    role = Role.Button
                    if (isExpanded) collapse { session.toggleChannelExpanded(id); true } else expand { session.toggleChannelExpanded(id); true }
                    customActions = actions.map { (label, perform) -> CustomAccessibilityAction(label) { perform(); true } }
                }
                .padding(start = (8 + level * 20).dp, end = 16.dp, top = 8.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(Modifier.size(28.dp), contentAlignment = Alignment.Center) {
                if (expandable) {
                    Icon(if (isExpanded) Icons.Filled.KeyboardArrowDown else Icons.Filled.KeyboardArrowRight, contentDescription = null, tint = secondaryText())
                }
            }
            Column {
                Text(title, style = MaterialTheme.typography.bodyLarge)
                if (topic.isNotEmpty()) Text(topic, style = MaterialTheme.typography.bodySmall, color = secondaryText())
            }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            actions.forEach { (label, perform) ->
                DropdownMenuItem(text = { Text(label) }, onClick = { menu = false; perform() })
            }
        }
    }
}

private fun limitTitle(text: String) = com.matthewdovi.teamtalkng.limitText(text)

/** A fresh copy to edit, with the password this session remembers. */
private fun channelForEdit(session: ServerSession, id: Int): Channel {
    val channel = Channel()
    session.tt.getChannel(id, channel)
    if (channel.szPassword.isNullOrEmpty()) channel.szPassword = session.rememberedPassword(id)
    return channel
}

@Composable
private fun UserRowView(session: ServerSession, user: User, level: Int) {
    session.tick.intValue
    val id = user.nUserID
    val isMe = session.myUserID == id
    val name = session.displayName(user)
    val status = user.szStatusMsg.orEmpty()
    val female = user.nStatusMode and STATUSMODE_FEMALE != 0
    val neutral = user.nStatusMode and STATUSMODE_NEUTRAL != 0 || (isMe && preferredGenderIndex() == 2)
    val isAdmin = user.uUserType and UserType.USERTYPE_ADMIN != 0
    val talking = user.uUserState and UserState.USERSTATE_VOICE != 0 || (isMe && session.isTransmitting)
    val gender = if (female) "Female" else if (neutral) "Neutral" else "Male"
    val unread = id in session.unread
    val mutedVoice = user.uUserState and UserState.USERSTATE_MUTE_VOICE != 0
    val op = session.isOperator(session.myUserID, user.nChannelID)
    var menu by remember { mutableStateOf(false) }

    val actions = buildList<Pair<String, () -> Unit>> {
        add("Send private message" to { Navigator.push(Screen.Messages(session, id)) })
        add((if (mutedVoice) "Unmute" else "Mute") to { session.toggleMute(user) })
        if (session.hasRight(UserRight.USERRIGHT_MOVE_USERS)) add("Move user" to { if (id !in session.moveUsers) session.moveUsers.add(id) })
        if (session.hasRight(UserRight.USERRIGHT_KICK_USERS) || op) add("Kick user" to { session.kick(id) })
        if (session.hasRight(UserRight.USERRIGHT_BAN_USERS) || op) add("Ban user" to { session.ban(id) })
    }
    val spoken = listOf(name, if (talking) "Speaking" else "", status, gender, if (isAdmin) "Administrator" else "", if (unread) "Unread messages" else "")
        .filter { it.isNotEmpty() }.joinToString(", ")

    Box {
        Row(
            Modifier
                .fillMaxWidth()
                .heightIn(min = 52.dp)
                .clickable(onClick = { Navigator.push(Screen.UserDetail(session, id)) })
                .longPressOnly { menu = true }
                .clearAndSetSemantics {
                    contentDescription = spoken
                    role = Role.Button
                    customActions = actions.map { (label, perform) -> CustomAccessibilityAction(label) { perform(); true } }
                }
                .padding(start = (8 + level * 20).dp, end = 16.dp, top = 6.dp, bottom = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.Filled.Person, contentDescription = null,
                tint = when {
                    talking -> Color(0xFF34C759)
                    female -> Color(0xFFFF2D92)
                    else -> MaterialTheme.colorScheme.primary
                },
                modifier = Modifier.size(28.dp),
            )
            Spacer(Modifier.width(8.dp))
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(name, style = MaterialTheme.typography.bodyLarge)
                    if (isAdmin) Icon(Icons.Filled.Star, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(14.dp))
                }
                Text(status.ifEmpty { "Available" }, style = MaterialTheme.typography.bodySmall, color = secondaryText())
            }
            if (unread) Icon(painterResource(R.drawable.ic_message), contentDescription = null, tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(20.dp))
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            actions.forEach { (label, perform) ->
                DropdownMenuItem(text = { Text(label) }, onClick = { menu = false; perform() })
            }
        }
    }
}

private enum class MessageFilter(val title: String) { UserMessages("User Messages"), ServerEvents("Server Events") }

private fun copyToClipboard(text: String) {
    if (text.isEmpty()) return
    appContext.getSystemService<ClipboardManager>()?.setPrimaryClip(ClipData.newPlainText("TeamTalk", text))
    announce("Copied to clipboard.")
}

/** The channel's messages (userID 0) or a private conversation. */
@Composable
fun MessagesScreen(session: ServerSession, userID: Int) {
    val all: List<MyTextMessage> = if (userID == 0) session.channelMessages else session.privateMessages[userID].orEmpty()
    var filter by remember { mutableStateOf(MessageFilter.UserMessages) }
    var clearing by remember { mutableStateOf(false) }
    var draft by remember { mutableStateOf("") }
    val visible = when {
        userID != 0 -> all
        filter == MessageFilter.UserMessages -> all.filter { it.msgtype != MsgType.LogMsg }
        else -> all.filter { it.msgtype == MsgType.LogMsg }
    }
    val listState = rememberLazyListState()
    LaunchedEffect(visible.size) { if (visible.isNotEmpty()) listState.scrollToItem(visible.size - 1) }
    DisposableEffect(userID) {
        session.visibleConversation = userID
        session.unread.remove(userID)
        onDispose {
            session.visibleConversation = -1
            session.unread.remove(userID)
        }
    }

    fun send() {
        val content = draft.trim()
        draft = ""
        if (content.isNotEmpty()) session.sendText(userID, content)
    }

    val title = if (userID > 0) session.users[userID]?.let { session.displayName(it) } ?: "Messages" else "Messages"
    ScreenFrame(
        title,
        actions = { if (all.isNotEmpty()) TextButton(onClick = { clearing = true }) { Text("Clear") } },
        bottom = {
            val sendOnReturn = Prefs.on(PREF_GENERAL_SENDONRETURN)
            Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(
                    value = draft,
                    onValueChange = { draft = it },
                    label = { Text("Message text") },
                    modifier = Modifier.weight(1f),
                    singleLine = sendOnReturn,
                    maxLines = 4,
                    keyboardOptions = KeyboardOptions(imeAction = if (sendOnReturn) ImeAction.Send else ImeAction.Default),
                    keyboardActions = KeyboardActions(onSend = { send() }),
                )
                TextButton(onClick = ::send) { Text("Send") }
            }
        },
    ) {
        if (userID == 0) {
            PrimaryTabRow(selectedTabIndex = filter.ordinal) {
                MessageFilter.entries.forEach {
                    Tab(selected = it == filter, onClick = { filter = it }, text = { Text(it.title) })
                }
            }
        }
        if (visible.isEmpty()) {
            Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("No messages", style = MaterialTheme.typography.titleMedium)
                    Text(
                        when {
                            userID != 0 -> "Private messages will appear here."
                            filter == MessageFilter.UserMessages -> "Channel messages will appear here."
                            else -> "Server events will appear here."
                        },
                        color = secondaryText(),
                    )
                }
            }
        } else {
            LazyColumn(Modifier.fillMaxSize().padding(horizontal = 12.dp), state = listState) {
                items(visible) { MessageRow(session, it) }
            }
        }
    }
    if (clearing) {
        ConfirmationDialog(
            if (userID == 0) "This clears all messages and server events from this screen." else "This clears all messages from this private conversation screen.",
            "Clear",
            onConfirm = { if (userID == 0) session.channelMessages.clear() else session.clearConversation(userID) },
            onDismiss = { clearing = false },
        )
    }
    SessionAlertDialog(session)
}

@Composable
private fun MessageRow(session: ServerSession, m: MyTextMessage) {
    val mine = m.msgtype == MsgType.PrivImMyself || m.msgtype == MsgType.ChanImMyself
    val myBroadcast = m.msgtype == MsgType.Bcast && m.fromUserID == session.myUserID
    val sender = when {
        mine -> "Your Message"
        myBroadcast -> "Your Broadcast Message"
        else -> com.matthewdovi.teamtalkng.limitText(m.nickname)
    }
    val spoken = when {
        m.msgtype == MsgType.LogMsg -> "${m.message}, ${m.time}"
        myBroadcast -> "$sender: ${m.message}, ${m.time}"
        m.msgtype == MsgType.Bcast -> "$sender (broadcast): ${m.message}, ${m.time}"
        else -> "$sender, ${m.message}, ${m.time}"
    }
    val background = when {
        mine -> MaterialTheme.colorScheme.primary
        m.msgtype == MsgType.LogMsg -> Color.Transparent
        else -> MaterialTheme.colorScheme.surface
    }
    val textColor = if (mine) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface
    Column(
        Modifier
            .fillMaxWidth()
            .clickable(onClickLabel = "Copy to clipboard") { copyToClipboard(m.message) }
            .clearAndSetSemantics { contentDescription = spoken }
            .padding(vertical = 4.dp),
        horizontalAlignment = if (mine) Alignment.End else Alignment.Start,
    ) {
        Text(
            if (m.msgtype == MsgType.LogMsg) m.time else "$sender, ${m.time}",
            style = MaterialTheme.typography.labelSmall, color = secondaryText(),
        )
        Surface(shape = RoundedCornerShape(16.dp), color = background) {
            Text(m.message, color = textColor, modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp))
        }
    }
}

// MARK: Channel details

private fun codecDetail(codec: AudioCodec): String {
    fun band(mode: Int) = when (mode) { 2 -> "32 KHz"; 1 -> "16 KHz"; else -> "8 KHz" }
    return when (codec.nCodec) {
        Codec.OPUS_CODEC -> "OPUS ${codec.opus.nSampleRate / 1000} KHz ${codec.opus.nBitRate / 1000} KB/s ${if (codec.opus.nChannels > 1) "Stereo" else "Mono"}"
        Codec.SPEEX_CODEC -> "Speex ${band(codec.speex.nBandmode)}"
        Codec.SPEEX_VBR_CODEC -> "Speex VBR ${band(codec.speex_vbr.nBandmode)}"
        else -> "No Audio"
    }
}

@Composable
fun ChannelDetailScreen(session: ServerSession, channel: Channel) {
    val isNew = channel.nChannelID == 0
    var name by remember { mutableStateOf(channel.szName.orEmpty()) }
    var password by remember { mutableStateOf(channel.szPassword.orEmpty()) }
    var topic by remember { mutableStateOf(channel.szTopic.orEmpty()) }
    var type by remember { mutableIntStateOf(channel.uChannelType) }
    var editingCodec by remember { mutableStateOf(false) }
    var codecRevision by remember { mutableIntStateOf(0) }
    var cmdid by remember { mutableIntStateOf(0) }
    var askPassword by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    SessionEvents(session) { m ->
        when (m.nClientEvent) {
            ClientEvent.CLIENTEVENT_CMD_SUCCESS -> if (m.nSource == cmdid && cmdid != 0) Navigator.pop()
            ClientEvent.CLIENTEVENT_CMD_ERROR -> if (m.nSource == cmdid) error = m.clienterrormsg.szErrorMsg
        }
    }

    fun save() {
        channel.szName = name.trim()
        channel.szPassword = password
        channel.szTopic = topic
        channel.uChannelType = type
        cmdid = if (isNew) session.tt.doJoinChannel(channel) else session.tt.doUpdateChannel(channel)
    }

    @Composable
    fun Flag(label: String, flag: Int) = ToggleRow(label, type and flag != 0) { type = if (it) type or flag else type and flag.inv() }

    if (editingCodec) {
        AudioCodecEditor(channel.audiocodec, isNew) {
            editingCodec = false
            codecRevision++
        }
        return
    }

    ScreenFrame(
        if (isNew) "Create Channel" else name.ifEmpty { "Channel" },
        actions = { TextButton(onClick = ::save) { Text(if (isNew) "Create" else "Save") } },
    ) {
        GroupedBody {
            GroupedSection(header = "Channel Properties") {
                listOf(Triple("Name", name) { v: String -> name = v }, Triple("Password", password) { v: String -> password = v }, Triple("Topic", topic) { v: String -> topic = v })
                    .forEach { (label, value, set) ->
                        OutlinedTextField(value, set, label = { Text(label) }, singleLine = true,
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp))
                    }
                codecRevision.let { NavRow("Audio Codec", codecDetail(channel.audiocodec)) { editingCodec = true } }
                Flag("Permanent Channel", ChannelType.CHANNEL_PERMANENT)
                Flag("No Interruptions", ChannelType.CHANNEL_SOLO_TRANSMIT)
                Flag("No Voice Activation", ChannelType.CHANNEL_NO_VOICEACTIVATION)
                Flag("No Audio Recording", ChannelType.CHANNEL_NO_RECORDING)
                Flag("Hidden Channel", ChannelType.CHANNEL_HIDDEN)
            }
            if (!isNew) {
                GroupedSection(header = "Commands") {
                    TextRow("Join Channel", onClick = {
                        if (channel.bPassword) askPassword = true else cmdid = session.tt.doJoinChannelByID(channel.nChannelID, "")
                    })
                    RowDivider()
                    TextRow("Delete Channel", color = MaterialTheme.colorScheme.error, onClick = {
                        cmdid = session.tt.doRemoveChannel(channel.nChannelID)
                    })
                }
            }
        }
    }
    if (askPassword) {
        TextEntryDialog("Enter Password", "Password", "Join", password, secret = true, onDismiss = { askPassword = false }) {
            cmdid = session.tt.doJoinChannelByID(channel.nChannelID, it)
        }
    }
    error?.let { MessageDialog("Error", it) { error = null } }
    SessionAlertDialog(session)
}

/** Choosing a channel's codec, written straight into [codec]. */
@Composable
private fun AudioCodecEditor(codec: AudioCodec, isNew: Boolean, done: () -> Unit) {
    var active by remember { mutableIntStateOf(if (codec.nCodec == Codec.NO_CODEC && isNew) Codec.OPUS_CODEC else codec.nCodec) }
    val opus = remember { codec.opus }
    val speex = remember { codec.speex }
    val vbr = remember { codec.speex_vbr }
    var opusApp by remember { mutableIntStateOf(opus.nApplication) }
    var opusRate by remember { mutableIntStateOf(opus.nSampleRate) }
    var opusChannels by remember { mutableIntStateOf(opus.nChannels) }
    var opusBitrate by remember { mutableStateOf("%.1f".format(opus.nBitRate.coerceIn(OpusConstants.OPUS_MIN_BITRATE, OpusConstants.OPUS_MAX_BITRATE) / 1000.0)) }
    var opusVbr by remember { mutableStateOf(opus.bVBR) }
    var opusDtx by remember { mutableStateOf(opus.bDTX) }
    var opusFrame by remember { mutableIntStateOf(opus.nFrameSizeMSec) }
    var opusTx by remember { mutableIntStateOf(opus.nTxIntervalMSec) }
    var spxBand by remember { mutableIntStateOf(speex.nBandmode) }
    var spxQuality by remember { mutableIntStateOf(speex.nQuality) }
    var spxTx by remember { mutableIntStateOf(speex.nTxIntervalMSec) }
    var vbrBand by remember { mutableIntStateOf(vbr.nBandmode) }
    var vbrQuality by remember { mutableIntStateOf(vbr.nQuality) }
    var vbrBitrate by remember { mutableStateOf("%.1f".format(vbr.nMaxBitRate.coerceIn(0, SpeexConstants.SPEEX_UWB_MAX_BITRATE) / 1000.0)) }
    var vbrDtx by remember { mutableStateOf(vbr.bDTX) }
    var vbrTx by remember { mutableIntStateOf(vbr.nTxIntervalMSec) }

    fun bits(text: String, min: Int, max: Int) =
        ((text.toDoubleOrNull() ?: 0.0).coerceIn(min / 1000.0, max / 1000.0) * 1000).toInt()

    fun use() {
        codec.nCodec = active
        when (active) {
            Codec.OPUS_CODEC -> {
                opus.nApplication = opusApp
                opus.nBitRate = bits(opusBitrate, OpusConstants.OPUS_MIN_BITRATE, OpusConstants.OPUS_MAX_BITRATE)
                opus.nSampleRate = opusRate
                opus.nChannels = opusChannels
                opus.nTxIntervalMSec = opusTx
                opus.bDTX = opusDtx
                opus.bVBR = opusVbr
                opus.nFrameSizeMSec = opusFrame
            }
            Codec.SPEEX_CODEC -> {
                speex.nBandmode = spxBand
                speex.nQuality = spxQuality
                speex.nTxIntervalMSec = spxTx
            }
            Codec.SPEEX_VBR_CODEC -> {
                vbr.nBandmode = vbrBand
                vbr.nQuality = vbrQuality
                vbr.nMaxBitRate = bits(vbrBitrate, 0, SpeexConstants.SPEEX_UWB_MAX_BITRATE)
                vbr.bDTX = vbrDtx
                vbr.nTxIntervalMSec = vbrTx
            }
        }
        done()
    }

    val bands = listOf(0 to "8 KHz", 1 to "16 KHz", 2 to "32 KHz")
    ScreenFrame("Audio Codec", onBack = done, actions = { TextButton(onClick = ::use) { Text("Use") } }) {
        GroupedBody {
            GroupedSection {
                ChoiceRow("Codec", listOf(Codec.OPUS_CODEC to "OPUS", Codec.SPEEX_CODEC to "Speex", Codec.SPEEX_VBR_CODEC to "Speex Variable Bitrate", Codec.NO_CODEC to "No Audio"), active) { active = it }
            }
            when (active) {
                Codec.OPUS_CODEC -> GroupedSection(header = "OPUS Codec") {
                    ChoiceRow("Application", listOf(OpusConstants.OPUS_APPLICATION_VOIP to "VoIP", OpusConstants.OPUS_APPLICATION_AUDIO to "Music"), opusApp) { opusApp = it }
                    ChoiceRow("Sample Rate", listOf(8000, 12000, 16000, 24000, 48000).map { it to "${it / 1000} KHz" }, opusRate) { opusRate = it }
                    ChoiceRow("Audio Channels", listOf(1 to "Mono", 2 to "Stereo"), opusChannels) { opusChannels = it }
                    OutlinedTextField(opusBitrate, { opusBitrate = it }, label = { Text("Bitrate") }, singleLine = true,
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp))
                    ToggleRow("Variable Bitrate", opusVbr) { opusVbr = it }
                    ToggleRow("DTX", opusDtx) { opusDtx = it }
                    StepperRow("Frame Size", opusFrame, 0, OpusConstants.OPUS_REALMAX_FRAMESIZE, 5, "ms") { opusFrame = it }
                    StepperRow("Transmit Interval", opusTx, 20, 500, 20, "ms") {
                        opusTx = it
                        if (opusFrame == 0 && it > OpusConstants.OPUS_REALMAX_FRAMESIZE) opusFrame = OpusConstants.OPUS_REALMAX_FRAMESIZE
                        else if (opusFrame >= it) opusFrame = 0
                    }
                }
                Codec.SPEEX_CODEC -> GroupedSection(header = "Speex Codec") {
                    ChoiceRow("Sample Rate", bands, spxBand) { spxBand = it }
                    SliderRow("Quality", spxQuality.toFloat(), 0f, 10f, 9, "$spxQuality") { spxQuality = it.toInt() }
                    StepperRow("Transmit Interval", spxTx, 20, 500, 20, "ms") { spxTx = it }
                }
                Codec.SPEEX_VBR_CODEC -> GroupedSection(header = "Speex Variable Bitrate Codec") {
                    ChoiceRow("Sample Rate", bands, vbrBand) { vbrBand = it }
                    SliderRow("Quality", vbrQuality.toFloat(), 0f, 10f, 9, "$vbrQuality") { vbrQuality = it.toInt() }
                    OutlinedTextField(vbrBitrate, { vbrBitrate = it }, label = { Text("Bitrate") }, singleLine = true,
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp))
                    ToggleRow("DTX", vbrDtx) { vbrDtx = it }
                    StepperRow("Transmit Interval", vbrTx, 20, 500, 20, "ms") { vbrTx = it }
                }
            }
        }
    }
}

// MARK: A person's details

fun clientDisplayName(name: String, version: Int): String {
    val text = if (version == 0) "" else "${(version shr 16) and 0xFF}.${(version shr 8) and 0xFF}.${version and 0xFF}"
    return listOf(name.trim(), text).filter { it.isNotEmpty() }.joinToString(" ")
}

@Composable
fun InfoRows(rows: List<Pair<String, String>>) {
    rows.filter { it.second.isNotBlank() }.forEachIndexed { i, (label, value) ->
        if (i > 0) RowDivider()
        ValueRow(label, value.trim()) { copyToClipboard(value.trim()) }
    }
}

@Composable
fun UserDetailScreen(session: ServerSession, userID: Int) {
    val user = session.users[userID] ?: User().also { session.tt.getUser(userID, it) }
    var kickCmd by remember { mutableIntStateOf(0) }
    var banCmd by remember { mutableIntStateOf(0) }
    var error by remember { mutableStateOf<String?>(null) }
    var expanded by remember { mutableStateOf(setOf<String>()) }
    val tt = session.tt
    SessionEvents(session) { m ->
        when (m.nClientEvent) {
            ClientEvent.CLIENTEVENT_CMD_SUCCESS -> if (m.nSource == banCmd && banCmd != 0) tt.doBanUser(userID, 0)
            ClientEvent.CLIENTEVENT_CMD_ERROR -> if (m.nSource == kickCmd || m.nSource == banCmd) error = m.clienterrormsg.szErrorMsg
        }
    }
    val admin = session.isAdmin

    @Composable
    fun Section(title: String, content: @Composable () -> Unit) {
        DisclosureSection(title, title in expanded, { expanded = if (it) expanded + title else expanded - title }) { content() }
    }

    fun state() = tt.pumpMessage(ClientEvent.CLIENTEVENT_USER_STATECHANGE, userID)

    @Composable
    fun Sub(label: String, flag: Int) = SwitchRow(label, user.uLocalSubscriptions and flag != 0, {
        if (it) tt.doSubscribe(userID, flag) else tt.doUnsubscribe(userID, flag)
    })

    ScreenFrame(session.displayName(user)) {
        GroupedBody {
            Section("General") {
                val channel = when {
                    user.nChannelID <= 0 -> "No channel"
                    else -> session.channels[user.nChannelID]?.szName.orEmpty().ifEmpty { "root" }
                }
                InfoRows(buildList {
                    add("Nickname" to user.szNickname.orEmpty())
                    add("Username" to user.szUsername.orEmpty())
                    add("User ID" to user.nUserID.toString())
                    add("Status Message" to user.szStatusMsg.orEmpty())
                    add("Channel" to channel)
                    add("Client" to clientDisplayName(user.szClientName.orEmpty(), user.uVersion))
                    add("User Type" to if (user.uUserType and UserType.USERTYPE_ADMIN != 0) "Administrator" else "User")
                    if (admin) add("IP Address" to user.szIPAddress.orEmpty())
                })
            }
            Section("Volume Controls") {
                PercentSlider("Voice Volume", refVolumeToPercent(user.nVolumeVoice) / 10 * 10) {
                    tt.setUserVolume(userID, StreamType.STREAMTYPE_VOICE, refVolume(it.toDouble()))
                    state()
                }
                SwitchRow("Mute Voice", user.uUserState and UserState.USERSTATE_MUTE_VOICE != 0, {
                    tt.setUserMute(userID, StreamType.STREAMTYPE_VOICE, it)
                    state()
                })
                PercentSlider("Media File Volume", refVolumeToPercent(user.nVolumeMediaFile) / 10 * 10) {
                    tt.setUserVolume(userID, StreamType.STREAMTYPE_MEDIAFILE_AUDIO, refVolume(it.toDouble()))
                    state()
                }
                SwitchRow("Mute Media File", user.uUserState and UserState.USERSTATE_MUTE_MEDIAFILE != 0, {
                    tt.setUserMute(userID, StreamType.STREAMTYPE_MEDIAFILE_AUDIO, it)
                    state()
                })
            }
            Section("Subscriptions") {
                Sub("User Messages", Subscription.SUBSCRIBE_USER_MSG)
                Sub("Channel Messages", Subscription.SUBSCRIBE_CHANNEL_MSG)
                Sub("Broadcast Messages", Subscription.SUBSCRIBE_BROADCAST_MSG)
                Sub("Voice", Subscription.SUBSCRIBE_VOICE)
                Sub("WebCam", Subscription.SUBSCRIBE_VIDEOCAPTURE)
                Sub("Media File", Subscription.SUBSCRIBE_MEDIAFILE)
                Sub("Desktop", Subscription.SUBSCRIBE_DESKTOP)
            }
            if (admin) Section("Intercept") {
                Sub("User Messages", Subscription.SUBSCRIBE_INTERCEPT_USER_MSG)
                Sub("Channel Messages", Subscription.SUBSCRIBE_INTERCEPT_CHANNEL_MSG)
                Sub("Voice", Subscription.SUBSCRIBE_INTERCEPT_VOICE)
                Sub("WebCam", Subscription.SUBSCRIBE_INTERCEPT_VIDEOCAPTURE)
                Sub("Media File", Subscription.SUBSCRIBE_INTERCEPT_MEDIAFILE)
                Sub("Desktop", Subscription.SUBSCRIBE_INTERCEPT_DESKTOP)
            }
            Section("Actions") {
                TextRow("Send Private Message", onClick = { Navigator.push(Screen.Messages(session, userID)) })
                TextRow("Kick User", color = MaterialTheme.colorScheme.error, onClick = { kickCmd = tt.doKickUser(userID, user.nChannelID) })
                TextRow("Kick and Ban User", color = MaterialTheme.colorScheme.error, onClick = { banCmd = tt.doKickUser(userID, 0) })
            }
        }
    }
    error?.let { MessageDialog("Error", it) { error = null } }
    SessionAlertDialog(session)
}
