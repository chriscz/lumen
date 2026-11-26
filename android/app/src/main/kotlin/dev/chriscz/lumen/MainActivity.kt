// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

package dev.chriscz.lumen

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    // Android drops Wi-Fi multicast unless an app holds a MulticastLock. The
    // Hue Bridge emulator holds one while it runs, to hear SSDP searches.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lumen/multicast").setMethodCallHandler { call, result ->
            when (call.method) {
                "acquire" -> {
                    val lock = multicastLock ?: wifi().createMulticastLock("lumen-ssdp").apply {
                        setReferenceCounted(false)
                    }
                    multicastLock = lock
                    if (!lock.isHeld) lock.acquire()
                    result.success(null)
                }
                "release" -> {
                    multicastLock?.let { if (it.isHeld) it.release() }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun wifi(): WifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager

    override fun onDestroy() {
        multicastLock?.let { if (it.isHeld) it.release() }
        multicastLock = null
        super.onDestroy()
    }
}
