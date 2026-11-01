/*
 * Notifications from TeamTalk NG Monitors. Pushes come through Firebase Cloud
 * Messaging as data messages (sealed, so Google sees no text); the app opens
 * them and shows the notification, with Reply and Mute for 1 Hour.
 */
package com.matthewdovi.teamtalkng

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.RemoteInput
import androidx.core.content.ContextCompat
import androidx.core.content.getSystemService
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import kotlinx.coroutines.launch
import org.json.JSONObject
import kotlin.math.abs

const val CHANNEL_MONITOR = "monitor"
const val CHANNEL_MONITOR_SILENT = "monitor_silent"
const val EXTRA_MONITOR_REF = "monitor_ref"
const val EXTRA_MONITOR_DATA = "monitor_data"

/** The sound of monitor notifications, as chosen in Notification Settings. */
object MonitorNotificationSounds {
    enum class Choice(val key: String, val title: String) {
        SoundPack("soundPack", "Sound Pack"), System("system", "Phone's Notification Sound"), None("none", "None")
    }

    var choice: Choice
        get() = Choice.entries.firstOrNull { it.key == MonitorInstall.defaults.getString("MonitorNotificationSound", null) } ?: Choice.SoundPack
        set(value) { MonitorInstall.defaults.edit().putString("MonitorNotificationSound", value.key).apply() }

    private val events = mapOf(
        "logged_on" to Sounds.LoggedIn, "logged_off" to Sounds.LoggedOut, "user_msg" to Sounds.UserMsg,
        "channel_msg" to Sounds.ChanMsg, "broadcast_msg" to Sounds.BroadcastMsg, "serverlost" to Sounds.SrvLost,
    )

    /** The iPhone app prepares sound files here; Android plays the pack's directly. */
    fun refresh() {}

    /** Plays the pack's sound for a notification, when the phone isn't silenced. */
    fun playFor(context: Context, serviceSound: String?) {
        if (choice != Choice.SoundPack) return
        val sound = events[serviceSound?.substringBeforeLast('.')] ?: return
        val manager = context.getSystemService<NotificationManager>() ?: return
        val audio = context.getSystemService<AudioManager>() ?: return
        if (manager.currentInterruptionFilter > NotificationManager.INTERRUPTION_FILTER_ALL) return
        if (audio.ringerMode != AudioManager.RINGER_MODE_NORMAL) return
        playSound(sound)
    }
}

object MonitorNotifications {
    /** Shows whatever was tapped. */
    var openHandler: ((ref: String, serverID: Int, chat: MonitorPrivateChat?) -> Unit)? = null
    /** The monitored server on screen, whose notifications are not needed. */
    var visibleServer: Pair<String, Int>? = null

    private const val TOKEN_KEY = "MonitorFCMToken"

    fun createChannels(context: Context) {
        val manager = context.getSystemService<NotificationManager>() ?: return
        manager.createNotificationChannel(NotificationChannel(CHANNEL_MONITOR, "Monitors", NotificationManager.IMPORTANCE_HIGH))
        // The sound pack's sounds are played by the app itself; a channel's sound is fixed once made.
        manager.createNotificationChannel(NotificationChannel(CHANNEL_MONITOR_SILENT, "Monitors (sound pack)", NotificationManager.IMPORTANCE_HIGH).apply {
            setSound(null, null)
        })
    }

    private val hasFirebase get() = FirebaseApp.getApps(TeamTalkApp.context).isNotEmpty()

    /** Registers this phone for pushes, if Firebase is set up in this build. */
    fun register() {
        if (MonitorAccountStore.all().isEmpty() || !hasFirebase) return
        FirebaseMessaging.getInstance().token.addOnSuccessListener { didRegister(it) }
    }

    fun didRegister(token: String) {
        MonitorInstall.defaults.edit().putString(TOKEN_KEY, token).apply()
        // Signed in to NG Account: only its sign-in gets this phone's pushes.
        val accounts = NGAccountCenter.signIn?.let { listOf(it) } ?: MonitorAccountStore.all()
        accounts.forEach { account ->
            appScope.launch { runCatching { MonitorAPI(account).registerPush(token) } }
        }
    }

    /** Shows a monitor's notification. */
    fun show(context: Context, ref: String, content: JSONObject) {
        val data = content.optJSONObject("data") ?: JSONObject()
        val serverID = data.optInt("server_id")
        val visible = visibleServer
        if (visible != null && visible.first == ref && visible.second == serverID) return
        if (MonitorCenter.isLive(ref, serverID)) return

        val category = content.str("category")
        val choice = MonitorNotificationSounds.choice
        val channel = if (choice == MonitorNotificationSounds.Choice.System) CHANNEL_MONITOR else CHANNEL_MONITOR_SILENT
        val id = abs((ref + content.str("thread") + content.str("title") + System.currentTimeMillis()).hashCode())
        val dataText = data.toString()

        val open = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(EXTRA_MONITOR_REF, ref)
            putExtra(EXTRA_MONITOR_DATA, dataText)
        }
        val pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val builder = NotificationCompat.Builder(context, channel)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(content.str("title"))
            .setSubText(content.str("subtitle").ifEmpty { null })
            .setContentText(content.str("body"))
            .setStyle(NotificationCompat.BigTextStyle().bigText(content.str("body")))
            .setGroup(content.str("thread").ifEmpty { null })
            .setAutoCancel(true)
            .setContentIntent(PendingIntent.getActivity(context, id, open, pendingFlags))

