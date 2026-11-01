/*
 * Talking to the TeamTalk NG monitor service: its HTTP API, a WebSocket that
 * keeps this install's monitored servers up to date while the app is open, and
 * monitoring servers from the saved list.
 */
package com.matthewdovi.teamtalkng

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Base64
import androidx.compose.runtime.mutableIntStateOf
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

sealed class MonitorException(message: String) : Exception(message) {
    class Refused(message: String) : MonitorException(message)
    class NotPaired : MonitorException("The monitor service no longer knows this phone. Monitor a server again to sign up again.")
    class Unreachable(detail: String) : MonitorException("Could not reach the monitor service: $detail")
}

object MonitorService {
    val baseURL: String = BuildConfig.SERVICE_URL
}

/** This install's sign-up with the monitor service. */
data class MonitorAccount(
    val ref: String, val name: String, val baseURL: String, val token: String, val pushKey: String,
    val deviceID: Int,
    /** The NG Account this is signed in to. */
    val email: String? = null,
) {
    val isNGAccount get() = email != null

    fun toJson() = JSONObject().put("ref", ref).put("name", name).put("baseURL", baseURL).put("token", token)
        .put("pushKey", pushKey).put("deviceID", deviceID).put("email", email ?: JSONObject.NULL)

    companion object {
        fun parse(j: JSONObject) = MonitorAccount(
            j.str("ref"), j.str("name"), j.str("baseURL"), j.str("token"), j.str("pushKey"), j.optInt("deviceID"),
            j.str("email").ifEmpty { null },
        )
    }
}

/** Settings of this installed copy only; these never sync. */
object MonitorInstall {
    lateinit var defaults: SharedPreferences
        private set
    private lateinit var androidID: String

    fun init(context: Context) {
        defaults = context.getSharedPreferences("install", Context.MODE_PRIVATE)
        androidID = Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID).orEmpty()
    }

    /** Starts over on another phone, even when the data was copied there. */
    val id: String
        get() {
            val saved = defaults.getString("MonitorInstallID", null)
            if (saved != null && defaults.getString("MonitorInstallDevice", null) == androidID) return saved
            val id = UUID.randomUUID().toString()
            defaults.edit().putString("MonitorInstallID", id).putString("MonitorInstallDevice", androidID).apply()
            return id
        }

    val deviceName: String
        get() = runCatching {
            Settings.Global.getString(TeamTalkApp.context.contentResolver, Settings.Global.DEVICE_NAME)
        }.getOrNull().orEmpty().ifEmpty { Build.MODEL }
}

/** The sign-ins, on this phone only. */
object MonitorAccountStore {
    private const val KEY = "monitor.accounts"

    fun all(): List<MonitorAccount> =
        runCatching { JSONArray(SecretStore.get(KEY) ?: "[]").mapObjects(MonitorAccount::parse) }.getOrDefault(emptyList())

    private fun write(list: List<MonitorAccount>) {
        SecretStore.put(KEY, JSONArray().apply { list.forEach { put(it.toJson()) } }.toString())
    }

    fun account(ref: String) = all().firstOrNull { it.ref == ref }
    val ngAccount get() = all().firstOrNull { it.isNGAccount }

    fun save(account: MonitorAccount) {
        write(all().filter { it.ref != account.ref && !(account.isNGAccount && it.isNGAccount) } + account)
    }

    fun remove(ref: String) = write(all().filter { it.ref != ref })
}

