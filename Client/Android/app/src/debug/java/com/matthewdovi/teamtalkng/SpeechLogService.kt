package com.matthewdovi.teamtalkng

import android.media.AudioFormat
import android.speech.tts.SynthesisCallback
import android.speech.tts.SynthesisRequest
import android.speech.tts.TextToSpeech
import android.speech.tts.TextToSpeechService
import android.util.Log

/**
 * Debug builds only: a silent speech engine that logs what it is asked to say,
 * so a test can read exactly what TalkBack speaks on a screen:
 *   adb shell settings put secure tts_default_synth com.matthewdovi.teamtalkng
 */
class SpeechLogService : TextToSpeechService() {
    override fun onIsLanguageAvailable(lang: String?, country: String?, variant: String?) = TextToSpeech.LANG_COUNTRY_AVAILABLE
    override fun onGetLanguage() = arrayOf("eng", "USA", "")
    override fun onLoadLanguage(lang: String?, country: String?, variant: String?) = TextToSpeech.LANG_COUNTRY_AVAILABLE
    override fun onStop() {}
    override fun onSynthesizeText(request: SynthesisRequest, callback: SynthesisCallback) {
        Log.i("SpeechLog", request.charSequenceText?.toString() ?: request.text.orEmpty())
        callback.start(16000, AudioFormat.ENCODING_PCM_16BIT, 1)
        val silence = ByteArray(640)
        callback.audioAvailable(silence, 0, silence.size)
        callback.done()
    }
}
