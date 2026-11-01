/*
 * Keeps connected servers alive with the screen off, as the iPhone app's
 * background audio does: a foreground service with the notification Android
 * requires, a wake lock, and Wi-Fi kept awake. Headset buttons work here too:
 * play/pause mutes, next or previous track unmutes, as on the iPhone.
 */
package com.matthewdovi.teamtalkng

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.net.wifi.WifiManager
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import androidx.core.content.getSystemService

class ConnectionService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var media: MediaSession? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val sessions = SessionManager.sessions
        if (sessions.isEmpty()) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        var types = ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        }
        ServiceCompat.startForeground(this, NOTIFICATION_ID, notification(), types)
        acquire()
        return START_NOT_STICKY
    }

    private fun notification(): Notification {
        val names = SessionManager.sessions.joinToString(", ") { it.displayName }
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("TeamTalk NG")
            .setContentText("Connected to $names")
            .setOngoing(true)
            .setContentIntent(open)
            .build()
    }

    @SuppressLint("WakelockTimeout")
    private fun acquire() {
        if (wakeLock == null) {
            wakeLock = getSystemService<PowerManager>()?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "TeamTalkNG:connection")?.apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        if (wifiLock == null) {
            wifiLock = getSystemService<WifiManager>()?.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "TeamTalkNG:connection")?.apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        if (media == null) {
            media = MediaSession(this, "TeamTalkNG").apply {
                setCallback(object : MediaSession.Callback() {
                    private fun voice(on: Boolean) {
                        SessionManager.active?.let { s -> if (on) AppHooks.withMicrophone { s.enableVoiceTx(true) } else s.enableVoiceTx(false) }
                    }
                    override fun onPause() = voice(false)
                    override fun onPlay() = voice(false)
                    override fun onSkipToNext() = voice(true)
                    override fun onSkipToPrevious() = voice(true)
                })
                setPlaybackState(PlaybackState.Builder().setState(PlaybackState.STATE_PLAYING, 0, 1f)
                    .setActions(PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_PLAY or
                        PlaybackState.ACTION_SKIP_TO_NEXT or PlaybackState.ACTION_SKIP_TO_PREVIOUS).build())
                isActive = true
            }
        }
    }

    override fun onDestroy() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wifiLock?.let { if (it.isHeld) it.release() }
        media?.release()
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "connection"
        private const val NOTIFICATION_ID = 1

        fun createChannel(context: Context) {
            context.getSystemService<NotificationManager>()?.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Connected servers", NotificationManager.IMPORTANCE_LOW),
            )
        }

        /** Brings the service in line with the connected servers. */
        fun update(context: Context) {
            val intent = Intent(context, ConnectionService::class.java)
            if (SessionManager.sessions.isEmpty()) context.stopService(intent)
            else runCatching { ContextCompat.startForegroundService(context, intent) }
        }
    }
}
