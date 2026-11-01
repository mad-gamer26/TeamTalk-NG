package com.matthewdovi.teamtalkng

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import java.io.File
import kotlin.math.PI
import kotlin.math.sin

/**
 * Debug builds only: sends a test tone through the mixer and TT_InsertAudioBlock,
 * the path AudioNet uses, without needing an AudioNet account:
 *
 *   adb shell am broadcast -n com.matthewdovi.teamtalkng/.DebugStreamReceiver --es do tone
 *   --es do file --es path /sdcard/Download/tone.flac   (joins the mix, decoded by Android)
 *   --es do stop
 */
class DebugStreamReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        // A pretend push, handled as PushService handles a real one.
        intent.getStringExtra("ttng")?.let { text ->
            val opened = MonitorPush.content(org.json.JSONObject(text))
            Log.i("DebugStream", "push opened: ${opened?.second?.str("body")}")
            opened?.let { (ref, content) -> MonitorNotifications.show(context, ref, content) }
            return
        }
        val streaming = SessionManager.active?.streaming ?: return
        when (intent.getStringExtra("do")) {
            "tone" -> {
                var n = 0L
                val format = streaming.channelFormat()
                val error = streaming.attachAudioNet { frames ->
                    ShortArray(frames * format.channels) {
                        (8000 * sin(2 * PI * 440 * (n++ / format.channels) / format.sampleRate)).toInt().toShort()
                    }
                }
                Log.i("DebugStream", "tone: ${error ?: "sending"}")
            }
            "file" -> {
                val copy = File(context.cacheDir, "debug-" + File(intent.getStringExtra("path")!!).name)
                File(intent.getStringExtra("path")!!).copyTo(copy, overwrite = true)
                Log.i("DebugStream", "file: ${streaming.streamFile(copy) ?: "joined"}")
            }
            "stop" -> streaming.detachAudioNet()
        }
    }
}
