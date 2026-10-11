package app.laptrace.logger.record

import android.content.Context
import android.media.AudioAttributes
import android.speech.tts.TextToSpeech
import app.laptrace.logger.core.LapCuePhrase
import java.util.Locale

/** Speaks the lap time over whatever audio is playing, e.g. "1 12.4. Plus 0.6." */
class LapCue(private val context: Context) {
    private var tts: TextToSpeech? = null
    private var ready = false

    val enabled: Boolean get() = Prefs.of(context).getBoolean(Prefs.SPEAK_LAP_TIMES, true)

    fun prepare() {
        if (tts != null || !enabled) return
        tts = TextToSpeech(context.applicationContext) { status ->
            ready = status == TextToSpeech.SUCCESS
            tts?.apply {
                language = Locale.US
                setSpeechRate(1.05f)
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )
            }
        }
    }

    fun speak(duration: Double, previousBest: Double?) {
        if (!enabled) return
        prepare()
        if (!ready) return
        tts?.speak(LapCuePhrase.phrase(duration, previousBest), TextToSpeech.QUEUE_FLUSH, null, "lap")
    }

    fun shutdown() {
        tts?.shutdown(); tts = null; ready = false
    }
}
