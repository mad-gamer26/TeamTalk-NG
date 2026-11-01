package com.matthewdovi.teamtalkng

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import com.matthewdovi.teamtalkng.ui.Navigator
import com.matthewdovi.teamtalkng.ui.Screen
import com.matthewdovi.teamtalkng.ui.TeamTalkNGApp

class MainActivity : ComponentActivity() {
    private var afterMicrophone: (() -> Unit)? = null

    private val microphonePermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        val then = afterMicrophone
        afterMicrophone = null
        if (granted) {
            ConnectionService.update(this)
            then?.invoke()
        }
    }

    private val notificationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) {
        MonitorNotifications.register()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        AppHooks.withMicrophone = { then ->
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) then()
            else {
                afterMicrophone = then
                microphonePermission.launch(Manifest.permission.RECORD_AUDIO)
            }
        }
        AppHooks.sessionClosed = { Navigator.closed(it) }
        MonitorNotifications.openHandler = { ref, serverID, chat ->
            MonitorCenter.reload()
            if (MonitorCenter.connection(ref) != null) {
                Navigator.popToRoot()
                Navigator.push(Screen.Monitors)
                Navigator.push(Screen.MonitorSession(ref, serverID))
                chat?.let { Navigator.push(Screen.MonitorChat(ref, serverID, it)) }
            }
        }
        setContent { TeamTalkNGApp() }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && MonitorAccountStore.all().isNotEmpty() &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        else MonitorNotifications.register()
        if (savedInstanceState == null) handle(intent)
    }

    override fun onStart() {
        super.onStart()
        val root = window.decorView.findViewById<FrameLayout>(android.R.id.content)
        Speech.announceInWindow = { text -> root.announceForAccessibility(text) }
        MonitorCenter.foreground()
    }

    override fun onStop() {
        Speech.announceInWindow = null
        MonitorCenter.background()
        super.onStop()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    private fun handle(intent: Intent) {
        // A tapped monitor notification.
        val ref = intent.getStringExtra(EXTRA_MONITOR_REF)
        val data = intent.getStringExtra(EXTRA_MONITOR_DATA)
        if (ref != null && data != null) {
            MonitorNotifications.open(ref, data)
            return
        }
        // A shortcut.
        intent.getStringExtra(EXTRA_CONNECT_SERVER)?.let { name ->
            ServerStore.servers.firstOrNull { it.name == name }?.let { Navigator.show(SessionManager.connect(it)) }
            return
        }
        val uri: Uri = intent.data ?: return
        if (uri.toString().startsWith(AppInfo.TTLINK_PREFIX)) {
            ServerLink.parse(uri)?.let {
                Navigator.popToRoot()
                Navigator.push(Screen.LinkDetails(it))
            }
        } else {
            // A .tt file.
            Navigator.popToRoot()
            Navigator.pendingImport.value = uri
        }
    }
}
