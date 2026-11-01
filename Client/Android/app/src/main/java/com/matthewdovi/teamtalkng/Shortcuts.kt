/*
 * Launcher shortcuts that connect to a saved server: Android's counterpart of
 * the iPhone app's Siri Shortcuts and Control Center control.
 */
package com.matthewdovi.teamtalkng

import android.content.Context
import android.content.Intent
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat

const val EXTRA_CONNECT_SERVER = "connect_server"

private fun shortcut(context: Context, server: Server): ShortcutInfoCompat =
    ShortcutInfoCompat.Builder(context, "connect-${server.syncID}")
        .setShortLabel(server.name)
        .setLongLabel("Connect to ${server.name}")
        .setIcon(IconCompat.createWithResource(context, R.mipmap.ic_launcher))
        .setIntent(Intent(context, MainActivity::class.java).setAction(Intent.ACTION_VIEW)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            .putExtra(EXTRA_CONNECT_SERVER, server.name))
        .build()

/** The first saved servers appear when the app's icon is held down. */
fun updateShortcuts(context: Context) {
    val servers = ServerStore.servers.filter { it.name.isNotBlank() }
    val limit = ShortcutManagerCompat.getMaxShortcutCountPerActivity(context)
    runCatching { ShortcutManagerCompat.setDynamicShortcuts(context, servers.take(limit).map { shortcut(context, it) }) }
}

/** Asks the launcher to pin a shortcut to the home screen. */
fun pinShortcut(context: Context, server: Server): Boolean =
    ShortcutManagerCompat.isRequestPinShortcutSupported(context) &&
        ShortcutManagerCompat.requestPinShortcut(context, shortcut(context, server), null)
