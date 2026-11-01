/*
 * NG Account on this phone: signing in and out, which of servers, settings and
 * sound packs sync, and the account's part of the service. Monitors need it;
 * servers and settings can stay on the phone without one.
 */
package com.matthewdovi.teamtalkng

import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.mutableIntStateOf
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.net.URLEncoder
import java.util.UUID

sealed class NGAccountException(message: String) : Exception(message) {
    class Refused(message: String) : NGAccountException(message)
    class SignedOut : NGAccountException("You're signed out of your NG Account. Sign in again.")
    class Unreachable(detail: String) : NGAccountException("Could not reach TeamTalk NG's service: $detail")
}

data class NGAccountInfo(val id: Int, val email: String, val created: Long)

class NGSignedIn(val token: String, val sessionId: Int, val account: NGAccountInfo, val deviceId: Int, val pushKey: String)

data class NGSession(val id: Int, val installId: String, val name: String, val created: Long, val lastSeen: Long, val current: Boolean)

data class NGPackFile(val name: String, val hash: String, val size: Long)

data class NGPack(
    val id: String, val localId: String, val name: String, val author: String, val description: String,
    val public: Boolean, val official: Boolean, val hidden: Boolean, val version: String, val size: Long, val files: List<NGPackFile>,
) {
    companion object {
        fun parse(j: JSONObject) = NGPack(
            j.str("id"), j.str("local_id"), j.str("name"), j.str("author"), j.str("description"), j.optBoolean("public"),
            j.optBoolean("official"), j.optBoolean("hidden"), j.str("version"), j.optLong("size"),
            j.optJSONArray("files").mapObjects { NGPackFile(it.str("name"), it.str("hash"), it.optLong("size")) },
        )
    }
}

class NGPackList(val packs: List<NGPack>, val usedBytes: Long, val limitBytes: Long)

class NGCatalogPack(
    val id: String, val name: String, val author: String, val description: String, val version: String,
    val official: Boolean, val installs: Int, val size: Long, val downloadPath: String,
)

class NGSyncRecord(val kind: String, val key: String, val rev: Long, val deleted: Boolean, val data: Any?) {
    companion object {
        fun parse(j: JSONObject): NGSyncRecord? {
            val kind = j.optString("kind").ifEmpty { return null }
            val key = j.optString("key").ifEmpty { return null }
            return NGSyncRecord(kind, key, j.optLong("rev"), j.optBoolean("deleted"), j.opt("data").takeUnless { it === JSONObject.NULL })
        }
    }
}

class NGSyncChange(val kind: String, val key: String, var baseRev: Long, val deleted: Boolean, val data: Any?) {
    val json: JSONObject
        get() = JSONObject().put("kind", kind).put("key", key).put("base_rev", baseRev).put("deleted", deleted).also {
            if (data != null && !deleted) it.put("data", data)
        }
}

class NGSyncResult(val rev: Long, val applied: List<NGSyncRecord>, val conflicts: List<NGSyncRecord>)

class NGInstall {
    fun fields(): JSONObject = JSONObject().put("install_id", MonitorInstall.id).put("device_name", MonitorInstall.deviceName)
}

class NGAccountAPI(private val token: String?) {
    private suspend fun send(method: String, path: String, json: Any? = null, data: ByteArray? = null): ByteArray {
        val reply = try {
            ServiceHttp.send(method, "${MonitorService.baseURL}/$path", token, json, data)
        } catch (e: IOException) {
            throw NGAccountException.Unreachable(e.message ?: "no response")
        }
        if (reply.ok) return reply.body
        if (reply.status == 401 && token != null) throw NGAccountException.SignedOut()
        throw NGAccountException.Refused(reply.error ?: "HTTP ${reply.status}")
    }

    private suspend fun obj(method: String, path: String, json: Any? = null) = JSONObject(String(send(method, path, json)))

    private fun signedIn(j: JSONObject): NGSignedIn {
        val a = j.getJSONObject("account")
        return NGSignedIn(j.str("token"), j.optInt("session_id"), NGAccountInfo(a.optInt("id"), a.str("email"), a.optLong("created")), j.optInt("device_id"), j.str("push_key"))
    }

    suspend fun signUp(email: String, password: String) { send("POST", "v1/account/signup", JSONObject().put("email", email).put("password", password)) }
    suspend fun verify(email: String, code: String, install: NGInstall) =
        signedIn(obj("POST", "v1/account/verify", install.fields().put("email", email).put("code", code)))
    suspend fun signIn(email: String, password: String, install: NGInstall) =
        signedIn(obj("POST", "v1/account/signin", install.fields().put("email", email).put("password", password)))
    suspend fun forgotPassword(email: String) { send("POST", "v1/account/forgot", JSONObject().put("email", email)) }
    suspend fun resetPassword(email: String, code: String, password: String, install: NGInstall) =
        signedIn(obj("POST", "v1/account/reset", install.fields().put("email", email).put("code", code).put("password", password)))

