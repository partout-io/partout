// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.vpn

import android.net.VpnService
import android.os.ParcelFileDescriptor
import android.util.Log
import io.partout.models.TaggedModuleDNS
import io.partout.models.TaggedModuleHTTPProxy
import io.partout.models.TaggedModuleIP
import io.partout.models.TaggedModuleOnDemand
import io.partout.models.TunnelRemoteInfoWrapper
import io.partout.models.TunnelSnapshot
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json

// Must match signatures in tun_android.c
interface TunnelController {
    fun testWorking()
    fun setTunnel(infoJSON: String): Int
    fun configureSockets(fds: IntArray)
    fun onSnapshot(snapshotJSON: String)
    fun cancelTunnel(errorMessage: String?)
}

class JNITunnelController(
    private val logTag: String,
    private val service: VpnService,
    private val sendSnapshot: (TunnelSnapshot) -> Unit,
    private val disconnect: () -> Unit
): TunnelController {
    private var descriptor: ParcelFileDescriptor? = null

    override fun testWorking() {
        Log.d(logTag, "JNITunnelController.testWorking()")
    }

    override fun setTunnel(infoJSON: String): Int {
        Log.d(logTag, "JNITunnelController.setTunnel()")
        if (descriptor != null) {
            Log.e(logTag, "Tunnel descriptor already established")
            return -1
        }

        val builder = service.Builder()
        val info: TunnelRemoteInfoWrapper = try {
            json.decodeFromString(infoJSON)
        } catch (e: SerializationException) {
            Log.e(logTag, "Unable to decode tunnel info JSON", e)
            return -1
        }
        val remoteFds = info.fileDescriptors
        var appliedAddressSettings = false
        var appliedDnsSettings = false

        info.modules?.forEach {
            when (it) {
                is TaggedModuleDNS -> {
                    Log.i(logTag, "DNS: ${it.value}")
                    appliedDnsSettings = DNSModuleApplying(it.value).apply(logTag, builder)
                            || appliedDnsSettings
                }

                is TaggedModuleIP -> {
                    Log.i(logTag, "IP: ${it.value}")
                    appliedAddressSettings = IPModuleApplying(it.value).apply(logTag, builder)
                            || appliedAddressSettings
                }

                is TaggedModuleHTTPProxy -> {
                    Log.i(logTag, "HTTP Proxy: ${it.value}")
                    HTTPProxyModuleApplying(it.value).apply(logTag, builder)
                }

                is TaggedModuleOnDemand -> {
                    Log.i(logTag, "OnDemand: ${it.value}")
                    OnDemandModuleApplying(it.value).apply(logTag, builder)
                }

                else -> {}
            }
        }

        if (!appliedAddressSettings) {
            Log.e(logTag, "No valid interface address")
            return -1
        }

        remoteFds.forEach {
            require(it in 0..Int.MAX_VALUE.toLong()) {
                "Invalid Android file descriptor: $it"
            }
            val protected = service.protect(it.toInt())
            Log.d(logTag, "protect($it) = $protected")
        }

        // IMPORTANT: this is a requirement for VirtualTunnelInterface.
        // By default, establish() returns a non-blocking descriptor.
        builder.setBlocking(true)

        descriptor = try {
            builder.establish()
        } catch (e: RuntimeException) {
            Log.e(logTag, "Unable to establish tunnel", e)
            null
        }
        if (descriptor == null) {
            Log.e(logTag, "Unable to establish tunnel")
            return -1
        }

        val fd = descriptor?.detachFd() ?: -1
        descriptor = null
        Log.i(logTag, "Established tunnel descriptor: $fd")
        return fd
    }

    override fun configureSockets(fds: IntArray) {
        Log.d(logTag, "JNITunnelController.configureSockets(${fds.toList()})")
        fds.forEach {
            val protected = service.protect(it)
            Log.d(logTag, "protect($it) = $protected")
        }
    }

    override fun onSnapshot(snapshotJSON: String) {
        Log.d(logTag, "JNITunnelController.onSnapshot()")
        val snapshot = json.decodeFromString<TunnelSnapshot>(snapshotJSON)
        sendSnapshot(snapshot)
    }

    override fun cancelTunnel(errorMessage: String?) {
        Log.d(logTag, "JNITunnelController.cancelTunnel()")
        if (errorMessage != null) {
            Log.e(logTag, "VPN daemon cancelled: $errorMessage")
        } else {
            Log.i(logTag, "VPN daemon cancelled")
        }
        disconnect()
    }

    companion object {
        private val json = Json {
            ignoreUnknownKeys = true
        }
    }
}