/*
 * Spoken events. With TalkBack on they go through TalkBack (when the setting
 * says so and the app is on screen), otherwise through Android's text to
 * speech, like the iPhone app's VoiceOver and AVSpeechSynthesizer.
 */
package com.matthewdovi.teamtalkng

import android.content.Context
import android.media.AudioAttributes
import android.os.Bundle
import android.util.Log
import android.speech.tts.TextToSpeech
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityManager
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.getSystemService
import java.util.Locale

object Speech {
    /** A voice to choose: an engine's voice, or a language where it lists no voices. */
    class Choice(val id: String, val label: String, val languageTag: String)
    class Engine(val packageName: String, val label: String)

    private const val LANGUAGE_PREFIX = "language:"
    private lateinit var context: Context
    private var tts: TextToSpeech? = null
    private var ready = false
    private val waiting = mutableListOf<String>()
    private var next = 0
    /** Set by the visible activity: announces through TalkBack. */
    var announceInWindow: ((String) -> Unit)? = null

    /** What the engine offers; empty until it has started. */
    var choices by mutableStateOf<List<Choice>>(emptyList())
        private set
    var engines by mutableStateOf<List<Engine>>(emptyList())
        private set
    /** Starting, ready or failed, for the voice screen. */
    var state by mutableStateOf(State.Idle)
        private set

    enum class State { Idle, Starting, Ready, Failed }

    fun init(appContext: Context) { context = appContext }

    private fun engine(): TextToSpeech {
        tts?.let { return it }
        state = State.Starting
        val chosen = Prefs.string(PREF_TTSEVENT_ENGINE).ifEmpty { null }
        val created = TextToSpeech(context, { status -> started(status) }, chosen)
        tts = created
        return created
    }

    private fun started(status: Int) {
        ready = status == TextToSpeech.SUCCESS
        val engine = tts
        engines = runCatching { engine?.engines.orEmpty() }.getOrDefault(emptyList())
            .map { Engine(it.name, it.label) }.sortedBy { it.label.lowercase() }
        if (!ready || engine == null) {
            Log.w("Speech", "The speech engine did not start: $status")
            state = State.Failed
            choices = emptyList()
            return
        }
        engine.setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
        choices = readChoices(engine)
        state = State.Ready
        waiting.toList().also { waiting.clear() }.forEach { say(it) }
    }

    private fun readChoices(engine: TextToSpeech): List<Choice> {
        val voices = runCatching { engine.voices.orEmpty() }.getOrDefault(emptySet())
            .filter { "notInstalled" !in it.features }
        if (voices.isNotEmpty()) {
            return voices.sortedWith(compareBy({ it.locale.displayName }, { it.name })).map {
                val online = if (it.isNetworkConnectionRequired) ", needs internet" else ""
                Choice(it.name, "${it.locale.displayName}, ${it.name}$online", it.locale.toLanguageTag())
            }
        }
        // Some engines list languages only.
        return runCatching { engine.availableLanguages.orEmpty() }.getOrDefault(emptySet())
            .sortedBy { it.displayName }.map { Choice(LANGUAGE_PREFIX + it.toLanguageTag(), it.displayName, it.toLanguageTag()) }
    }

    /** Starts the engine, so that [choices] and [engines] fill in. */
    fun prepare() {
        engine()
    }

    /** Another engine: its voices replace the last one's, and a voice from that one no longer applies. */
    fun useEngine(packageName: String) {
        if (packageName == Prefs.string(PREF_TTSEVENT_ENGINE)) return
        if (packageName.isEmpty()) Prefs.remove(PREF_TTSEVENT_ENGINE) else Prefs.set(PREF_TTSEVENT_ENGINE, packageName)
        Prefs.remove(PREF_TTSEVENT_VOICEID)
        Prefs.remove(PREF_TTSEVENT_VOICELANG)
        runCatching { tts?.shutdown() }
        tts = null
        ready = false
        choices = emptyList()
        engine()
    }

    val talkBackOn: Boolean
        get() = context.getSystemService<AccessibilityManager>()?.let { it.isEnabled && it.isTouchExplorationEnabled } == true

    fun speak(text: String, allowTalkBack: Boolean = true) {
        val announce = announceInWindow
        if (allowTalkBack && Prefs.on(PREF_TTSEVENT_USE_VOICEOVER) && talkBackOn && announce != null) {
            announce(text)
            return
        }
        engine()
        if (ready) say(text) else waiting.add(text)
    }

    private fun say(text: String) {
        val engine = tts ?: return
        // The chosen voice; if this phone doesn't have it (the setting came from
        // another device), a voice for its language; else the default.
        val id = Prefs.string(PREF_TTSEVENT_VOICEID)
        val voice = runCatching { engine.voices.orEmpty() }.getOrDefault(emptySet()).firstOrNull { it.name == id }
        if (voice != null) {
            engine.voice = voice
        } else {
            Prefs.string(PREF_TTSEVENT_VOICELANG).takeIf { it.isNotEmpty() }?.let {
                engine.language = Locale.forLanguageTag(it)
            }
        }
        // iOS speech rates run from 0 to 1 with 0.5 as normal.
        engine.setSpeechRate(Prefs.float(PREF_TTSEVENT_RATE, 0.5f) * 2f)
        val params = Bundle().apply { putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, Prefs.float(PREF_TTSEVENT_VOL, 1f)) }
        engine.speak(text, TextToSpeech.QUEUE_ADD, params, "tt-${next++}")
    }

    fun preview(text: String) = speak(text, allowTalkBack = false)
}

fun newUtterance(text: String) = Speech.speak(text)

/** Says something to TalkBack users only (what the iPhone app posts as an announcement). */
fun announce(text: String) {
    Speech.announceInWindow?.invoke(text)
}

/** The event itself, for the activity. */
fun accessibilityAnnouncement(context: Context, text: String) {
    val manager = context.getSystemService<AccessibilityManager>() ?: return
    if (!manager.isEnabled) return
    val event = AccessibilityEvent.obtain(AccessibilityEvent.TYPE_ANNOUNCEMENT)
    event.packageName = context.packageName
    event.text.add(text)
    manager.sendAccessibilityEvent(event)
}
