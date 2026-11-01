/*
 * Sound packs and the NG Account: packs made here are backed up privately and
 * come back on a new phone; deleting one deletes it everywhere. Packs from the
 * catalog aren't uploaded: which are installed, and which pack is chosen, sync
 * as settings, and a new phone downloads them again.
 */
package com.matthewdovi.teamtalkng

import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.compose.runtime.snapshotFlow
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File

private const val TAG = "NGPackSync"

object NGPackSync {
    private val INSTALLED_KEY = NGSync.packKeys[0]
    private val SELECTED_KEY = NGSync.packKeys[1]

    private class BackedUp(val packID: String, val files: Map<String, String>, val name: String)

    private class State(val email: String) {
        val packs = HashMap<String, BackedUp>()
        var catalog = HashMap<String, BackedUp>()
    }

    var ownedCatalogPacks: Map<String, NGPack> = emptyMap()
        private set
    private val accountPacks = HashMap<String, NGPack>()

    fun accountPack(localID: String): NGPack? =
        if (enabled && loadState()?.packs?.containsKey(localID) == true) accountPacks[localID] else null

    fun owns(catalogID: String?) = catalogID != null && ownedCatalogPacks.containsKey(catalogID)

    private var running = false
    private var again = false
    private var applying = 0
    private val main = Handler(Looper.getMainLooper())
    private val pending = Runnable { appScope.launch { syncNow() } }
    private val stateFile get() = File(TeamTalkApp.context.filesDir, "NGPackSync.json")

    val enabled get() = NGAccountCenter.isSignedIn && NGAccountCenter.isSyncing(NGAccountCenter.Category.SoundPacks)

    fun start() {
        appScope.launch {
            snapshotFlow { SoundPackStore.revision.intValue }.collect {
                if (applying == 0) {
                    noteSelection()
                    syncSoon(2000)
                }
            }
        }
    }

    fun syncSoon(delay: Long = 500) {
        if (!enabled) return
        main.removeCallbacks(pending)
        main.postDelayed(pending, delay)
    }

    fun signedOut() {
        main.removeCallbacks(pending)
        stateFile.delete()
    }

    fun removeLocalCopy() {
        val backedUp = loadState()?.packs?.keys.orEmpty()
        applying++
        SoundPackStore.customPacks.filter { it.id in backedUp || it.catalogID != null }.forEach {
            runCatching { SoundPackStore.deletePack(it.id) }
        }
        applying--
    }

    private fun parse(j: JSONObject): BackedUp {
        val files = j.getJSONObject("files")
        return BackedUp(j.str("packID"), files.keys().asSequence().associateWith { files.str(it) }, j.str("name"))
    }

    private fun json(b: BackedUp) = JSONObject().put("packID", b.packID).put("files", JSONObject(b.files)).put("name", b.name)

    private fun loadState(): State? = runCatching {
        val j = JSONObject(stateFile.readText())
        State(j.str("email")).apply {
            val p = j.getJSONObject("packs")
            p.keys().forEach { packs[it] = parse(p.getJSONObject(it)) }
            j.optJSONObject("catalog")?.let { c -> c.keys().forEach { catalog[it] = parse(c.getJSONObject(it)) } }
        }
    }.getOrNull()

    private fun saveState(s: State) {
        val packs = JSONObject()
        s.packs.forEach { (k, v) -> packs.put(k, json(v)) }
        val catalog = JSONObject()
        s.catalog.forEach { (k, v) -> catalog.put(k, json(v)) }
        stateFile.writeText(JSONObject().put("email", s.email).put("packs", packs).put("catalog", catalog).toString())
    }

    /** Writes which catalog packs are installed and which pack is chosen where settings sync picks them up. */
    private fun noteSelection() {
        val catalog = SoundPackStore.customPacks.mapNotNull { it.catalogID }.sorted()
        if (NGSync.getStrings(INSTALLED_KEY) != catalog) NGSync.setStrings(INSTALLED_KEY, catalog)
        val pack = SoundPackStore.selectedPack
        val selected = when {
            pack.isDefault -> "default"
            pack.catalogID != null -> "catalog:" + pack.catalogID
            else -> loadState()?.packs?.get(pack.id)?.let { "account:" + it.packID } ?: ("local:" + pack.id)
        }
        if (Prefs.string(SELECTED_KEY) != selected) Prefs.set(SELECTED_KEY, selected)
    }