/** Opening the sealed text of pushes: ChaCha20-Poly1305, nonce + ciphertext + tag. */
object MonitorPush {
    fun open(sealed: String, keyBase64: String): ByteArray? = runCatching {
        val combined = Base64.decode(sealed, Base64.DEFAULT)
        val key = Base64.decode(keyBase64, Base64.DEFAULT)
        val cipher = Cipher.getInstance("ChaCha20-Poly1305")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "ChaCha20"), IvParameterSpec(combined, 0, 12))
        cipher.doFinal(combined, 12, combined.size - 12)
    }.getOrNull()

    /** A push's content and the sign-in whose key opened it. */
    fun content(ttng: JSONObject): Pair<String, JSONObject>? {
        val ref = ttng.str("ref")
        ttng.objOrNull("content")?.let { return ref to it }
        val sealed = ttng.str("sealed").ifEmpty { return null }
        val accounts = MonitorAccountStore.all()
        for (account in accounts.filter { it.ref == ref } + accounts.filter { it.ref != ref }) {
            val opened = open(sealed, account.pushKey) ?: continue
            return account.ref to (runCatching { JSONObject(String(opened)) }.getOrNull() ?: continue)
        }
        return null
    }
}

/** The monitor's API, for one sign-up. */
class MonitorAPI(val account: MonitorAccount) {
    private suspend fun request(method: String, path: String, json: Any? = null): ByteArray {
        val reply = try {
            ServiceHttp.send(method, "${account.baseURL}/$path", account.token, json)
        } catch (e: IOException) {
            throw MonitorException.Unreachable(e.message ?: "no response")
        }
        if (reply.status == 401) throw MonitorException.NotPaired()
        if (!reply.ok) throw MonitorException.Refused(reply.error ?: "HTTP ${reply.status}")
        return reply.body
    }

    private suspend fun obj(method: String, path: String, json: Any? = null) = JSONObject(String(request(method, path, json)))

    suspend fun servers() = obj("GET", "v1/servers").optJSONArray("servers").mapObjects(MonitorServerSummary::parse)
    suspend fun server(id: Int) = obj("GET", "v1/servers/$id")

    class ServerConfig(val username: String, val statusMsg: String, val statusMode: Int?, val channel: String)

    suspend fun serverConfig(id: Int) = obj("GET", "v1/servers/$id/config").let {
        ServerConfig(it.str("username"), it.str("status_msg"), it.intOrNull("status_mode"), it.str("channel"))
    }

    suspend fun addServer(s: MonitorServerInput) { request("POST", "v1/servers", s.toJson()) }
    suspend fun updateServer(id: Int, s: MonitorServerInput) { request("PUT", "v1/servers/$id", s.toJson()) }
    suspend fun removeServer(id: Int) { request("DELETE", "v1/servers/$id") }

    /** What the server answered, one object per line, its name under `type`. */
    suspend fun admin(server: Int, command: String, params: JSONObject = JSONObject()): List<JSONObject> =
        obj("POST", "v1/servers/$server/admin", JSONObject().put("command", command).put("params", params))
            .optJSONArray("lines").mapObjects { it }

    suspend fun pause(server: Int, minutes: Int) { request("POST", "v1/servers/$server/pause", JSONObject().put("minutes", minutes)) }
    suspend fun resume(server: Int) { request("DELETE", "v1/servers/$server/pause") }

    suspend fun sendPrivateMessage(server: Int, userID: Int, conversationID: Int?, text: String) {
        val body = JSONObject().put("to", "user").put("user_id", userID).put("text", text)
        conversationID?.let { body.put("conversation_id", it) }
        request("POST", "v1/servers/$server/messages", body)
    }

    suspend fun sendChannelMessage(server: Int, channelID: Int?, text: String) {
        val body = JSONObject().put("to", "channel").put("text", text)
        channelID?.let { body.put("channel_id", it) }
        request("POST", "v1/servers/$server/messages", body)
    }

    suspend fun sendBroadcast(server: Int, text: String) {
        request("POST", "v1/servers/$server/messages", JSONObject().put("to", "broadcast").put("text", text))
    }

    /** One of the monitor's actions: join, leave, move, kick, ban, nickname, status. */
    suspend fun act(server: Int, action: String, fields: JSONObject = JSONObject()) {
        request("POST", "v1/servers/$server/actions", fields.put("action", action))
    }