    class AccountState(val account: NGAccountInfo, val sessionId: Int, val deviceId: Int, val syncRev: Long, val usedBytes: Long, val limitBytes: Long)

    suspend fun account(): AccountState {
        val j = obj("GET", "v1/account")
        val a = j.getJSONObject("account")
        val p = j.optJSONObject("packs") ?: JSONObject()
        return AccountState(NGAccountInfo(a.optInt("id"), a.str("email"), a.optLong("created")), j.optInt("session_id"), j.optInt("device_id"), j.optLong("sync_rev"), p.optLong("used_bytes"), p.optLong("limit_bytes"))
    }

    suspend fun changePassword(current: String, new: String) { send("POST", "v1/account/password", JSONObject().put("current", current).put("new", new)) }
    suspend fun signOut() { send("POST", "v1/account/signout") }
    suspend fun deleteAccount(password: String) { send("POST", "v1/account/delete", JSONObject().put("password", password)) }
    suspend fun sessions() = obj("GET", "v1/account/sessions").optJSONArray("sessions").mapObjects {
        NGSession(it.optInt("id"), it.str("install_id"), it.str("name"), it.optLong("created"), it.optLong("last_seen"), it.optBoolean("current"))
    }
    suspend fun endSession(id: Int) { send("DELETE", "v1/account/sessions/$id") }
    suspend fun export() = send("GET", "v1/account/export")

    class Pulled(val rev: Long, val reset: Boolean, val records: List<NGSyncRecord>)

    suspend fun pull(since: Long): Pulled {
        val j = obj("GET", "v1/sync?since=$since")
        return Pulled(j.optLong("rev"), j.optBoolean("reset"), j.optJSONArray("records").mapObjects { it }.mapNotNull(NGSyncRecord::parse))
    }

    suspend fun push(changes: List<NGSyncChange>): NGSyncResult {
        val j = obj("POST", "v1/sync", JSONObject().put("changes", JSONArray(changes.map { it.json })))
        return NGSyncResult(j.optLong("rev"), j.optJSONArray("applied").mapObjects { it }.mapNotNull(NGSyncRecord::parse),
            j.optJSONArray("conflicts").mapObjects { it }.mapNotNull(NGSyncRecord::parse))
    }

    suspend fun packs(): NGPackList {
        val j = obj("GET", "v1/packs")
        return NGPackList(j.optJSONArray("packs").mapObjects(NGPack::parse), j.optLong("used_bytes"), j.optLong("limit_bytes"))
    }

    suspend fun backupPack(localID: String, name: String) =
        NGPack.parse(obj("POST", "v1/packs", JSONObject().put("local_id", localID).put("name", name)))

    suspend fun changePack(id: String, name: String? = null, author: String? = null, description: String? = null, public: Boolean? = null): NGPack {
        val body = JSONObject()
        name?.let { body.put("name", it) }
        author?.let { body.put("author", it) }
        description?.let { body.put("description", it) }
        public?.let { body.put("public", it) }
        return NGPack.parse(obj("PATCH", "v1/packs/$id", body))
    }

    suspend fun deletePack(id: String) { send("DELETE", "v1/packs/$id") }
    suspend fun uploadSound(pack: String, name: String, data: ByteArray) =
        NGPack.parse(JSONObject(String(send("PUT", "v1/packs/$pack/files/$name", data = data))))
    suspend fun downloadSound(pack: String, name: String) = send("GET", "v1/packs/$pack/files/$name")
    suspend fun removeSound(pack: String, name: String) = NGPack.parse(obj("DELETE", "v1/packs/$pack/files/$name"))
    suspend fun packZip(id: String) = send("GET", "v1/packs/$id/pack.zip")

    suspend fun catalog(query: String = "", popular: Boolean = false): List<NGCatalogPack> {
        val q = buildList {
            if (query.isNotEmpty()) add("q=" + URLEncoder.encode(query, "UTF-8"))
            if (popular) add("sort=popular")
        }.joinToString("&")
        return obj("GET", "v1/catalog" + if (q.isEmpty()) "" else "?$q").optJSONArray("packs").mapObjects {
            NGCatalogPack(it.str("id"), it.str("name"), it.str("author"), it.str("description"), it.str("version"),
                it.optBoolean("official"), it.optInt("installs"), it.optLong("size"), it.str("download_path"))
        }
    }

