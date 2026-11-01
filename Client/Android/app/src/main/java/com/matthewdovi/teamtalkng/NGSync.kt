/*
 * Syncing saved servers and settings with the NG Account, in step with the
 * iPhone app. Each phone remembers what it last synced, so it only sends what
 * changed on it; when two phones change the same thing, the latest wins.
 */
package com.matthewdovi.teamtalkng

import android.os.Handler
import android.os.Looper
import android.util.Log
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.UUID

private const val TAG = "NGSync"

/** Settings that aren't numbers, strings or switches are saved as JSON behind this mark. */
private const val JSON_MARK = "\u0001json:"

object NGSync {
    /** Saved in the app's settings but synced another way. */
    private val notSettings = setOf("ServerList", "settings.selectedSoundPackID", PREF_AUDIO_OUTPUT, PREF_TTSEVENT_ENGINE, PREF_SNDINPUT_DEVICE)
    val packKeys = listOf("ng_installed_catalog_packs", "ng_selected_sound_pack")

    private fun isSetting(key: String) = key !in notSettings && key !in packKeys

    private val syncsServers get() = NGAccountCenter.isSyncing(NGAccountCenter.Category.Servers)
    private val syncsSettings get() = NGAccountCenter.isSyncing(NGAccountCenter.Category.Settings)

    private fun isSynced(key: String) =
        if (key in packKeys) NGAccountCenter.isSyncing(NGAccountCenter.Category.SoundPacks) else syncsSettings && isSetting(key)

    private class Synced(val rev: Long, val hash: String)

    private class State(val email: String) {
        var rev = 0L
        val records = HashMap<String, Synced>()
        var keepThisPhone: Boolean? = null
    }

    private val stateFile get() = File(TeamTalkApp.context.filesDir, "NGSync.json")
    private var state: State? = null
    private var running = false
    private var again = false
    private var holding = false
    private var applying = false
    private val main = Handler(Looper.getMainLooper())
    private val pending = Runnable { appScope.launch { syncNow() } }

    fun start() {
        Prefs.store.registerOnSharedPreferenceChangeListener(prefListener)
        ServerStore.saved = { localChange() }
        syncSoon()
    }

    private val prefListener = android.content.SharedPreferences.OnSharedPreferenceChangeListener { _, _ -> localChange() }

    private var lastFingerprint: String? = null

    private fun fingerprint(): String {
        val all = Prefs.store.all
        val parts = all.keys.filter { isSetting(it) || it in packKeys }.sorted().map { "$it=${all[it]}" }.toMutableList()
        parts.add(ServerStore.servers.joinToString(",") { it.toJson().toString() })
        return sha256(parts.joinToString("\n").toByteArray())
    }

    private fun localChange() {
        if (applying || !NGAccountCenter.isSignedIn) return
        val now = fingerprint()
        if (now == lastFingerprint) return
        lastFingerprint = now
        syncSoon(1500)
    }

    fun syncSoon(delay: Long = 300) {
        if (!NGAccountCenter.isSignedIn) return
        main.removeCallbacks(pending)
        main.postDelayed(pending, delay)
    }

    fun holdForSignIn() {
        holding = true
        main.removeCallbacks(pending)
    }

    fun signedIn(keepThisPhone: Boolean) {
        holding = false
        state = null
        stateFile.delete()
        if (keepThisPhone) NGAccountCenter.email?.let { saveState(State(it).apply { this.keepThisPhone = true }) }
        syncSoon(0)
    }

    /** Syncing turned back on: that category is pulled from the start. */
    fun turnedOn(category: NGAccountCenter.Category) {
        val email = NGAccountCenter.email ?: return
        val prefix = when (category) {
            NGAccountCenter.Category.Servers -> "server:"
            NGAccountCenter.Category.Settings -> "setting:"
            NGAccountCenter.Category.SoundPacks -> return
        }
        val s = loadState(email)
        s.records.keys.removeAll { it.startsWith(prefix) }
        s.rev = 0
        saveState(s)
        syncSoon(0)
    }

