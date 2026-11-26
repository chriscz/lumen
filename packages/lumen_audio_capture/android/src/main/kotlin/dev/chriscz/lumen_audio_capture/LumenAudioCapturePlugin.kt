// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

package dev.chriscz.lumen_audio_capture

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * The Android side of Lumen's music sync, on two channels: "lumen/audio"
 * reports and asks for what each source needs, and "lumen/audio/chunks"
 * runs a source while Dart listens: the microphone ("microphone"), the
 * Visualizer on the phone's output ("phoneSound") or audio playback capture
 * ("capture", Android 10 and later, after the user agrees each time).
 */
class LumenAudioCapturePlugin :
    FlutterPlugin,
    ActivityAware,
    EventChannel.StreamHandler,
    PluginRegistry.RequestPermissionsResultListener,
    PluginRegistry.ActivityResultListener {
    private lateinit var context: Context
    private lateinit var methods: MethodChannel
    private lateinit var chunks: EventChannel
    private val main = Handler(Looper.getMainLooper())
    private var activity: ActivityPluginBinding? = null
    private var pendingPermission: Pair<String, MethodChannel.Result>? = null
    private var events: EventChannel.EventSink? = null
    private var source: Source? = null
    private var projection: MediaProjection? = null

    /** Counts listens, so a late callback from an old one is ignored. */
    private var run = 0

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "lumen/audio")
        methods.setMethodCallHandler(::onCall)
        chunks = EventChannel(binding.binaryMessenger, "lumen/audio/chunks")
        chunks.setStreamHandler(this)
    }

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        val name = call.argument<String>("source") ?: "microphone"
        try {
            when (call.method) {
                "status" -> result.success(status(name))
                "requestPermission" -> requestPermission(name, result)
                "openSettings" -> {
                    val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    context.startActivity(intent)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("failed", e.toString(), null)
        }
    }

    private fun granted(): Boolean =
        context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private val prefs get() = context.getSharedPreferences("lumen_audio_capture", Context.MODE_PRIVATE)

    /**
     * What [name] needs: "unsupported" with a reason, "ready", or the
     * microphone permission: "needsPermission" while Android will still
     * ask, "denied" once it will not (asked before, and no rationale to show).
     */
    private fun status(name: String): Map<String, Any?> {
        if (name == "capture" && !VisualizerSource.captureSupported) {
            return mapOf("state" to "unsupported", "reason" to "Needs Android 10 or later")
        }
        if (granted()) return mapOf("state" to "ready")
        val asked = prefs.getBoolean(ASKED, false)
        val current = activity?.activity
        val rationale = current?.shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO) ?: true
        return mapOf("state" to if (asked && !rationale) "denied" else "needsPermission")
    }

    private fun requestPermission(name: String, result: MethodChannel.Result) {
        val current = activity
        if (granted() || current == null || pendingPermission != null) {
            result.success(status(name))
            return
        }
        prefs.edit().putBoolean(ASKED, true).apply()
        pendingPermission = name to result
        current.activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_RECORD)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_RECORD) return false
        val (name, result) = pendingPermission ?: return true
        pendingPermission = null
        result.success(status(name))
        return true
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        stopSource()
        events = sink
        val mine = ++run
        val name = (arguments as? Map<*, *>)?.get("source") as? String ?: "microphone"
        val out = object : Sink {
            override fun chunk(event: Map<String, Any>) {
                if (mine == run) events?.success(event)
            }

            // Either ends this listen: later callbacks from it are ignored.
            override fun fail(code: String, message: String) {
                if (mine != run) return
                run++
                events?.error(code, message, null)
                stopSource()
            }

            override fun end() {
                if (mine != run) return
                run++
                events?.endOfStream()
                stopSource()
            }
        }
        if (!granted()) {
            out.fail("denied", "Music sync needs the microphone permission to hear the music.")
            return
        }
        try {
            when (name) {
                // The source first, then the service: a service started and
                // stopped before it reaches the foreground crashes the app.
                "phoneSound" -> {
                    source = try {
                        VisualizerSource(out)
                    } catch (e: Exception) {
                        Log.w(TAG, "No Visualizer: $e")
                        out.fail("unavailable", "This phone does not share its sound output. Try the microphone.")
                        return
                    }
                    MusicSyncService.listen(context, "Following the phone's sound") { why -> out.fail("unavailable", why) }
                }
                "capture" -> capture(out)
                else -> {
                    source = RecordSource.microphone(context, out)
                    MusicSyncService.listen(context, "Listening to the microphone") { why -> out.fail("unavailable", why) }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Could not start $name: $e")
            out.fail("unavailable", e.message ?: "The sound source would not start.")
        }
    }

    /** Asks for the user's consent; the rest happens in [onActivityResult]. */
    private fun capture(out: Sink) {
        if (Build.VERSION.SDK_INT < 29) {
            out.fail("unavailable", "Audio capture needs Android 10 or later.")
            return
        }
        val current = activity?.activity
        if (current == null) {
            out.fail("unavailable", "Open Lumen to start audio capture.")
            return
        }
        pendingCapture = out
        val manager = context.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        current.startActivityForResult(manager.createScreenCaptureIntent(), REQUEST_CAPTURE)
    }

    private var pendingCapture: Sink? = null

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CAPTURE) return false
        val out = pendingCapture ?: return true
        pendingCapture = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            out.fail("cancelled", "Audio capture was not allowed, so music sync did not start.")
            return true
        }
        val mine = run
        MusicSyncService.project(context, "Capturing the phone's sound", resultCode, data) { got, why ->
            main.post {
                if (mine != run) {
                    got?.stop()
                    return@post
                }
                if (got == null || Build.VERSION.SDK_INT < 29) {
                    out.fail("unavailable", why ?: "Android did not hand over the sound.")
                    return@post
                }
                projection = got
                got.registerCallback(
                    object : MediaProjection.Callback() {
                        override fun onStop() {
                            main.post { if (mine == run) out.end() }
                        }
                    },
                    main,
                )
                source = try {
                    RecordSource.capture(got, out)
                } catch (e: Exception) {
                    Log.w(TAG, "Capture would not start: $e")
                    out.fail("unavailable", "Audio capture would not start: ${e.message}")
                    null
                }
            }
        }
        return true
    }

    override fun onCancel(arguments: Any?) {
        run++
        stopSource()
        events = null
    }

    private fun stopSource() {
        source?.stop()
        source = null
        projection?.stop()
        projection = null
        pendingCapture = null
        MusicSyncService.stop(context)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addRequestPermissionsResultListener(this)
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activity?.removeRequestPermissionsResultListener(this)
        activity?.removeActivityResultListener(this)
        activity = null
        pendingPermission?.let { (name, result) -> result.success(status(name)) }
        pendingPermission = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        run++
        stopSource()
        methods.setMethodCallHandler(null)
        chunks.setStreamHandler(null)
    }

    private companion object {
        const val TAG = "LumenAudio"
        const val ASKED = "askedRecordAudio"
        const val REQUEST_RECORD = 1919
        const val REQUEST_CAPTURE = 1920
    }
}
