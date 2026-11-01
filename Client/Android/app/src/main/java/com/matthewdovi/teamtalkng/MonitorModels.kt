/*
 * What a TeamTalk NG Monitor reports, as its API sends it, and a live copy of
 * one monitored server kept up to date from the monitor's events.
 */
package com.matthewdovi.teamtalkng

import org.json.JSONArray
import org.json.JSONObject
import java.util.Date

data class MonitorUser(
    val id: Int, val nickname: String, val username: String, val statusMode: Int, val statusMsg: String,
    val clientName: String, val version: String, val userType: Int, val channelId: Int?,
    val packetProtocol: Int, val ipAddress: String?,
) {
    val displayName get() = nickname.trim().ifEmpty { username.ifEmpty { "User $id" } }
    val isAdministrator get() = userType == 2

    companion object {
        fun parse(j: JSONObject) = MonitorUser(
            j.optInt("id"), j.str("nickname"), j.str("username"), j.optInt("status_mode"), j.str("status_msg"),
            j.str("client_name"), j.str("version"), j.optInt("user_type"), j.intOrNull("channel_id"),
            j.optInt("packet_protocol"), j.str("ip_address").ifEmpty { null },
        )
    }
}

data class MonitorChannel(
    val id: Int, val parentId: Int, val name: String, val path: String, val topic: String,
    val passwordProtected: Boolean, val maxUsers: Int, val channelType: Int, val operators: List<Int>,
) {
    companion object {
        fun parse(j: JSONObject) = MonitorChannel(
            j.optInt("id"), j.optInt("parent_id"), j.str("name"), j.str("path"), j.str("topic"),
            j.optBoolean("password_protected"), j.optInt("max_users"), j.optInt("channel_type"), j.optJSONArray("operators").ints(),
        )
    }
}

data class MonitorServerInfo(
    val properties: JSONObject?, val name: String, val motd: String, val version: String,
    val protocol: String, val maxUsers: Int, val userTimeout: Int,
) {
    companion object {
        fun parse(j: JSONObject) = MonitorServerInfo(
            j.objOrNull("properties"), j.str("name"), j.str("motd"), j.str("version"),
            j.str("protocol"), j.optInt("max_users"), j.optInt("user_timeout"),
        )
    }
}

data class MonitorMe(val userId: Int, val userType: Int, val userRights: Int, val channelId: Int?) {
    companion object {
        fun parse(j: JSONObject) = MonitorMe(j.optInt("user_id"), j.optInt("user_type"), j.optLong("user_rights").toInt(), j.intOrNull("channel_id"))
    }
}

enum class MonitorConnectionStatus(val key: String, val text: String) {
    Connecting("connecting", "Connecting"),
    Connected("connected", "Logging in"),
    LoggedIn("logged_in", "Watching"),
    Disconnected("disconnected", "Disconnected"),
    LoginFailed("login_failed", "Login refused"),
    SteppedAside("stepped_aside", "Stepped aside"),
    Paused("paused", "Paused while you are connected");

    companion object {
        fun parse(key: String) = entries.firstOrNull { it.key == key } ?: Disconnected
    }
}

data class MonitorServerSummary(
    val id: Int, val name: String, val host: String, val tcpPort: Int, val encrypted: Boolean, val enabled: Boolean,
    val nickname: String, val username: String, val status: MonitorConnectionStatus, val reason: String?,
    val statusSince: Long, val serverName: String, val userCount: Int, val unreadPrivateMessages: Int,
) {
    val displayName get() = name.ifEmpty { serverName.ifEmpty { host } }

    companion object {
        fun parse(j: JSONObject) = MonitorServerSummary(
            j.optInt("id"), j.str("name"), j.str("host"), j.optInt("tcp_port"), j.optBoolean("encrypted"), j.optBoolean("enabled"),
            j.str("nickname"), j.str("username"), MonitorConnectionStatus.parse(j.str("status")), j.str("reason").ifEmpty { null },
            j.optLong("status_since"), j.str("server_name"), j.optInt("user_count"), j.optInt("unread_private_messages"),
        )
    }
}

data class MonitorUserRef(val id: Int, val nickname: String, val username: String) {
    companion object {
        fun parse(j: JSONObject) = MonitorUserRef(j.optInt("id"), j.str("nickname"), j.str("username"))
    }
}

enum class MonitorMessageKind { User, Channel, Broadcast }