    suspend fun syncNow() {
        if (!enabled) return
        val email = NGAccountCenter.email ?: return
        if (running) {
            again = true
            return
        }
        running = true
        try {
            do {
                again = false
                backUpAndRestore(email)
                installCatalogPacks()
                applySelection()
            } while (again)
        } catch (_: NGAccountException.SignedOut) {
        } catch (e: Exception) {
            Log.w(TAG, "NG Account sound pack sync failed: ${e.message}")
        } finally {
            running = false
        }
    }

    private suspend fun backUpAndRestore(email: String) {
        val s = loadState()?.takeIf { it.email == email } ?: State(email)
        val store = SoundPackStore
        val remote = NGAccountCenter.signed { it.packs() }.packs
        val byLocal = remote.associateBy { it.localId }
        val mine = store.customPacks.filter { it.catalogID == null }
        val owned = remote.associateBy { it.id }
        val ownedNow = HashMap<String, NGPack>()
        store.customPacks.forEach { p -> p.catalogID?.let { c -> owned[c]?.let { ownedNow[c] = it } } }
        ownedCatalogPacks = ownedNow

        // Deleted on another device: delete here too.
        for ((localID, backed) in s.packs.toMap()) {
            if (remote.none { it.id == backed.packID }) {
                if (store.pack(localID) != null) quietly { store.deletePack(localID) }
                s.packs.remove(localID)
            }
        }
        // Deleted here: delete from the account.
        for (p in remote) {
            if (s.packs.containsKey(p.localId) && store.pack(p.localId) == null) {
                NGAccountCenter.signed { it.deletePack(p.id) }
                s.packs.remove(p.localId)
            }
        }
        saveState(s)

        // This phone's packs and the account's copies, kept the same.
        for (pack in mine) {
            var account = byLocal[pack.id] ?: NGAccountCenter.signed { it.backupPack(pack.id, pack.name) }
            val base = s.packs[pack.id]
            var name = pack.name
            if (base != null && base.name == pack.name && account.name != pack.name) {
                // Renamed on another device.
                quietly { store.renamePack(pack.id, account.name) }
                name = account.name
            } else if (account.name != pack.name) {
                val id = account.id
                account = NGAccountCenter.signed { it.changePack(id, name = pack.name) }
            }
            val (synced, files) = reconcile(pack.id, account, base?.files)
            s.packs[pack.id] = BackedUp(synced.id, files, name)
            accountPacks[pack.id] = synced
            saveState(s)
        }

        // Catalog packs this account owns: sounds changed here are published as a new version.
        for (pack in store.customPacks) {
            val catalogID = pack.catalogID ?: continue
            val account = ownedNow[catalogID] ?: continue
            val base = s.catalog[catalogID]?.files
                ?: if (pack.version == account.version) account.files.associate { it.name to it.hash } else localHashes(pack.id)
            val (synced, files) = reconcile(pack.id, account, base)
            ownedNow[catalogID] = synced
            s.catalog[catalogID] = BackedUp(synced.id, files, synced.name)
            if (pack.version != synced.version) quietly { store.setVersion(synced.version, pack.id) }
        }
        saveState(s)

        // The account's packs this phone doesn't have: restore them. Not Official
        // ones or ones from the catalog: those install from the catalog.
        for (p in remote) {
            if (store.pack(p.localId) != null || s.packs.containsKey(p.localId) || p.files.isEmpty() || p.official || store.installedPack(p.id) != null) continue
            val zip = NGAccountCenter.signed { it.packZip(p.id) }
            quietly { store.restoreArchive(zip.inputStream(), p.localId, p.name) }
            s.packs[p.localId] = BackedUp(p.id, p.files.associate { it.name to it.hash }, p.name)
            accountPacks[p.localId] = p
            saveState(s)
        }
    }

    private inline fun quietly(work: () -> Unit) {
        applying++
        try {
            runCatching { work() }
        } finally {
            applying--
        }
    }

    private suspend fun localHashes(packID: String): Map<String, String> = withContext(Dispatchers.IO) {
        SoundPackStore.customSoundFiles(packID).associate { (name, file) -> name to sha256(file.readBytes()) }
    }