    fun signedOut() {
        holding = false
        main.removeCallbacks(pending)
        state = null
        stateFile.delete()
    }

    val phoneHasData: Boolean get() = ServerStore.servers.isNotEmpty() || Prefs.store.all.keys.any { isSetting(it) }

    /** Whether the account's records and this phone disagree about anything both have. */
    fun differs(records: List<NGSyncRecord>): Boolean {
        for (r in records) {
            if (r.deleted) continue
            if (r.kind == "setting" && syncsSettings && isSetting(r.key)) {
                val local = settingValue(r.key)
                if (local != null && hash(local) != hash(r.data)) return true
            } else if (r.kind == "server" && syncsServers) {
                val remote = (r.data as? JSONObject)?.let { JSONObject(it.toString()) } ?: continue
                remote.remove("order")
                val local = ServerStore.servers.firstOrNull { it.syncID == r.key } ?: ServerStore.servers.firstOrNull { sameLogin(it, remote) }
                if (local != null && hash(serverData(local)) != hash(remote)) return true
            }
        }
        return false
    }

    fun removeLocalCopy() {
        val s = state ?: NGAccountCenter.email?.let { loadState(it) } ?: return
        val synced = s.records.keys.filter { it.startsWith("server:") }.map { it.removePrefix("server:") }.toSet()
        applying = true
        ServerStore.save(ServerStore.servers.filter { it.syncID !in synced })
        applying = false
    }

    suspend fun syncNow() {
        if (holding) return
        val email = NGAccountCenter.email ?: return
        if (running) {
            again = true
            return
        }
        running = true
        try {
            do {
                again = false
                cycle(email)
            } while (again)
        } catch (_: NGAccountException.SignedOut) {
        } catch (e: Exception) {
            Log.w(TAG, "NG Account sync failed: ${e.message}")
        } finally {
            running = false
        }
    }

    private fun loadState(email: String): State {
        state?.takeIf { it.email == email }?.let { return it }
        return runCatching {
            val j = JSONObject(stateFile.readText())
            if (j.str("email") != email) return State(email)
            State(email).apply {
                rev = j.optLong("rev")
                keepThisPhone = if (j.has("keepThisPhone")) j.optBoolean("keepThisPhone") else null
                val records = j.getJSONObject("records")
                records.keys().forEach {
                    val r = records.getJSONObject(it)
                    this.records[it] = Synced(r.optLong("rev"), r.str("hash"))
                }
            }
        }.getOrElse { State(email) }
    }

    private fun saveState(s: State) {
        state = s
        val records = JSONObject()
        s.records.forEach { (k, v) -> records.put(k, JSONObject().put("rev", v.rev).put("hash", v.hash)) }
        val j = JSONObject().put("email", s.email).put("rev", s.rev).put("records", records)
        s.keepThisPhone?.let { j.put("keepThisPhone", it) }
        stateFile.writeText(j.toString())
    }

    private suspend fun cycle(email: String) {
        var s = loadState(email)

        // 1. What changed in the account.
        val pulled = NGAccountCenter.signed { it.pull(s.rev) }
        if (pulled.reset) s = State(email)
        apply(pulled.records, s)
        s.rev = maxOf(s.rev, pulled.rev)
        s.keepThisPhone = null
        saveState(s)

        // 2. What changed here, sent; changed elsewhere meanwhile: this
        // phone's change is the latest, so it goes again from there.
        var changes = localChanges(s)
        repeat(2) {
            if (changes.isEmpty()) return@repeat
            val sent = changes
            val result = NGAccountCenter.signed { it.push(sent) }
            for (r in result.applied) {
                sent.firstOrNull { it.kind == r.kind && it.key == r.key }?.let { c ->
                    s.records["${r.kind}:${r.key}"] = Synced(r.rev, hash(if (c.deleted) null else c.data))
                }
            }
            s.rev = maxOf(s.rev, result.rev)
            saveState(s)
            changes = result.conflicts.mapNotNull { conflict ->
                sent.firstOrNull { it.kind == conflict.kind && it.key == conflict.key }?.also { it.baseRev = conflict.rev }
            }
        }
    }