data class MonitorTextMessage(
    val kind: MonitorMessageKind, val from: MonitorUserRef, val to: MonitorUserRef?, val channelId: Int?,
    val channelPath: String?, val text: String, val outgoing: Boolean, val intercepted: Boolean,
) {
    companion object {
        fun parse(j: JSONObject) = MonitorTextMessage(
            when (j.str("kind")) { "channel" -> MonitorMessageKind.Channel; "broadcast" -> MonitorMessageKind.Broadcast; else -> MonitorMessageKind.User },
            MonitorUserRef.parse(j.getJSONObject("from")), j.objOrNull("to")?.let(MonitorUserRef::parse), j.intOrNull("channel_id"),
            j.str("channel_path").ifEmpty { null }, j.str("text"), j.optBoolean("outgoing"), j.optBoolean("intercepted"),
        )
    }
}

sealed interface MonitorEvent {
    data class Connection(val status: MonitorConnectionStatus, val reason: String?) : MonitorEvent
    data class LoggedIn(val user: MonitorUser) : MonitorEvent
    data class LoggedOut(val user: MonitorUser) : MonitorEvent
    data class Joined(val user: MonitorUser, val channelId: Int, val channelPath: String) : MonitorEvent
    data class Left(val user: MonitorUser, val channelId: Int, val channelPath: String) : MonitorEvent
    data class UserUpdated(val user: MonitorUser) : MonitorEvent
    data class ChannelAdded(val channel: MonitorChannel) : MonitorEvent
    data class ChannelUpdated(val channel: MonitorChannel) : MonitorEvent
    data class ChannelRemoved(val channelId: Int, val channelPath: String) : MonitorEvent
    data class ServerUpdated(val info: MonitorServerInfo) : MonitorEvent
    data class Message(val message: MonitorTextMessage) : MonitorEvent
    data class Kicked(val by: MonitorUserRef?, val channelId: Int?) : MonitorEvent
    data class MyChannel(val channelId: Int?) : MonitorEvent
    data object Unknown : MonitorEvent

    companion object {
        fun parse(j: JSONObject): MonitorEvent = when (j.str("type")) {
            "connection" -> Connection(MonitorConnectionStatus.parse(j.str("status")), j.str("reason").ifEmpty { null })
            "logged_in" -> LoggedIn(MonitorUser.parse(j.getJSONObject("user")))
            "logged_out" -> LoggedOut(MonitorUser.parse(j.getJSONObject("user")))
            "joined" -> Joined(MonitorUser.parse(j.getJSONObject("user")), j.optInt("channel_id"), j.str("channel_path"))
            "left" -> Left(MonitorUser.parse(j.getJSONObject("user")), j.optInt("channel_id"), j.str("channel_path"))
            "user_updated" -> UserUpdated(MonitorUser.parse(j.getJSONObject("user")))
            "channel_added" -> ChannelAdded(MonitorChannel.parse(j.getJSONObject("channel")))
            "channel_updated" -> ChannelUpdated(MonitorChannel.parse(j.getJSONObject("channel")))
            "channel_removed" -> ChannelRemoved(j.optInt("channel_id"), j.str("channel_path"))
            "server_updated" -> ServerUpdated(MonitorServerInfo.parse(j.getJSONObject("info")))
            "message" -> Message(MonitorTextMessage.parse(j.getJSONObject("message")))
            "kicked" -> Kicked(j.objOrNull("by")?.let(MonitorUserRef::parse), j.intOrNull("channel_id"))
            "my_channel" -> MyChannel(j.intOrNull("channel_id"))
            else -> Unknown
        }
    }
}

data class MonitorStoredEvent(val seq: Long, val serverId: Int, val time: Long, val event: MonitorEvent) {
    val date get() = Date(time)

    companion object {
        fun parse(j: JSONObject) = MonitorStoredEvent(j.optLong("seq"), j.optInt("server_id"), j.optLong("time"), MonitorEvent.parse(j.getJSONObject("event")))
    }
}

/** A private conversation, as in TeamTalk: with one user ID for as long as that person stays logged in. */
data class MonitorConversation(
    val id: Int, val serverId: Int, val userId: Int, val nickname: String, val username: String,
    val active: Boolean, val lastText: String, val lastTime: Long, val lastOutgoing: Boolean, val unread: Int,
) {
    companion object {
        fun parse(j: JSONObject) = MonitorConversation(
            j.optInt("id"), j.optInt("server_id"), j.optInt("user_id"), j.str("nickname"), j.str("username"),
            j.optBoolean("active"), j.str("last_text"), j.optLong("last_time"), j.optBoolean("last_outgoing"), j.optInt("unread"),
        )
    }
}

data class MonitorPrivateMessage(val id: Int, val conversationId: Int, val serverId: Int, val outgoing: Boolean, val text: String, val time: Long, val read: Boolean) {
    val date get() = Date(time)

