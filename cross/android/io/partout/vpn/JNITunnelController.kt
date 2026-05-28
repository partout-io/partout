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
import kotlinx.coroutines.CoroutineScope
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json

// Must match signatures in tun_android.c
interface TunnelController {
    // Runtime
    fun stopObserving()

    // JNI -> Jotlin
    fun setDelegate(delegate: Long): Long
    fun setTunnel(infoJSON: String): Int
    fun configureSockets(fds: IntArray)
    fun onSnapshot(snapshotJSON: String)
    fun cancelTunnel(errorCode: String?)

    // Kotlin -> JNI
    fun onReachabilityUpdate(isReachable: Boolean)
    fun onBetterPathUpdate()
    fun getEnvironmentValue(key: String): String?
}

interface TunnelControllerDelegate {
    fun sendSnapshot(snapshot: TunnelSnapshot)
    fun disconnect()
}

class JNITunnelController(
    private val logTag: String,
    private val service: VpnService,
    private val delegate: TunnelControllerDelegate,
    scope: CoroutineScope
) : TunnelController {
    // All accesses must be synchronized against the lock
    private val lock = Any()

    // JNI interactions with Native (Swift)
    private var nativeDelegate: Long = 0
    private var isNativeCancelled = false
    private var tunDescriptor: ParcelFileDescriptor? = null

    override fun stopObserving() {
    }

    override fun setDelegate(delegate: Long): Long = synchronized(lock) {
        Log.d(logTag, "setDelegate($delegate)")
        val oldDelegate = nativeDelegate
        nativeDelegate = delegate
        return oldDelegate
    }

    override fun setTunnel(infoJSON: String): Int = synchronized(lock) {
        if (isNativeCancelled) { return -1 }
        Log.d(logTag, "setTunnel()")
        if (tunDescriptor != null) {
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

        // IMPORTANT: this is a requirement for VirtualTunnelInterface.
        // By default, establish() returns a non-blocking descriptor.
        builder.setBlocking(true)

        tunDescriptor = try {
            builder.establish()
        } catch (e: RuntimeException) {
            Log.e(logTag, "Unable to establish tunnel", e)
            null
        }
        if (tunDescriptor == null) {
            Log.e(logTag, "Unable to establish tunnel")
            return -1
        }

        val fd = tunDescriptor?.detachFd() ?: -1
        tunDescriptor = null
        Log.i(logTag, "Established tunnel descriptor: $fd")
        return fd
    }

    override fun configureSockets(fds: IntArray) = synchronized(lock) {
        if (isNativeCancelled) { return }
        Log.d(logTag, "configureSockets(${fds.toList()})")
        fds.forEach {
            require(it in 0..Int.MAX_VALUE.toLong()) {
                "Invalid Android file descriptor: $it"
            }
            val protected = service.protect(it.toInt())
            Log.d(logTag, "protect($it) = $protected")
        }
    }

    override fun onSnapshot(snapshotJSON: String) = synchronized(lock) {
        if (isNativeCancelled) { return }
        Log.d(logTag, "onSnapshot(${snapshotJSON})")
        val snapshot = json.decodeFromString<TunnelSnapshot>(snapshotJSON)
        delegate?.sendSnapshot(snapshot)
        return@synchronized
    }

    override fun cancelTunnel(errorCode: String?) = synchronized(lock) {
        if (isNativeCancelled) { return }
        isNativeCancelled = true
        Log.d(logTag, "cancelTunnel()")
        if (errorCode != null) {
            Log.e(logTag, "VPN daemon cancelled: $errorCode")
        } else {
            Log.i(logTag, "VPN daemon cancelled")
        }
        delegate?.disconnect()
        return@synchronized
    }

    override fun onReachabilityUpdate(isReachable: Boolean) = synchronized(lock) {
        Log.e(logTag, ">>> Network: onReachabilityUpdate($isReachable)")
        onNativeReachabilityUpdate(nativeDelegate, isReachable)
    }

    override fun onBetterPathUpdate() = synchronized(lock) {
        Log.e(logTag, ">>> Network: onBetterPathUpdate()")
        onNativeBetterPathUpdate(nativeDelegate)
    }

    override fun getEnvironmentValue(key: String): String? = synchronized(lock) {
        Log.d(logTag, "getEnvironmentValue($key)")
        return getNativeEnvironmentValue(nativeDelegate, key)
    }

    private external fun onNativeReachabilityUpdate(delegate: Long, isReachable: Boolean)
    private external fun onNativeBetterPathUpdate(delegate: Long)
    private external fun getNativeEnvironmentValue(delegate: Long, key: String): String?

    companion object {
        private val json = Json {
            ignoreUnknownKeys = true
        }
    }
}
