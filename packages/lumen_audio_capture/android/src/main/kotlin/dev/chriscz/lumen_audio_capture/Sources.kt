// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

package dev.chriscz.lumen_audio_capture

import android.annotation.SuppressLint
import android.annotation.TargetApi
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.Visualizer
import android.media.projection.MediaProjection
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log

/** Where a source sends its sound, always on the main thread. */
interface Sink {
    fun chunk(event: Map<String, Any>)
    fun fail(code: String, message: String)
    fun end()
}

/** A running source of sound. */
interface Source {
    fun stop()
}

/**
 * Reads 16 bit mono samples from [record] on a thread of its own and sends
 * them on in chunks of 1024 samples, about 23 ms at 44.1 kHz.
 */
class RecordSource(private val record: AudioRecord, private val rate: Int, private val sink: Sink) : Source {
    private val main = Handler(Looper.getMainLooper())

    @Volatile private var running = true

    private val thread = Thread({
        try {
            record.startRecording()
            val buffer = ByteArray(2048)
            while (running) {
                val read = record.read(buffer, 0, buffer.size)
                if (read < 0) {
                    main.post { if (running) sink.fail("failed", "The sound stopped (error $read).") }
                    break
                }
                if (read == 0) continue
                val data = buffer.copyOf(read)
                main.post { if (running) sink.chunk(mapOf("type" to "pcm", "rate" to rate, "data" to data)) }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Recording failed: $e")
            main.post { if (running) sink.fail("failed", "The sound stopped: ${e.message}") }
        } finally {
            try {
                record.stop()
            } catch (_: Exception) {
            }
            record.release()
        }
    }, "lumen-audio")

    init {
        thread.start()
    }

    override fun stop() {
        running = false
    }

    companion object {
        private const val TAG = "LumenAudio"
        const val RATE = 44100

        fun bufferSize(): Int = maxOf(
            AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT),
            8192,
        )

        /**
         * The microphone, unprocessed where the phone offers it: the noise
         * suppression and gain control meant for voices flatten the drums.
         */
        @SuppressLint("MissingPermission")
        fun microphone(context: Context, sink: Sink): Source {
            val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val unprocessed = audio.getProperty(AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED) == "true"
            val input = if (unprocessed) MediaRecorder.AudioSource.UNPROCESSED else MediaRecorder.AudioSource.MIC
            val record = AudioRecord(input, RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, bufferSize())
            if (record.state != AudioRecord.STATE_INITIALIZED) {
                record.release()
                throw IllegalStateException("The microphone is busy or missing.")
            }
            return RecordSource(record, RATE, sink)
        }

        /**
         * A copy of what other apps play for media and games, through a
         * media projection the user agreed to. Apps that opt out, such as
         * Spotify, are left out and so sound silent.
         */
        @TargetApi(29)
        @SuppressLint("MissingPermission")
        fun capture(projection: MediaProjection, sink: Sink): Source {
            val config = AudioPlaybackCaptureConfiguration.Builder(projection)
                .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                .addMatchingUsage(AudioAttributes.USAGE_GAME)
                .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                .build()
            val format = AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(RATE)
                .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                .build()
            val record = AudioRecord.Builder()
                .setAudioFormat(format)
                .setBufferSizeInBytes(bufferSize())
                .setAudioPlaybackCaptureConfig(config)
                .build()
            return RecordSource(record, RATE, sink)
        }
    }
}

/**
 * The Visualizer on the phone's sound output (audio session 0): about 20
 * spectra a second of whatever plays, Spotify included on most phones. It
 * gives levels, not audio, and some phones do not offer it.
 */
class VisualizerSource(private val sink: Sink) : Source {
    private val visualizer = Visualizer(0)

    init {
        try {
            visualizer.setEnabled(false)
            visualizer.setCaptureSize(minOf(1024, Visualizer.getCaptureSizeRange()[1]))
            // As played, not normalised: normalising scales each snapshot to its
            // own peak, which flattens the loudness changes the beat shows in
            // and blows silence up to full scale. The tracker scales by itself.
            visualizer.setScalingMode(Visualizer.SCALING_MODE_AS_PLAYED)
            val listener = object : Visualizer.OnDataCaptureListener {
                override fun onWaveFormDataCapture(v: Visualizer?, waveform: ByteArray?, samplingRate: Int) {}

                override fun onFftDataCapture(v: Visualizer?, fft: ByteArray?, samplingRate: Int) {
                    if (fft == null) return
                    sink.chunk(
                        mapOf(
                            "type" to "fft",
                            // The Visualizer gives its rate in milliHertz.
                            "rate" to samplingRate / 1000,
                            "atUs" to SystemClock.elapsedRealtimeNanos() / 1000,
                            "data" to fft.copyOf(),
                        ),
                    )
                }
            }
            // Created on the main thread, so it calls back there, as the
            // sink needs.
            visualizer.setDataCaptureListener(listener, Visualizer.getMaxCaptureRate(), false, true)
            visualizer.setEnabled(true)
        } catch (e: Exception) {
            visualizer.release()
            throw e
        }
    }

    override fun stop() {
        try {
            visualizer.setEnabled(false)
        } catch (_: Exception) {
        }
        visualizer.release()
    }

    companion object {
        /** Whether this Android version has playback capture. */
        val captureSupported: Boolean get() = Build.VERSION.SDK_INT >= 29
    }
}