    suspend fun conversations(server: Int? = null) =
        obj("GET", "v1/conversations" + (server?.let { "?server_id=$it" } ?: "")).optJSONArray("conversations").mapObjects(MonitorConversation::parse)

    class Messages(val conversation: MonitorConversation, val messages: List<MonitorPrivateMessage>, val seq: Long)

    suspend fun messages(server: Int, conversation: Int): Messages {
        val j = obj("GET", "v1/servers/$server/conversations/$conversation/messages?limit=300")
        return Messages(MonitorConversation.parse(j.getJSONObject("conversation")), j.optJSONArray("messages").mapObjects(MonitorPrivateMessage::parse), j.optLong("seq"))
    }

    suspend fun deleteConversation(server: Int, conversation: Int) { request("DELETE", "v1/servers/$server/conversations/$conversation") }
    suspend fun markRead(server: Int, conversation: Int) { request("POST", "v1/servers/$server/conversations/$conversation/read") }

    suspend fun recentEvents(server: Int, limit: Int = 200) =
        obj("GET", "v1/events?server_id=$server&limit=$limit").optJSONArray("events").mapObjects(MonitorStoredEvent::parse)

    suspend fun prefs() = MonitorPrefs.parse(obj("GET", "v1/me/prefs"))
    suspend fun setPrefs(p: MonitorPrefs) { request("PUT", "v1/me/prefs", p.toJson()) }

    /** Firebase's token for this phone; null turns pushes off. */
    suspend fun registerPush(fcmToken: String?) {
        request("PUT", "v1/me/push", JSONObject().put("app_ref", account.ref).put("install_id", MonitorInstall.id)
            .put("fcm_token", fcmToken ?: JSONObject.NULL))
    }

    suspend fun unpair() { request("DELETE", "v1/me") }
}

/** One signed-up monitor while the app is open: its servers, live state, and the WebSocket keeping them current. */
class MonitorConnection(account: MonitorAccount) {
    var account = account
        private set
    var servers: List<MonitorServerSummary> = emptyList()
        private set
    val models = HashMap<Int, MonitorServerModel>()
    var lastError: String? = null
        private set
    var online = false
        private set
    var prefs: MonitorPrefs? = null

    private var socket: WebSocket? = null
    private var lastSeq: Long? = null
    private var catchingUp = false
    private var retryDelay = 1000L
    private var running = false
    private var generation = 0
    private val main = Handler(Looper.getMainLooper())

    val api get() = MonitorAPI(account)

    /** Listeners for one event: (event, caught up while away). */
    val eventListeners = mutableListOf<(MonitorStoredEvent, Boolean) -> Unit>()
    val reloadListeners = mutableListOf<(Int) -> Unit>()

    fun update(account: MonitorAccount) { this.account = account }

    fun start() {
        if (running) return
        running = true
        appScope.launch { refreshServers() }
        connect()
    }

    fun stop() {
        running = false
        generation++
        socket?.close(1001, null)
        socket = null
        online = false
    }

    suspend fun refreshServers() {
        try {
            servers = api.servers()
            prefs = runCatching { api.prefs() }.getOrNull()
            lastError = null
        } catch (_: MonitorException.NotPaired) {
            NGAccountCenter.sessionEnded()
            return
        } catch (e: Exception) {
            lastError = e.message
        }
        changed()
    }

    fun isMutedByHand(serverID: Int) = prefs?.mutedServers?.contains(serverID) == true && !MonitorCenter.isLiveMuted(serverID)

    suspend fun model(serverID: Int): MonitorServerModel {
        models[serverID]?.let { return it }
        val m = MonitorServerModel(api.server(serverID))
        models[serverID] = m
        if (lastSeq == null) lastSeq = m.seq
        return m
    }

    private suspend fun reloadModels() {
        for (id in models.keys.toList()) {
            runCatching { api.server(id) }.getOrNull()?.let {
                models[id] = MonitorServerModel(it)
                reloadListeners.toList().forEach { l -> l(id) }
            }
        }
        refreshServers()
    }

