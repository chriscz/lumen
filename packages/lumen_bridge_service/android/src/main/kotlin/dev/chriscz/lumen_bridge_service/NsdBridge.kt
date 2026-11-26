// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

package dev.chriscz.lumen_bridge_service

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address

/**
 * Android's own mDNS responder for the bridge. The system daemon owns port
 * 5353, so registering through it is heard where a second responder
 * sharing the port may not be. Registers one service at a time, and
 * browses `_hue._tcp` for the client side, resolving one service at a time
 * as older Android versions require.
 */
class NsdBridge(context: Context) {
    private val manager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val main = Handler(Looper.getMainLooper())
    private var registration: NsdManager.RegistrationListener? = null

    fun register(name: String, type: String, port: Int, txt: Map<String, String>, result: MethodChannel.Result) {
        unregister()
        val info = NsdServiceInfo().apply {
            serviceName = name
            serviceType = type
            this.port = port
            for ((key, value) in txt) setAttribute(key, value)
        }
        var answered = false
        fun answer(block: () -> Unit) {
            main.post {
                if (!answered) {
                    answered = true
                    block()
                }
            }
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) = answer { result.success(null) }

            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                main.post { if (registration === this) registration = null }
                answer { result.error("failed", "NsdManager error $errorCode", null) }
            }

            override fun onServiceUnregistered(info: NsdServiceInfo) {}

            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {}
        }
        registration = listener
        try {
            manager.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (e: Exception) {
            registration = null
            answer { result.error("failed", e.toString(), null) }
        }
    }

    fun unregister() {
        val listener = registration ?: return
        registration = null
        try {
            manager.unregisterService(listener)
        } catch (_: Exception) {
        }
    }

    fun browse(type: String, windowMs: Long, result: MethodChannel.Result) {
        val found = mutableListOf<Map<String, Any?>>()
        val seen = mutableSetOf<String>()
        val queue = ArrayDeque<NsdServiceInfo>()
        var resolving = false
        var finished = false

        fun next() {
            if (finished || resolving) return
            val info = queue.removeFirstOrNull() ?: return
            resolving = true
            @Suppress("DEPRECATION")
            manager.resolveService(
                info,
                object : NsdManager.ResolveListener {
                    override fun onServiceResolved(resolved: NsdServiceInfo) {
                        main.post {
                            resolving = false
                            hostOf(resolved)?.let { host ->
                                found.add(
                                    mapOf(
                                        "host" to host,
                                        "port" to resolved.port,
                                        "txt" to resolved.attributes.mapValues { (_, v) -> v?.toString(Charsets.UTF_8) },
                                    ),
                                )
                            }
                            next()
                        }
                    }

                    override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                        main.post {
                            resolving = false
                            next()
                        }
                    }
                },
            )
        }

        val discovery = object : NsdManager.DiscoveryListener {
            override fun onServiceFound(info: NsdServiceInfo) {
                main.post {
                    if (seen.add(info.serviceName)) {
                        queue.addLast(info)
                        next()
                    }
                }
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                main.post {
                    if (!finished) {
                        finished = true
                        result.error("failed", "NsdManager discovery error $errorCode", null)
                    }
                }
            }

            override fun onDiscoveryStarted(serviceType: String) {}

            override fun onDiscoveryStopped(serviceType: String) {}

            override fun onServiceLost(info: NsdServiceInfo) {}

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
        }
        try {
            manager.discoverServices(type, NsdManager.PROTOCOL_DNS_SD, discovery)
        } catch (e: Exception) {
            result.error("failed", e.toString(), null)
            return
        }
        main.postDelayed({
            try {
                manager.stopServiceDiscovery(discovery)
            } catch (_: Exception) {
            }
            if (!finished) {
                finished = true
                result.success(found.toList())
            }
        }, windowMs)
    }

    private fun hostOf(info: NsdServiceInfo): String? {
        if (Build.VERSION.SDK_INT >= 34) {
            val addresses = info.hostAddresses
            return (addresses.firstOrNull { it is Inet4Address } ?: addresses.firstOrNull())?.hostAddress
        }
        @Suppress("DEPRECATION")
        return info.host?.hostAddress
    }
}
