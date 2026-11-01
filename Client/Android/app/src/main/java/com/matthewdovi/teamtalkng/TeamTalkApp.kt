package com.matthewdovi.teamtalkng

import android.app.Application
import android.content.Context
import com.google.firebase.FirebaseApp
import dk.bearware.TeamTalk5

class TeamTalkApp : Application() {
    override fun onCreate() {
        super.onCreate()
        context = this
        TeamTalk5.loadLibrary()
        Prefs.init(this)
        SecretStore.init(this)
        MonitorInstall.init(this)
        Speech.init(this)
        SoundPlayer.init(this)
        SoundPackStore.init(this)
        ServerStore.load()
        AudioRouting.watchDevices()
        AudioNetBridge.attach(this)
        ConnectionService.createChannel(this)
        MonitorNotifications.createChannels(this)
        // FirebaseApp sets itself up from google-services.json's resources;
        // a build without them has no pushes.
        FirebaseApp.initializeApp(this)
        MonitorCenter.start()
        NGSync.start()
        NGPackSync.start()
    }

    companion object {
        lateinit var context: Context
            private set
    }
}