    suspend fun countInstall(id: String) { runCatching { send("POST", "v1/catalog/$id/installed") } }
    suspend fun report(id: String, reason: String) { send("POST", "v1/catalog/$id/report", JSONObject().put("reason", reason)) }
}

object NGAccountCenter {
    enum class Category(val key: String, val title: String) {
        Servers("servers", "Servers"), Settings("settings", "Settings"), SoundPacks("soundPacks", "Sound Packs")
    }

    /** Goes up on signing in or out, or when the account changes. */
    val revision = mutableIntStateOf(0)

    /**
     * Asks, on signing in to an account that has servers and settings from a
     * phone with its own, whose to keep: true for this phone's. Set by the sign-in screen.
     */
    var askWhoseData: (suspend () -> Boolean)? = null

    val signIn: MonitorAccount? get() = MonitorAccountStore.ngAccount?.takeIf { it.baseURL == MonitorService.baseURL }
    val isSignedIn get() = signIn != null
    val email get() = signIn?.email
    val api get() = NGAccountAPI(signIn?.token)
    private val anonymous get() = NGAccountAPI(null)

    fun isSyncing(c: Category) = MonitorInstall.defaults.getBoolean("NGSync." + c.key, true)

    fun setSyncing(c: Category, on: Boolean) {
        MonitorInstall.defaults.edit().putBoolean("NGSync." + c.key, on).apply()
        if (on) when (c) {
            Category.Servers, Category.Settings -> NGSync.turnedOn(c)
            Category.SoundPacks -> { NGPackSync.syncSoon(); NGSync.syncSoon() }
        }
        revision.intValue++
    }

    private fun install() = NGInstall()

    suspend fun signUp(email: String, password: String) = anonymous.signUp(email, password)
    suspend fun verify(email: String, code: String) = signedIn(anonymous.verify(email, code, install()), true)
    suspend fun signIn(email: String, password: String) = signedIn(anonymous.signIn(email, password, install()), false)
    suspend fun forgotPassword(email: String) = anonymous.forgotPassword(email)
    suspend fun resetPassword(email: String, code: String, password: String) =
        signedIn(anonymous.resetPassword(email, code, password, install()), false)

    private suspend fun signedIn(r: NGSignedIn, firstTime: Boolean) {
        val account = MonitorAccount(UUID.randomUUID().toString(), "TeamTalk NG", MonitorService.baseURL, r.token, r.pushKey, r.deviceId, r.account.email)
        // No syncing until whose servers and settings to keep is decided.
        NGSync.holdForSignIn()
        MonitorAccountStore.save(account)
        MonitorCenter.reload()
        MonitorNotifications.register()
        var keepThisPhone = false
        val ask = askWhoseData
        if (!firstTime && NGSync.phoneHasData && ask != null) {
            val pulled = runCatching { api.pull(0) }.getOrNull()
            if (pulled != null && pulled.rev > 0 && NGSync.differs(pulled.records)) keepThisPhone = ask()
        }
        NGSync.signedIn(keepThisPhone)
        NGPackSync.syncSoon()
        revision.intValue++
        announce("Signed in as ${r.account.email}")
    }

    /** Signs this phone out. [removeLocalCopy] also removes the servers and sound packs that came from the account. */
    suspend fun signOut(removeLocalCopy: Boolean) {
        val api = api
        runCatching { api.signOut() }
        forget(removeLocalCopy)
    }

    suspend fun deleteAccount(password: String) {
        api.deleteAccount(password)
        forget(false)
    }

    /** The service no longer knows this sign-in. */
    fun sessionEnded() {
        if (isSignedIn) forget(false)
    }

    private fun forget(removeLocalCopy: Boolean) {
        signIn?.let { MonitorAccountStore.remove(it.ref) }
        if (removeLocalCopy) {
            NGSync.removeLocalCopy()
            NGPackSync.removeLocalCopy()
        }
        NGSync.signedOut()
        NGPackSync.signedOut()
        MonitorCenter.reload()
        revision.intValue++
    }

    /** Runs a signed-in request; a sign-in that ended signs this phone out. */
    suspend fun <T> signed(work: suspend (NGAccountAPI) -> T): T = try {
        work(api)
    } catch (e: NGAccountException.SignedOut) {
        sessionEnded()
        throw e
    }

    /** Another device changed something: pull it now. */
    fun remoteChange() {
        Handler(Looper.getMainLooper()).post {
            NGSync.syncSoon()
            NGPackSync.syncSoon()
            revision.intValue++
        }
    }
}