        fun action(name: String) = Intent(context, MonitorActionReceiver::class.java).apply {
            action = name
            putExtra(EXTRA_MONITOR_REF, ref)
            putExtra(EXTRA_MONITOR_DATA, dataText)
            putExtra(MonitorActionReceiver.NOTIFICATION_ID, id)
        }
        if (category == "TTNG_PRIVATE_MESSAGE" || category == "TTNG_CHANNEL_MESSAGE") {
            val input = RemoteInput.Builder(MonitorActionReceiver.REPLY_TEXT).setLabel("Message").build()
            val reply = PendingIntent.getBroadcast(context, id, action(MonitorActionReceiver.REPLY),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
            builder.addAction(NotificationCompat.Action.Builder(R.drawable.ic_notification, "Reply", reply).addRemoteInput(input).build())
        }
        val mute = PendingIntent.getBroadcast(context, id + 1, action(MonitorActionReceiver.MUTE), pendingFlags)
        builder.addAction(R.drawable.ic_notification, "Mute for 1 Hour", mute)

        if (ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
            NotificationManagerCompat.from(context).notify(id, builder.build())
            MonitorNotificationSounds.playFor(context, content.str("sound"))
        }
    }

    fun reportFailure(context: Context, text: String) {
        val n: Notification = NotificationCompat.Builder(context, CHANNEL_MONITOR)
            .setSmallIcon(R.drawable.ic_notification).setContentTitle("TeamTalk NG").setContentText(text).build()
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
            NotificationManagerCompat.from(context).notify(abs(text.hashCode()), n)
        }
    }

    /** The screen a tapped notification opens. */
    fun open(ref: String, dataText: String) {
        val data = runCatching { JSONObject(dataText) }.getOrNull() ?: return
        val chat = if (data.str("event") == "private_message" && data.has("user_id")) {
            MonitorPrivateChat(data.optInt("user_id"), data.intOrNull("conversation_id"), data.str("nickname"))
        } else null
        openHandler?.invoke(ref, data.optInt("server_id"), chat)
    }
}

class MonitorActionReceiver : BroadcastReceiver() {
    companion object {
        const val REPLY = "com.matthewdovi.teamtalkng.REPLY"
        const val MUTE = "com.matthewdovi.teamtalkng.MUTE"
        const val REPLY_TEXT = "reply_text"
        const val NOTIFICATION_ID = "notification_id"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val ref = intent.getStringExtra(EXTRA_MONITOR_REF) ?: return
        val data = runCatching { JSONObject(intent.getStringExtra(EXTRA_MONITOR_DATA).orEmpty()) }.getOrNull() ?: return
        val account = MonitorAccountStore.account(ref) ?: return
        val api = MonitorAPI(account)
        val serverID = data.optInt("server_id")
        val manager = NotificationManagerCompat.from(context)
        val id = intent.getIntExtra(NOTIFICATION_ID, 0)
        // Sending must finish before the system stops the app.
        val pending = goAsync()
        appScope.launch {
            try {
                when (intent.action) {
                    REPLY -> {
                        val text = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(REPLY_TEXT)?.toString()?.trim().orEmpty()
                        if (text.isNotEmpty()) try {
                            if (data.str("event") == "channel_message") {
                                api.sendChannelMessage(serverID, data.intOrNull("channel_id"), text)
                            } else if (data.has("user_id")) {
                                // Only to the same person: the conversation ends if they logged out since.
                                val conversation = data.intOrNull("conversation_id")
                                api.sendPrivateMessage(serverID, data.optInt("user_id"), conversation, text)
                                conversation?.let { runCatching { api.markRead(serverID, it) } }
                            }
                        } catch (e: Exception) {
                            MonitorNotifications.reportFailure(context, "Your reply was not sent: ${e.message}")
                        }
                    }
                    MUTE -> runCatching {
                        val prefs = api.prefs()
                        prefs.mutedUntil = System.currentTimeMillis() + 3_600_000
                        api.setPrefs(prefs)
                    }
                }
                manager.cancel(id)
            } finally {
                pending.finish()
            }
        }
    }
}

class PushService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        MonitorNotifications.didRegister(token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val text = message.data["ttng"] ?: return
        val ttng = runCatching { JSONObject(text) }.getOrNull() ?: return
        // Silent: another device changed the account's synced data.
        if (ttng.has("sync")) {
            NGAccountCenter.remoteChange()
            return
        }
        val (ref, content) = MonitorPush.content(ttng) ?: return
        MonitorNotifications.show(this, ref, content)
        keepAlive(ref)
    }

    /** Once a day tells the service this phone still has the app, even if it's only used through notifications. */
    private fun keepAlive(ref: String) {
        val defaults = MonitorInstall.defaults
        val last = defaults.getLong("MonitorLastKeepAlive", 0)
        if (System.currentTimeMillis() - last < 24 * 3600 * 1000L) return
        val account = MonitorAccountStore.account(ref) ?: return
        appScope.launch {
            val reply = runCatching { ServiceHttp.send("GET", "${account.baseURL}/v1/me", account.token) }.getOrNull()
            if (reply?.status == 200) defaults.edit().putLong("MonitorLastKeepAlive", System.currentTimeMillis()).apply()
        }
    }
}