    private fun connect() {
        if (!running) return
        val gen = ++generation
        catchingUp = lastSeq != null
        val base = account.baseURL.replaceFirst("https://", "wss://").replaceFirst("http://", "ws://")
        val request = Request.Builder().url("$base/v1/ws" + (lastSeq?.let { "?since=$it" } ?: ""))
            .header("Authorization", "Bearer ${account.token}").build()
        socket = ServiceHttp.socketClient.newWebSocket(request, object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, text: String) {
                main.post { if (gen == generation) { retryDelay = 1000; handle(text) } }
            }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) = closed(gen, t.message)
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = closed(gen, reason)
        })
    }

    private fun closed(gen: Int, why: String?) {
        main.post {
            if (gen != generation) return@post
            online = false
            lastError = why
            changed()
            if (!running) return@post
            val delay = retryDelay
            retryDelay = minOf(retryDelay * 2, 30_000)
            main.postDelayed({
                if (gen == generation && running) appScope.launch { refreshServers(); connect() }
            }, delay)
        }
    }

    private fun handle(text: String) {
        val env = runCatching { JSONObject(text) }.getOrNull() ?: return
        when (env.str("type")) {
            "ready" -> {
                catchingUp = false
                online = true
                lastError = null
                if (lastSeq == null) lastSeq = env.longOrNull("seq")
                changed()
            }
            "reset" -> {
                lastSeq = env.longOrNull("seq")
                appScope.launch { reloadModels() }
            }
            "sync" -> NGAccountCenter.remoteChange()
            "event" -> env.objOrNull("event")?.let { event(MonitorStoredEvent.parse(it)) }
        }
    }

    private fun event(e: MonitorStoredEvent) {
        lastSeq = maxOf(lastSeq ?: 0, e.seq)
        models[e.serverId]?.apply(e)
        val ev = e.event
        // After logging in again the server sends its whole state at once,
        // which the monitor does not repeat as events: reload it.
        if (ev is MonitorEvent.Connection && ev.status == MonitorConnectionStatus.LoggedIn && models.containsKey(e.serverId)) {
            appScope.launch {
                runCatching { api.server(e.serverId) }.getOrNull()?.let {
                    models[e.serverId] = MonitorServerModel(it)
                    changed()
                    reloadListeners.toList().forEach { l -> l(e.serverId) }
                }
            }
        }
        servers = servers.map { s ->
            if (s.id != e.serverId) return@map s
            var next = s
            if (ev is MonitorEvent.Connection) next = next.copy(status = ev.status, reason = ev.reason)
            if (ev is MonitorEvent.Message && ev.message.kind == MonitorMessageKind.User && !ev.message.outgoing && !ev.message.intercepted) {
                next = next.copy(unreadPrivateMessages = next.unreadPrivateMessages + 1)
            }
            models[e.serverId]?.let { next = next.copy(userCount = it.summary.userCount) }
            next
        }
        // Missed while away (or simply old): already notified.
        val catchUp = catchingUp || System.currentTimeMillis() - e.time > 30_000
        eventListeners.toList().forEach { it(e, catchUp) }
        changed()
    }

    fun clearUnread(serverID: Int) {
        servers = servers.map { if (it.id == serverID) it.copy(unreadPrivateMessages = 0) else it }
        changed()
    }

    private fun changed() { MonitorCenter.revision.intValue++ }
}

/** This install's monitored servers, connected to the service while the app is in the foreground. */
object MonitorCenter {
    /** Goes up whenever anything about the monitors changes. */
    val revision = mutableIntStateOf(0)
    var connection: MonitorConnection? = null
        private set
    private var active = false
    private val liveTimers = HashMap<String, Runnable>()
    private val main = Handler(Looper.getMainLooper())

