// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

package dev.chriscz.lumen_audio_capture

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Keeps music sync listening while another app, such as Spotify, is in
 * front, with a quiet ongoing notification. Android lets a background app
 * use the microphone only from a microphone service started while the app
 * was open, and hands out a media projection only to a running media
 * projection service, so the service starts as one or the other.
 */
class MusicSyncService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val projecting = intent?.getBooleanExtra(EXTRA_PROJECTION, false) == true
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: "Listening"
        try {
            when {
                Build.VERSION.SDK_INT >= 30 && !projecting ->
                    startForeground(NOTIFICATION_ID, notification(text), ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
                Build.VERSION.SDK_INT >= 29 && projecting ->
                    startForeground(
                        NOTIFICATION_ID,
                        notification(text),
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
                    )
                else -> startForeground(NOTIFICATION_ID, notification(text))
            }
        } catch (e: Exception) {
            Log.w(TAG, "Could not run in the foreground: $e")
            if (projecting) {
                onProjection?.invoke(null, "Android did not let Lumen capture the sound: ${e.message}")
                onProjection = null
            } else {
                // Left running without the foreground, Android would stop
                // the app once its timeout ran out: stop now and say why.
                onListenFailed?.invoke("Android did not let Lumen keep listening: ${e.message}")
            }
            onListenFailed = null
            stopSelf()
            return START_NOT_STICKY
        }
        onListenFailed = null
        if (projecting && Build.VERSION.SDK_INT >= 29) {
            val callback = onProjection
            onProjection = null
            val resultCode = intent?.getIntExtra(EXTRA_RESULT_CODE, Activity.RESULT_CANCELED) ?: Activity.RESULT_CANCELED
            @Suppress("DEPRECATION")
            val data = intent?.getParcelableExtra<Intent>(EXTRA_RESULT_DATA)
            val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            val projection = try {
                if (data == null) null else manager.getMediaProjection(resultCode, data)
            } catch (e: Exception) {
                Log.w(TAG, "No media projection: $e")
                null
            }
            callback?.invoke(projection, if (projection == null) "Android did not hand over the sound." else null)
        }
        // Without the app's engine there is nothing to listen for.
        return START_NOT_STICKY
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val channel = NotificationChannel(CHANNEL_ID, "Music sync", NotificationManager.IMPORTANCE_LOW).apply {
            description = "Shows while Lumen moves the lights with the music."
            setShowBadge(false)
        }
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(channel)
    }

    private fun notification(text: String): Notification {
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this).setPriority(Notification.PRIORITY_LOW)
        }
        builder
            .setSmallIcon(R.drawable.lumen_music_notification)
            .setContentTitle("Lumen music sync")
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)
        packageManager.getLaunchIntentForPackage(packageName)?.let { launch ->
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            builder.setContentIntent(
                PendingIntent.getActivity(this, 0, launch, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT),
            )
        }
        return builder.build()
    }

    companion object {
        private const val TAG = "LumenMusic"
        private const val CHANNEL_ID = "lumen_music"
        private const val NOTIFICATION_ID = 1919
        private const val EXTRA_TEXT = "text"
        private const val EXTRA_PROJECTION = "projection"
        private const val EXTRA_RESULT_CODE = "resultCode"
        private const val EXTRA_RESULT_DATA = "resultData"

        /** Told why, when the microphone service could not run in the foreground. */
        @Volatile private var onListenFailed: ((String) -> Unit)? = null

        /** Gets the media projection, or null with why, once the service runs. */
        @Volatile private var onProjection: ((MediaProjection?, String?) -> Unit)? = null

        /**
         * Runs as a microphone service, for the microphone and the
         * Visualizer; [failed] hears why if Android refuses the foreground.
         */
        fun listen(context: Context, text: String, failed: (String) -> Unit) {
            onListenFailed = failed
            start(context, Intent(context, MusicSyncService::class.java).putExtra(EXTRA_TEXT, text))
        }

        /**
         * Runs as a media projection service with the user's consent, then
         * hands the projection to [then].
         */
        fun project(
            context: Context,
            text: String,
            resultCode: Int,
            data: Intent,
            then: (MediaProjection?, String?) -> Unit,
        ) {
            onProjection = then
            val intent = Intent(context, MusicSyncService::class.java)
                .putExtra(EXTRA_TEXT, text)
                .putExtra(EXTRA_PROJECTION, true)
                .putExtra(EXTRA_RESULT_CODE, resultCode)
                .putExtra(EXTRA_RESULT_DATA, data)
            start(context, intent)
        }

        private fun start(context: Context, intent: Intent) {
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
        }

        fun stop(context: Context) {
            onProjection = null
            onListenFailed = null
            context.stopService(Intent(context, MusicSyncService::class.java))
        }
    }
}
