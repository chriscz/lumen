// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

package dev.chriscz.lumen_bridge_service

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * The Android side of Lumen's emulated Hue Bridge, on two channels:
 * "lumen/bridge_service" runs the foreground service that keeps the bridge
 * listening in the background, asks for the notification permission and
 * opens the battery optimisation settings; "lumen/nsd" registers and browses
 * `_hue._tcp` with Android's own mDNS responder (NsdManager).
 */
class LumenBridgeServicePlugin :
    FlutterPlugin,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {
    private lateinit var context: Context
    private lateinit var service: MethodChannel
    private lateinit var nsdChannel: MethodChannel
    private lateinit var nsd: NsdBridge
    private var activity: ActivityPluginBinding? = null
    private var pendingPermission: MethodChannel.Result? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        nsd = NsdBridge(context)
        service = MethodChannel(binding.binaryMessenger, "lumen/bridge_service")
        service.setMethodCallHandler(::onServiceCall)
        nsdChannel = MethodChannel(binding.binaryMessenger, "lumen/nsd")
        nsdChannel.setMethodCallHandler(::onNsdCall)
    }

    private fun onServiceCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "run" -> {
                    BridgeForegroundService.run(
                        context,
                        title = call.argument<String>("title") ?: "Lumen bridge running",
                        text = call.argument<String>("text") ?: "",
                        stayAwakeWhileCharging = call.argument<Boolean>("stayAwakeWhileCharging") ?: false,
                    )
                    result.success(true)
                }
                "stop" -> {
                    BridgeForegroundService.stop(context)
                    result.success(true)
                }
                "requestNotifications" -> requestNotifications(result)
                "openBatterySettings" -> {
                    val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    context.startActivity(intent)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("failed", e.toString(), null)
        }
    }

    private fun onNsdCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "register" -> nsd.register(
                name = call.argument<String>("name") ?: "Lumen",
                type = call.argument<String>("type") ?: "_hue._tcp",
                port = call.argument<Int>("port") ?: 0,
                txt = call.argument<Map<String, String>>("txt") ?: emptyMap(),
                result = result,
            )
            "unregister" -> {
                nsd.unregister()
                result.success(null)
            }
            "browse" -> nsd.browse(
                type = call.argument<String>("type") ?: "_hue._tcp",
                windowMs = (call.argument<Int>("windowMs") ?: 3000).toLong(),
                result = result,
            )
            else -> result.notImplemented()
        }
    }

    /** Android 13 and later ask; earlier versions grant it at install. */
    private fun requestNotifications(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 33) {
            result.success(true)
            return
        }
        val permission = Manifest.permission.POST_NOTIFICATIONS
        if (context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) {
            result.success(true)
            return
        }
        val current = activity
        if (current == null || pendingPermission != null) {
            result.success(false)
            return
        }
        pendingPermission = result
        current.activity.requestPermissions(arrayOf(permission), REQUEST_NOTIFICATIONS)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_NOTIFICATIONS) return false
        val result = pendingPermission ?: return true
        pendingPermission = null
        result.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
        return true
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activity?.removeRequestPermissionsResultListener(this)
        activity = null
        pendingPermission?.success(false)
        pendingPermission = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        service.setMethodCallHandler(null)
        nsdChannel.setMethodCallHandler(null)
        nsd.unregister()
        // The engine, and with it the bridge's server, is gone: so is the
        // reason for the notification.
        BridgeForegroundService.stop(context)
    }

    private companion object {
        const val REQUEST_NOTIFICATIONS = 1818
    }
}
