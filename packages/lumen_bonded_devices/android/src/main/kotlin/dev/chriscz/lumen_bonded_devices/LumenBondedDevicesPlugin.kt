// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

package dev.chriscz.lumen_bonded_devices

import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Lists the Bluetooth devices this phone holds a bond with. Bonds belong to
 * the phone, not to an app, so a bulb the Hue app bonded is listed too.
 * Also opens the app's settings page, on its own channel "lumen/settings".
 */
class LumenBondedDevicesPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var settings: MethodChannel
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "lumen/bonded_devices")
        channel.setMethodCallHandler(this)
        settings = MethodChannel(binding.binaryMessenger, "lumen/settings")
        settings.setMethodCallHandler { call, result ->
            if (call.method != "openAppSettings") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            try {
                val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                    .setData(Uri.fromParts("package", context.packageName, null))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(intent)
                result.success(true)
            } catch (e: Exception) {
                result.error("failed", e.toString(), null)
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "bondedDevices") {
            result.notImplemented()
            return
        }
        try {
            val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager?
            val adapter = manager?.adapter
            if (adapter == null) {
                result.success(emptyList<Map<String, Any?>>())
                return
            }
            val devices = adapter.bondedDevices.orEmpty().map { d ->
                mapOf(
                    "id" to d.address,
                    "name" to (d.name ?: ""),
                    "type" to d.type,
                    "uuids" to (d.uuids?.map { it.uuid.toString() } ?: emptyList()),
                )
            }
            result.success(devices)
        } catch (e: SecurityException) {
            result.error("permission", e.toString(), null)
        } catch (e: Exception) {
            result.error("failed", e.toString(), null)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        settings.setMethodCallHandler(null)
    }
}
