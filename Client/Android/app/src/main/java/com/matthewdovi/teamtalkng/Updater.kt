/*
 * Keeps sideloaded copies of the app up to date, as MG Notify does: reads
 * android.json from the service's site, downloads a newer release, checks its
 * SHA-256, and hands it to Android's installer, which asks the person to confirm.
 */
package com.matthewdovi.teamtalkng

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.provider.Settings
import androidx.core.content.IntentCompat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.net.URL
import java.security.MessageDigest

object Updater {
    /** Checks, and installs a newer release; says how it went, in words. */
    suspend fun check(context: Context): String {
        if (BuildConfig.UPDATES_URL.isEmpty()) return "Debug builds don't update themselves."
        return try {
            val json = withContext(Dispatchers.IO) { JSONObject(URL(BuildConfig.UPDATES_URL).readText()) }
            val code = json.getLong("version_code")
            if (code <= BuildConfig.VERSION_CODE) return "TeamTalk NG is up to date."
            if (!context.packageManager.canRequestPackageInstalls()) {
                context.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return "Allow TeamTalk NG to install apps, then check again."
            }
            announce("Downloading version ${json.getString("version_name")}.")
            val file = File(context.cacheDir, "update.apk")
            val sha = withContext(Dispatchers.IO) {
                val digest = MessageDigest.getInstance("SHA-256")
                URL(json.getString("url")).openStream().use { input ->
                    file.outputStream().use { output ->
                        val buffer = ByteArray(64 * 1024)
                        while (true) {
                            val n = input.read(buffer)
                            if (n < 0) break
                            digest.update(buffer, 0, n)
                            output.write(buffer, 0, n)
                        }
                    }
                }
                digest.digest().joinToString("") { "%02x".format(it) }
            }
            if (sha != json.getString("sha256").lowercase()) {
                file.delete()
                return "The download was damaged. Try again."
            }
            withContext(Dispatchers.IO) { install(context, file) }
            "Installing version ${json.getString("version_name")}."
        } catch (_: Exception) {
            "Couldn't check for updates. Check your connection and try again."
        }
    }

    private fun install(context: Context, file: File) {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setSize(file.length())
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            session.openWrite("app", 0, file.length()).use { out ->
                file.inputStream().use { it.copyTo(out) }
                session.fsync(out)
            }
            val intent = Intent(context, UpdateInstallReceiver::class.java)
            val pending = PendingIntent.getBroadcast(context, id, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
            session.commit(pending.intentSender)
        }
        file.delete()
    }
}

class UpdateInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -1) == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            IntentCompat.getParcelableExtra(intent, Intent.EXTRA_INTENT, Intent::class.java)?.let {
                context.startActivity(it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
        }
    }
}