    private fun apply(records: List<NGSyncRecord>, s: State) {
        var servers: MutableList<Server>? = null
        applying = true
        try {
            for (r in records) {
                val id = "${r.kind}:${r.key}"
                when {
                    r.kind == "setting" && isSetting(r.key) && isSynced(r.key) && s.keepThisPhone == true && settingValue(r.key) != null ->
                        // This phone's value is kept: noted as the account's, so it differs and goes up in its place.
                        s.records[id] = Synced(r.rev, hash(if (r.deleted) null else r.data))
                    r.kind == "setting" && isSynced(r.key) -> {
                        if (r.deleted) Prefs.remove(r.key) else if (r.data != null) store(r.key, r.data)
                        s.records[id] = Synced(r.rev, hash(if (r.deleted) null else settingValue(r.key)))
                    }
                    r.kind == "server" && syncsServers -> {
                        val list = servers ?: ServerStore.servers.toMutableList().also { servers = it }
                        if (r.deleted) {
                            list.removeAll { it.syncID == r.key }
                            s.records[id] = Synced(r.rev, hash(null))
                        } else (r.data as? JSONObject)?.let { data ->
                            val existing = list.firstOrNull { it.syncID == r.key }
                                ?: list.firstOrNull { s.records["server:${it.syncID}"] == null && sameLogin(it, data) }
                            if (existing != null && s.keepThisPhone == true) {
                                // This phone's version is kept and goes up in its place.
                                existing.syncID = r.key
                                s.records[id] = Synced(r.rev, hash(data))
                            } else {
                                val server = existing ?: Server().also { list.add(it) }
                                server.syncID = r.key
                                fill(server, data)
                                val synced = serverData(server)
                                if (data.has("order")) synced.put("order", data.opt("order"))
                                s.records[id] = Synced(r.rev, hash(synced))
                            }
                        }
                    }
                }
            }
            servers?.let { list ->
                // The account's order, with servers it doesn't know where they were.
                val order = records.filter { it.kind == "server" }.mapNotNull { r ->
                    (r.data as? JSONObject)?.takeIf { it.has("order") }?.let { r.key to it.optInt("order") }
                }.toMap()
                val sorted = if (order.isNotEmpty() && s.keepThisPhone != true) {
                    list.withIndex().sortedBy { (i, server) -> order[server.syncID] ?: i }.map { it.value }
                } else list
                ServerStore.save(sorted)
            }
        } finally {
            applying = false
            lastFingerprint = fingerprint()
        }
    }

    private fun localChanges(s: State): List<NGSyncChange> {
        val changes = mutableListOf<NGSyncChange>()
        val known = s.records.keys.filter { it.startsWith("setting:") }.map { it.removePrefix("setting:") }
        val keys = (Prefs.store.all.keys + known + packKeys).filter { isSynced(it) }.toSortedSet()
        for (key in keys) {
            val value = settingValue(key)
            val id = "setting:$key"
            val h = hash(value)
            val had = s.records[id]
            if (had?.hash == h || (value == null && had == null)) continue
            changes.add(NGSyncChange("setting", key, had?.rev ?: 0, value == null, value))
        }
        if (syncsServers) {
            val present = HashSet<String>()
            ServerStore.servers.forEachIndexed { i, server ->
                present.add(server.syncID)
                val data = serverData(server).put("order", i)
                val had = s.records["server:${server.syncID}"]
                if (had?.hash != hash(data)) changes.add(NGSyncChange("server", server.syncID, had?.rev ?: 0, false, data))
            }
            for ((id, had) in s.records) {
                if (id.startsWith("server:") && had.hash != hash(null)) {
                    val key = id.removePrefix("server:")
                    if (key !in present) changes.add(NGSyncChange("server", key, had.rev, true, null))
                }
            }
        }
        return changes
    }