    /**
     * Makes one of this phone's packs and the account's copy the same, sound by
     * sound. Against [base]: a sound changed here goes up, one changed in the
     * account comes down, and with no base this phone's sounds win.
     */
    private suspend fun reconcile(packID: String, account: NGPack, base: Map<String, String>?): Pair<NGPack, Map<String, String>> {
        var a = account
        val local = SoundPackStore.customSoundFiles(packID).toMap()
        val localHash = localHashes(packID)
        val remote = a.files.associate { it.name to it.hash }
        fun stem(n: String) = n.substringBeforeLast('.')
        val sounds = (localHash.keys + remote.keys + base.orEmpty().keys).map(::stem).toSet()
        fun file(m: Map<String, String>?, sound: String) = m?.entries?.firstOrNull { stem(it.key) == sound }
        val now = HashMap<String, String>()
        for (sound in sounds) {
            val l = file(localHash, sound)
            val r = file(remote, sound)
            val b = file(base, sound)
            if (l?.value == r?.value) {
                l?.let { now[it.key] = it.value }
                continue
            }
            val changedHere = base == null || l?.value != b?.value
            if (changedHere) {
                val data = l?.let { local[it.key]?.readBytes() }
                if (l != null && data != null) {
                    try {
                        val id = a.id
                        a = NGAccountCenter.signed { it.uploadSound(id, l.key, data) }
                        now[l.key] = l.value
                    } catch (e: NGAccountException.Refused) {
                        // This one sound: left out of what's synced, so it's tried again.
                        Log.w(TAG, "${l.key} was not backed up: ${e.message}")
                        b?.let { now[it.key] = it.value }
                    }
                } else if (r != null) {
                    val id = a.id
                    a = NGAccountCenter.signed { it.removeSound(id, r.key) }
                }
            } else if (r != null) {
                val id = a.id
                val bytes = NGAccountCenter.signed { it.downloadSound(id, r.key) }
                quietly { SoundPackStore.writeSound(bytes, r.key, packID) }
                now[r.key] = r.value
            } else if (l != null) {
                quietly { SoundPackStore.removeSound(l.key, packID) }
            }
        }
        return a to now
    }

    private suspend fun installCatalogPacks() {
        val missing = NGSync.getStrings(INSTALLED_KEY).filter { SoundPackStore.installedPack(it) == null }
        if (missing.isEmpty()) return
        val catalog = runCatching { SoundCatalog.catalog() }.getOrNull() ?: return
        for (pack in catalog) {
            if (pack.id !in missing) continue
            val archive = runCatching { SoundCatalog.download(pack) }.getOrNull() ?: continue
            quietly { SoundPackStore.importCatalogArchive(archive.inputStream(), pack, selectAfter = false) }
        }
    }

    private fun applySelection() {
        val selected = Prefs.string(SELECTED_KEY).ifEmpty { return }
        val target = when {
            selected == "default" -> SoundPackStore.DEFAULT_ID
            selected.startsWith("catalog:") -> SoundPackStore.installedPack(selected.removePrefix("catalog:"))?.id
            selected.startsWith("account:") -> {
                val id = selected.removePrefix("account:")
                loadState()?.packs?.entries?.firstOrNull { it.value.packID == id }?.key
            }
            selected.startsWith("local:") -> SoundPackStore.pack(selected.removePrefix("local:"))?.id
            else -> null
        }
        if (target != null && target != SoundPackStore.selectedPackID) quietly { SoundPackStore.selectPack(target) }
    }
}

/** The catalog of published sound packs (Official ones first). */
object SoundCatalog {
    suspend fun catalog(): List<RemoteSoundPack> = NGAccountAPI(null).catalog().map {
        RemoteSoundPack(it.id, it.name, it.author, it.description.ifEmpty { null }, it.version,
            MonitorService.baseURL.trimEnd('/') + "/" + it.downloadPath.trimStart('/'), it.official)
    }

    suspend fun download(pack: RemoteSoundPack): ByteArray {
        val reply = ServiceHttp.send("GET", pack.downloadURL, null)
        if (!reply.ok) throw SoundPackException("Catalog request failed with status ${reply.status}.")
        return reply.body
    }
}