    private const val LIVE_MUTED_KEY = "MonitorLiveMutedServers"
    private const val LIVE_KEY = "MonitorLiveServers"
    private const val LIVE_LIFETIME = 15 * 60 * 1000L
    private const val GENDER_GIVEN_KEY = "MonitorGenderGiven"

    fun start() {
        MonitorInstall.defaults.edit().remove(LIVE_KEY).apply()
        reload()
    }

    fun connection(ref: String) = connection?.takeIf { it.account.ref == ref }

    /** The monitors this phone follows: the NG Account's. Monitors need one on Android. */
    fun reload() {
        val account = NGAccountCenter.signIn
        if (account != null) {
            val c = connection
            if (c != null && c.account.ref == account.ref) c.update(account) else {
                c?.stop()
                connection = MonitorConnection(account)
            }
        } else {
            connection?.stop()
            connection = null
        }
        if (active) connection?.start()
        revision.intValue++
    }

    fun foreground() {
        active = true
        reload()
        connection?.start()
        MonitorNotificationSounds.refresh()
        appScope.launch { unmuteLeftoverLiveServers(); giveMonitorsGender() }
    }

    fun background() {
        // Push notifications take over in the background, unless a server
        // stays connected and the app with it.
        if (SessionManager.sessions.isNotEmpty()) return
        active = false
        connection?.stop()
    }

    /** The monitor's settings for a saved server: its login, under a nickname that shows it is the monitor. */
    fun input(server: Server): MonitorServerInput {
        val nickname = server.nickname.trim().ifEmpty { Prefs.string(PREF_GENERAL_NICKNAME).trim() }
        return MonitorServerInput(
            server.name.ifEmpty { server.ipaddr }, server.ipaddr, server.tcpport, server.encrypted,
            if (nickname.isEmpty()) "Monitor" else "$nickname (Monitor)",
            server.username, server.password, "", MonitorGender.statusMode(preferredGenderIndex()), "", "", true,
        )
    }

    fun monitored(server: Server) = connection?.servers?.firstOrNull {
        it.host.equals(server.ipaddr, ignoreCase = true) && it.tcpPort == server.tcpport && it.username == server.username
    }

    suspend fun monitor(input: MonitorServerInput) {
        reload()
        val c = connection ?: throw MonitorException.NotPaired()
        c.api.addServer(input)
        c.refreshServers()
    }

    private fun monitoredAtAddress(server: Server) = connection?.servers?.filter {
        it.host.trim().equals(server.ipaddr.trim(), ignoreCase = true) && it.tcpPort == server.tcpport
    }.orEmpty()

    private fun live(): MutableMap<String, Long> {
        val j = JSONObject(MonitorInstall.defaults.getString(LIVE_KEY, null) ?: "{}")
        val map = HashMap<String, Long>()
        j.keys().forEach { map[it] = j.optLong(it) }
        return map
    }

    private fun mark(ref: String, id: Int) {
        val now = System.currentTimeMillis()
        val map = live().filterValues { now - it < LIVE_LIFETIME }.toMutableMap()
        map["$ref|$id"] = now
        MonitorInstall.defaults.edit().putString(LIVE_KEY, JSONObject(map as Map<*, *>).toString()).apply()
    }

    private fun unmark(ref: String, id: Int) {
        val map = live()
        map.remove("$ref|$id")
        MonitorInstall.defaults.edit().putString(LIVE_KEY, JSONObject(map as Map<*, *>).toString()).apply()
    }

    fun isLive(ref: String, serverID: Int): Boolean =
        live()["$ref|$serverID"]?.let { System.currentTimeMillis() - it < LIVE_LIFETIME } == true