    companion object {
        fun parse(j: JSONObject) = MonitorPrivateMessage(
            j.optInt("id"), j.optInt("conversation_id"), j.optInt("server_id"), j.optBoolean("outgoing"), j.str("text"), j.optLong("time"), j.optBoolean("read"),
        )
    }
}

/** Who a private message window is with. */
data class MonitorPrivateChat(val userID: Int, val conversationID: Int?, val nickname: String)

/** What this device is notified about. */
data class MonitorPrefs(
    var logins: String = "all",
    var logouts: String = "all",
    var watched: List<String> = emptyList(),
    var privateMessages: Boolean = true,
    var channelMessages: String = "mentions",
    var mentionWords: List<String> = emptyList(),
    var broadcasts: Boolean = true,
    var connection: Boolean = true,
    var mutedServers: List<Int> = emptyList(),
    var mutedUntil: Long? = null,
    var ignored: List<String> = emptyList(),
) {
    fun toJson() = JSONObject().apply {
        put("logins", logins); put("logouts", logouts); put("watched", JSONArray(watched))
        put("private_messages", privateMessages); put("channel_messages", channelMessages)
        put("mention_words", JSONArray(mentionWords)); put("broadcasts", broadcasts); put("connection", connection)
        put("muted_servers", JSONArray(mutedServers)); put("muted_until", mutedUntil ?: JSONObject.NULL)
        put("ignored", JSONArray(ignored))
    }

    companion object {
        fun parse(j: JSONObject) = MonitorPrefs(
            j.str("logins"), j.str("logouts"), j.optJSONArray("watched").strings(), j.optBoolean("private_messages"),
            j.str("channel_messages"), j.optJSONArray("mention_words").strings(), j.optBoolean("broadcasts"), j.optBoolean("connection"),
            j.optJSONArray("muted_servers").ints(), j.longOrNull("muted_until"), j.optJSONArray("ignored").strings(),
        )
    }
}

/** Settings of a server the monitor watches, as sent to it. */
data class MonitorServerInput(
    val name: String, val host: String, val tcpPort: Int, val encrypted: Boolean, val nickname: String,
    val username: String, val password: String, val statusMsg: String, val statusMode: Int,
    val channel: String, val channelPassword: String, val enabled: Boolean,
) {
    fun toJson() = JSONObject().apply {
        put("name", name); put("host", host); put("tcp_port", tcpPort); put("encrypted", encrypted); put("nickname", nickname)
        put("username", username); put("password", password); put("status_msg", statusMsg); put("status_mode", statusMode)
        put("channel", channel); put("channel_password", channelPassword); put("enabled", enabled)
    }
}

/** A monitor's gender, which TeamTalk carries in the status mode. */
object MonitorGender {
    const val FEMALE = 0x100
    const val NEUTRAL = 0x1000
    fun statusMode(index: Int) = when (index) { 1 -> FEMALE; 2 -> NEUTRAL; else -> 0 }
    fun index(statusMode: Int) = when {
        statusMode and FEMALE != 0 -> 1
        statusMode and NEUTRAL != 0 -> 2
        else -> 0
    }
}

/** A live copy of one monitored server. */
class MonitorServerModel(view: JSONObject) {
    var summary = MonitorServerSummary.parse(view.getJSONObject("server"))
        private set
    val serverID = summary.id
    private val state = view.getJSONObject("state")
    var info = MonitorServerInfo.parse(state.getJSONObject("info"))
        private set
    var me = MonitorMe.parse(state.getJSONObject("me"))
        private set
    private val channelList = state.optJSONArray("channels").mapObjects(MonitorChannel::parse).toMutableList()
    private val userList = state.optJSONArray("users").mapObjects(MonitorUser::parse).toMutableList()
    var seq = view.optLong("seq")
        private set

    val users get() = userList.filter { it.id != me.userId }.sortedBy { it.displayName.lowercase() }
    val channels get() = channelList.sortedBy { it.path.lowercase() }
    fun channel(id: Int?) = channelList.firstOrNull { it.id == id }
    fun user(id: Int) = userList.firstOrNull { it.id == id }
    fun users(channelID: Int) = users.filter { it.channelId == channelID }

