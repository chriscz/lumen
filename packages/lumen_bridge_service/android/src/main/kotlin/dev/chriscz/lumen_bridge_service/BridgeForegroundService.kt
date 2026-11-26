// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

package dev.chriscz.lumen_bridge_service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log

/**
 * Keeps the app process, and so the bridge's sockets in Dart, alive and
 * unfrozen while Lumen acts as a Hue Bridge, with a low-importance ongoing
 * notification. It holds no wake lock by default: a unicast packet to the
 * listening socket wakes the phone. With "Stay fully awake while charging"
 * on and the phone plugged in, it holds a partial wake lock and a Wi-Fi
 * lock, and lets go when unplugged or switched off.
 */
class BridgeForegroundService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var pluggedIn = false

    private val power = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            pluggedIn = intent.action == Intent.ACTION_POWER_CONNECTED
            updateLocks()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        createChannel()
        pluggedIn = chargingNow()
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_POWER_CONNECTED)
            addAction(Intent.ACTION_POWER_DISCONNECTED)
        }
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(power, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(power, filter)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIFICATION_ID, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            } else {
                startForeground(NOTIFICATION_ID, notification())
            }
        } catch (e: Exception) {
            Log.w(TAG, "Could not run in the foreground: $e")
            stopSelf()
            return START_NOT_STICKY
        }
        updateLocks()
        // Without the app's engine there is no bridge to keep up, so a
        // killed service stays down until the app starts it again.
        return START_NOT_STICKY
    }

    /** Shows the latest text and applies the wake lock choice. */
    fun refresh() {
        try {
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIFICATION_ID, notification())
        } catch (e: Exception) {
            Log.w(TAG, "Could not update the notification: $e")
        }
        updateLocks()
    }

    override fun onDestroy() {
        instance = null
        try {
            unregisterReceiver(power)
        } catch (_: Exception) {
        }
        releaseLocks()
        super.onDestroy()
    }

    private fun chargingNow(): Boolean {
        val battery = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        return (battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0
    }

    private fun updateLocks() {
        if (stayAwakeWhileCharging && pluggedIn) acquireLocks() else releaseLocks()
    }

    private fun acquireLocks() {
        val wake = wakeLock ?: (getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "lumen:bridge")
            .apply { setReferenceCounted(false) }
        wakeLock = wake
        if (!wake.isHeld) wake.acquire()
        @Suppress("DEPRECATION")
        val mode = if (Build.VERSION.SDK_INT >= 29) {
            WifiManager.WIFI_MODE_FULL_LOW_LATENCY
        } else {
            WifiManager.WIFI_MODE_FULL_HIGH_PERF
        }
        val wifi = wifiLock ?: (applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager)
            .createWifiLock(mode, "lumen:bridge")
            .apply { setReferenceCounted(false) }
        wifiLock = wifi
        if (!wifi.isHeld) wifi.acquire()
    }

    private fun releaseLocks() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wifiLock?.let { if (it.isHeld) it.release() }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val channel = NotificationChannel(CHANNEL_ID, "Hue Bridge", NotificationManager.IMPORTANCE_LOW).apply {
            description = "Shows while Lumen acts as a Hue Bridge in the background."
            setShowBadge(false)
        }
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(channel)
    }

    private fun notification(): Notification {
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this).setPriority(Notification.PRIORITY_LOW)
        }
        builder
            .setSmallIcon(R.drawable.lumen_bridge_notification)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)
        packageManager.getLaunchIntentForPackage(packageName)?.let { launch ->
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            builder.setContentIntent(
                PendingIntent.getActivity(
                    this,
                    0,
                    launch,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                ),
            )
        }
        return builder.build()
    }

    companion object {
        private const val TAG = "LumenBridge"
        private const val CHANNEL_ID = "lumen_bridge"
        private const val NOTIFICATION_ID = 1818

        @Volatile private var instance: BridgeForegroundService? = null

        @Volatile private var title = "Lumen bridge running"

        @Volatile private var text = ""

        @Volatile private var stayAwakeWhileCharging = false

        /** Starts the service, or updates it when it already runs. */
        fun run(context: Context, title: String, text: String, stayAwakeWhileCharging: Boolean) {
            this.title = title
            this.text = text
            this.stayAwakeWhileCharging = stayAwakeWhileCharging
            val running = instance
            if (running != null) {
                running.refresh()
                return
            }
            val intent = Intent(context, BridgeForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, BridgeForegroundService::class.java))
        }
    }
}