    /** While connected live the monitor keeps watching but sends no notifications for it. */
    fun connectedLive(server: Server) {
        val key = "${server.ipaddr.lowercase()}:${server.tcpport}"
        appScope.launch {
            connection?.refreshServers()
            val ref = connection?.account?.ref ?: return@launch
            val monitored = monitoredAtAddress(server)
            if (monitored.isEmpty()) return@launch
            monitored.forEach { mark(ref, it.id) }
            liveTimers.remove(key)?.let { main.removeCallbacks(it) }
            val renew = object : Runnable {
                override fun run() {
                    monitored.forEach { mark(ref, it.id) }
                    main.postDelayed(this, 5 * 60 * 1000L)
                }
            }
            liveTimers[key] = renew
            main.postDelayed(renew, 5 * 60 * 1000L)
            setLiveMuted(monitored.map { it.id }, true)
        }
    }

    fun disconnectedLive(server: Server) {
        val key = "${server.ipaddr.lowercase()}:${server.tcpport}"
        liveTimers.remove(key)?.let { main.removeCallbacks(it) }
        val ref = connection?.account?.ref ?: return
        val ids = monitoredAtAddress(server).map { it.id }
        ids.forEach { unmark(ref, it) }
        if (ids.isNotEmpty()) appScope.launch { setLiveMuted(ids, false) }
    }

    private var liveMuted: Set<Int>
        get() = JSONArray(MonitorInstall.defaults.getString(LIVE_MUTED_KEY, null) ?: "[]").ints().toSet()
        set(value) { MonitorInstall.defaults.edit().putString(LIVE_MUTED_KEY, JSONArray(value.toList()).toString()).apply() }

    fun isLiveMuted(id: Int) = id in liveMuted

    /** Mute or unmute one server's notifications by hand; never undone by connecting live. */
    suspend fun setMuted(serverID: Int, muted: Boolean) {
        val c = connection ?: return
        val prefs = c.api.prefs()
        prefs.mutedServers = prefs.mutedServers.filter { it != serverID } + if (muted) listOf(serverID) else emptyList()
        c.api.setPrefs(prefs)
        liveMuted = liveMuted - serverID
        c.prefs = prefs
        revision.intValue++
    }

    private suspend fun setLiveMuted(ids: List<Int>, muted: Boolean) {
        val c = connection ?: return
        val prefs = runCatching { c.api.prefs() }.getOrNull() ?: return
        val mine = liveMuted.toMutableSet()
        val list = prefs.mutedServers.toMutableList()
        for (id in ids) {
            if (muted) {
                if (id in list) continue // Muted by hand already.
                list.add(id)
                mine.add(id)
            } else if (id in mine && !isLive(c.account.ref, id)) {
                list.remove(id)
                mine.remove(id)
            }
        }
        prefs.mutedServers = list
        runCatching { c.api.setPrefs(prefs); liveMuted = mine }
    }

    /** Nothing is connected live when the app starts: unmute what was muted for being connected. */
    private suspend fun unmuteLeftoverLiveServers() {
        val ids = liveMuted.toList()
        if (ids.isNotEmpty() && connection != null && SessionManager.sessions.isEmpty()) setLiveMuted(ids, false)
    }

    /** Monitors set up before they had a gender log in as male: give them Settings' gender, once. */
    private suspend fun giveMonitorsGender() {
        val c = connection ?: return
        if (MonitorInstall.defaults.getBoolean(GENDER_GIVEN_KEY, false)) return
        val mode = MonitorGender.statusMode(preferredGenderIndex())
        runCatching {
            if (mode != 0) for (s in c.api.servers()) {
                val config = c.api.serverConfig(s.id)
                if ((config.statusMode ?: 0) != 0) continue
                c.api.updateServer(s.id, MonitorServerInput(s.name, s.host, s.tcpPort, s.encrypted, s.nickname, config.username,
                    "", config.statusMsg, mode, config.channel, "", s.enabled))
            }
            MonitorInstall.defaults.edit().putBoolean(GENDER_GIVEN_KEY, true).apply()
        }
    }

    /** Stop monitoring every server. The NG Account stays signed in. */
    suspend fun stopEverything() {
        val c = connection ?: return
        c.api.unpair()
        c.refreshServers()
    }
}