    /** A setting's value as JSON can carry it; null when unset. */
    private fun settingValue(key: String): Any? {
        val v = Prefs.store.all[key] ?: return null
        if (v is String && v.startsWith(JSON_MARK)) {
            val text = v.removePrefix(JSON_MARK)
            return runCatching { if (text.startsWith("[")) JSONArray(text) else JSONObject(text) }.getOrNull()
        }
        return v
    }

    private fun store(key: String, value: Any) {
        when (value) {
            is Boolean -> Prefs.set(key, value)
            is Int -> Prefs.set(key, value)
            is Long -> Prefs.set(key, value.toInt())
            is Number -> Prefs.set(key, value.toFloat())
            is String -> Prefs.set(key, value)
            is JSONArray, is JSONObject -> Prefs.set(key, JSON_MARK + value)
        }
    }

    /** Writes a list setting of sound pack sync. */
    fun setStrings(key: String, values: List<String>) = Prefs.set(key, JSON_MARK + JSONArray(values))
    fun getStrings(key: String): List<String> = (settingValue(key) as? JSONArray).strings()

    private fun serverData(s: Server): JSONObject {
        val d = JSONObject().put("name", s.name).put("ipaddr", s.ipaddr).put("tcpport", s.tcpport).put("udpport", s.udpport)
            .put("username", s.username).put("nickname", s.nickname).put("statusmsg", s.statusmsg).put("channel", s.channel)
            .put("encrypted", s.encrypted).put("cacertdata", s.cacertdata).put("certdata", s.certdata)
            .put("certverifypeer", s.certverifypeer).put("sync_password", s.syncPassword)
        // Passwords (and the client certificate's key) only when allowed.
        if (s.syncPassword) {
            d.put("password", s.password).put("chanpasswd", s.chanpasswd).put("certprivkeydata", s.certprivkeydata)
        }
        return d
    }

    private fun fill(s: Server, d: JSONObject) {
        d.optString("name", s.name).let { s.name = it }
        s.ipaddr = d.optString("ipaddr", s.ipaddr)
        s.tcpport = d.optInt("tcpport", s.tcpport)
        s.udpport = d.optInt("udpport", s.udpport)
        s.username = d.optString("username", s.username)
        s.nickname = d.optString("nickname", s.nickname)
        s.statusmsg = d.optString("statusmsg", s.statusmsg)
        s.channel = d.optString("channel", s.channel)
        s.encrypted = d.optBoolean("encrypted", s.encrypted)
        s.cacertdata = d.optString("cacertdata", s.cacertdata)
        s.certdata = d.optString("certdata", s.certdata)
        s.certverifypeer = d.optBoolean("certverifypeer", s.certverifypeer)
        s.syncPassword = d.optBoolean("sync_password", true)
        // Without them (not synced from that phone), keep this phone's.
        if (d.has("password")) s.password = d.str("password")
        if (d.has("chanpasswd")) s.chanpasswd = d.str("chanpasswd")
        if (d.has("certprivkeydata")) s.certprivkeydata = d.str("certprivkeydata")
    }

    private fun sameLogin(s: Server, d: JSONObject) =
        s.ipaddr.equals(d.str("ipaddr"), ignoreCase = true) && s.tcpport == d.optInt("tcpport") && s.username == d.str("username")

    private fun canonical(v: Any?): String = when (v) {
        null, JSONObject.NULL -> "null"
        is JSONObject -> v.keys().asSequence().toList().sorted().joinToString(",", "{", "}") { "${JSONObject.quote(it)}:${canonical(v.opt(it))}" }
        is JSONArray -> (0 until v.length()).joinToString(",", "[", "]") { canonical(v.opt(it)) }
        is String -> JSONObject.quote(v)
        is Number -> if (v.toDouble() == v.toLong().toDouble()) v.toLong().toString() else v.toDouble().toString()
        else -> v.toString()
    }

    /** A stable hash of JSON-able data (null: deleted or unset). */
    private fun hash(value: Any?): String =
        if (value == null || value === JSONObject.NULL) "-" else sha256(canonical(value).toByteArray())
}

fun sha256(data: ByteArray): String =
    MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it) }