    /** Brings the copy up to date; events it already reflects are skipped. */
    fun apply(e: MonitorStoredEvent) {
        if (e.serverId != serverID || e.seq <= seq) return
        seq = e.seq
        when (val ev = e.event) {
            is MonitorEvent.Connection -> {
                summary = summary.copy(status = ev.status, reason = ev.reason)
                if (ev.status != MonitorConnectionStatus.LoggedIn) {
                    userList.clear()
                    channelList.clear()
                    me = me.copy(channelId = null)
                }
            }
            is MonitorEvent.LoggedIn -> upsert(ev.user)
            is MonitorEvent.UserUpdated -> upsert(ev.user)
            is MonitorEvent.LoggedOut -> userList.removeAll { it.id == ev.user.id }
            is MonitorEvent.Joined -> upsert(ev.user.copy(channelId = ev.channelId))
            is MonitorEvent.Left -> upsert(ev.user.copy(channelId = null))
            is MonitorEvent.ChannelAdded -> { channelList.removeAll { it.id == ev.channel.id }; channelList.add(ev.channel) }
            is MonitorEvent.ChannelUpdated -> { channelList.removeAll { it.id == ev.channel.id }; channelList.add(ev.channel) }
            is MonitorEvent.ChannelRemoved -> channelList.removeAll { it.id == ev.channelId }
            is MonitorEvent.ServerUpdated -> { info = ev.info; summary = summary.copy(serverName = ev.info.name) }
            is MonitorEvent.MyChannel -> me = me.copy(channelId = ev.channelId)
            is MonitorEvent.Kicked -> if (ev.channelId != null) me = me.copy(channelId = null)
            is MonitorEvent.Message, MonitorEvent.Unknown -> {}
        }
        summary = summary.copy(userCount = userList.size)
    }

    private fun upsert(u: MonitorUser) {
        val i = userList.indexOfFirst { it.id == u.id }
        if (i >= 0) userList[i] = u else userList.add(u)
    }
}

/** Words for monitor events, for the activity list and speech. */
object MonitorEventText {
    fun describe(e: MonitorEvent, model: MonitorServerModel?): String? = when (e) {
        is MonitorEvent.Connection ->
            if (!e.reason.isNullOrEmpty() && e.status != MonitorConnectionStatus.LoggedIn) "Monitor ${e.status.text.lowercase()}: ${e.reason}"
            else "Monitor ${e.status.text.lowercase()}"
        is MonitorEvent.LoggedIn -> "${e.user.displayName} logged in"
        is MonitorEvent.LoggedOut -> "${e.user.displayName} logged out"
        is MonitorEvent.Joined -> "${e.user.displayName} joined ${e.channelPath}"
        is MonitorEvent.Left -> "${e.user.displayName} left ${e.channelPath}"
        is MonitorEvent.UserUpdated -> if (e.user.statusMsg.isNotEmpty()) "${e.user.displayName} is now: ${e.user.statusMsg}" else null
        is MonitorEvent.ChannelAdded -> "Channel ${e.channel.path} created"
        is MonitorEvent.ChannelRemoved -> "Channel ${e.channelPath} removed"
        is MonitorEvent.Message -> {
            val m = e.message
            when {
                m.kind == MonitorMessageKind.User && m.outgoing -> "To ${m.to?.nickname.orEmpty()}: ${m.text}"
                m.kind == MonitorMessageKind.User -> "Private message from ${m.from.nickname}: ${m.text}"
                m.kind == MonitorMessageKind.Channel -> "${m.from.nickname} in ${m.channelPath.orEmpty()}: ${m.text}"
                else -> "Broadcast from ${m.from.nickname}: ${m.text}"
            }
        }
        is MonitorEvent.Kicked -> {
            val who = e.by?.nickname ?: "Someone"
            if (e.channelId == null) "$who kicked the monitor from the server" else "$who kicked the monitor from its channel"
        }
        is MonitorEvent.MyChannel -> model?.channel(e.channelId)?.let { "Monitor joined ${it.path}" } ?: "Monitor left its channel"
        is MonitorEvent.ChannelUpdated, is MonitorEvent.ServerUpdated, MonitorEvent.Unknown -> null
    }

    fun sound(e: MonitorEvent): Sounds? = when (e) {
        is MonitorEvent.LoggedIn -> Sounds.LoggedIn
        is MonitorEvent.LoggedOut -> Sounds.LoggedOut
        is MonitorEvent.Message -> if (e.message.outgoing) null else when (e.message.kind) {
            MonitorMessageKind.User -> Sounds.UserMsg
            MonitorMessageKind.Channel -> Sounds.ChanMsg
            MonitorMessageKind.Broadcast -> Sounds.BroadcastMsg
        }
        is MonitorEvent.Connection -> if (e.status == MonitorConnectionStatus.Disconnected) Sounds.SrvLost else null
        else -> null
    }
}
