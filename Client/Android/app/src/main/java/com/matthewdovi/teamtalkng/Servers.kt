/*
 * The saved server list, and .tt files and tt:// links.
 */
package com.matthewdovi.teamtalkng

import android.net.Uri
import androidx.compose.runtime.mutableStateListOf
import org.json.JSONArray
import org.json.JSONObject
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserFactory
import java.io.StringReader
import java.util.UUID

const val DEFAULT_TCPPORT = 10333
const val DEFAULT_UDPPORT = 10333

/** Properties of a TeamTalk server to connect to. */
data class Server(
    var name: String = "",
    var ipaddr: String = "",
    var tcpport: Int = DEFAULT_TCPPORT,
    var udpport: Int = DEFAULT_UDPPORT,
    var nickname: String = "",
    var statusmsg: String = "",
    var username: String = "",
    var password: String = "",
    var channel: String = "",
    var chanpasswd: String = "",
    var encrypted: Boolean = false,
    var cacertdata: String = "",
    var certdata: String = "",
    var certprivkeydata: String = "",
    var certverifypeer: Boolean = false,
    /** The same server on every device of the NG Account. */
    var syncID: String = UUID.randomUUID().toString(),
    /** Whether NG Account syncs this server's passwords. */
    var syncPassword: Boolean = true,
) {
    val displayName get() = name.ifEmpty { "Unnamed Server" }

    fun sameAddress(other: Server) =
        ipaddr.trim().equals(other.ipaddr.trim(), ignoreCase = true) &&
            tcpport == other.tcpport && udpport == other.udpport && encrypted == other.encrypted

    fun sameLogin(other: Server) = ipaddr.equals(other.ipaddr, ignoreCase = true) &&
        tcpport == other.tcpport && udpport == other.udpport && encrypted == other.encrypted &&
        username == other.username && password == other.password &&
        cacertdata == other.cacertdata && certdata == other.certdata &&
        certprivkeydata == other.certprivkeydata && certverifypeer == other.certverifypeer

    fun toJson() = JSONObject().apply {
        put("name", name); put("ipaddr", ipaddr); put("tcpport", tcpport); put("udpport", udpport)
        put("nickname", nickname); put("statusmsg", statusmsg); put("username", username); put("password", password)
        put("channel", channel); put("chanpasswd", chanpasswd); put("encrypted", encrypted)
        put("cacertdata", cacertdata); put("certdata", certdata); put("certprivkeydata", certprivkeydata)
        put("certverifypeer", certverifypeer); put("syncid", syncID); put("syncpassword", syncPassword)
    }

    companion object {
        fun fromJson(j: JSONObject) = Server(
            name = j.optString("name"), ipaddr = j.optString("ipaddr"),
            tcpport = j.optInt("tcpport", DEFAULT_TCPPORT), udpport = j.optInt("udpport", DEFAULT_UDPPORT),
            nickname = j.optString("nickname"), statusmsg = j.optString("statusmsg"),
            username = j.optString("username"), password = j.optString("password"),
            channel = j.optString("channel"), chanpasswd = j.optString("chanpasswd"),
            encrypted = j.optBoolean("encrypted"), cacertdata = j.optString("cacertdata"),
            certdata = j.optString("certdata"), certprivkeydata = j.optString("certprivkeydata"),
            certverifypeer = j.optBoolean("certverifypeer"),
            syncID = j.optString("syncid").ifEmpty { UUID.randomUUID().toString() },
            syncPassword = j.optBoolean("syncpassword", true),
        )
    }
}

/** The saved servers. Saved with the secrets' store, as they hold passwords. */
object ServerStore {
    private const val KEY = "ServerList"
    val servers = mutableStateListOf<Server>()
    /** Called after every save (NG Account sync pushes the change). */
    var saved: () -> Unit = {}

    fun load() {
        val text = SecretStore.get(KEY) ?: return
        val list = runCatching { JSONArray(text) }.getOrNull() ?: return
        servers.clear()
        for (i in 0 until list.length()) servers.add(Server.fromJson(list.getJSONObject(i)))
    }

    fun save(list: List<Server>, notify: Boolean = true) {
        if (servers.toList() !== list) {
            val copy = list.toList()
            servers.clear()
            servers.addAll(copy)
        }
        SecretStore.put(KEY, JSONArray().apply { servers.forEach { put(it.toJson()) } }.toString())
        if (notify) saved()
    }

    fun isSaved(server: Server) = servers.any { it.sameLogin(server) }

    /** Saves a server under [name], replacing one of that name (which keeps it the same server in the NG Account). */
    fun saveNamed(server: Server, name: String) {
        servers.firstOrNull { it.name == name }?.let { server.syncID = it.syncID }
        val next = servers.filter { it.name != name } + server.copy(name = name)
        save(next)
    }
}

/** What a .tt file or tt:// link gives. */
object ServerFiles {
    /** The servers in a .tt file; throws when it can't be read. */
    fun parse(xml: String): List<Server> {
        val parser = XmlPullParserFactory.newInstance().newPullParser()
        parser.setInput(StringReader(xml))
        val servers = mutableListOf<Server>()
        var current = Server()
        val stack = ArrayDeque<String>()
        var type = parser.eventType
        while (type != XmlPullParser.END_DOCUMENT) {
            when (type) {
                XmlPullParser.START_TAG -> {
                    stack.addLast(parser.name)
                    if (parser.name == "host") current = Server()
                }
                XmlPullParser.TEXT -> if (stack.isNotEmpty() && !parser.isWhitespace) {
                    val text = parser.text
                    when (stack.last()) {
                        "name" -> current.name = text
                        "address" -> current.ipaddr = text
                        "tcpport" -> current.tcpport = text.trim().toIntOrNull() ?: current.tcpport
                        "udpport" -> current.udpport = text.trim().toIntOrNull() ?: current.udpport
                        "encrypted" -> current.encrypted = text.trim() == "true"
                        "username" -> current.username = text
                        "password" ->
                            if ("auth" in stack) current.password = text else if ("join" in stack) current.chanpasswd = text
                        "nickname" -> current.nickname = text
                        "statusmsg" -> current.statusmsg = text
                        "channel" -> current.channel = text
                        "certificate-authority-pem" -> current.cacertdata += text
                        "client-certificate-pem" -> current.certdata += text
                        "client-private-key-pem" -> current.certprivkeydata += text
                        "verify-peer" -> current.certverifypeer = text.trim() == "true"
                    }
                }
                XmlPullParser.END_TAG -> {
                    stack.removeLastOrNull()
                    if (parser.name == "host") servers.add(current)
                }
            }
            type = parser.next()
        }
        return servers
    }

    fun export(servers: List<Server>): String = buildString {
        fun esc(v: String) = v.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<teamtalk>\n")
        for (s in servers) {
            append("  <host>\n")
            append("    <name>${esc(s.name)}</name>\n")
            append("    <address>${esc(s.ipaddr)}</address>\n")
            append("    <tcpport>${s.tcpport}</tcpport>\n")
            append("    <udpport>${s.udpport}</udpport>\n")
            append("    <encrypted>${s.encrypted}</encrypted>\n")
            append("    <auth>\n")
            append("      <username>${esc(s.username)}</username>\n")
            append("      <password>${esc(s.password)}</password>\n")
            append("      <nickname>${esc(s.nickname)}</nickname>\n")
            append("      <statusmsg>${esc(s.statusmsg)}</statusmsg>\n")
            append("    </auth>\n")
            append("    <join>\n")
            append("      <channel>${esc(s.channel)}</channel>\n")
            append("      <password>${esc(s.chanpasswd)}</password>\n")
            append("    </join>\n")
            append("  </host>\n")
        }
        append("</teamtalk>\n")
    }
}

/** A tt:// link: the server, and what to show about it before connecting. */
class ServerLink(val server: Server, val details: List<Pair<String, String>>) {
    companion object {
        fun parse(uri: Uri): ServerLink? {
            val host = uri.host?.takeIf { it.isNotEmpty() } ?: return null
            val items = uri.queryParameterNames.associate { it.lowercase() to (uri.getQueryParameter(it) ?: "") }
            val server = Server(ipaddr = host)
            items["tcpport"]?.toIntOrNull()?.let { server.tcpport = it }
            items["udpport"]?.toIntOrNull()?.let { server.udpport = it }
            val encrypted = items["encrypted"]?.let { it.equals("true", true) || it == "1" }
            encrypted?.let { server.encrypted = it }
            items["username"]?.let { server.username = it }
            items["password"]?.let { server.password = it }
            items["nickname"]?.let { server.nickname = it }
            items["channel"]?.let { server.channel = it }
            items["chanpasswd"]?.let { server.chanpasswd = it }
            val details = buildList {
                add("Host" to host)
                items["tcpport"]?.let { add("TCP Port" to it) }
                items["udpport"]?.let { add("UDP Port" to it) }
                encrypted?.let { add("Encrypted" to if (it) "Yes" else "No") }
                items["username"]?.let { add("Username" to it) }
                items["password"]?.let { add("Password" to it) }
                items["channel"]?.let { add("Channel" to it) }
            }
            return ServerLink(server, details)
        }
    }
}
