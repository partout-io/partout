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
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json

// Must match signatures in tun_android.c
interface TunnelController {
    // Runtime
    fun startObserving()
    fun stopObserving()

    // JNI -> Jotlin
    fun setDelegate(delegate: Long): Long
    fun setTunnel(infoJSON: String): Int
    fun configureSockets(fds: IntArray)
    fun onSnapshot(snapshotJSON: String)
    fun clearTunnel(killSwitch: Boolean)
    fun cancelTunnel(errorCode: String?)

    // Kotlin -> JNI
    fun onReachabilityUpdate(info: NetworkInfo)
    fun getEnvironmentValue(key: String): String?
}

interface TunnelControllerDelegate {
    fun sendSnapshot(snapshot: TunnelSnapshot)
    fun disconnect()
}

class JNITunnelController(
    private val logTag: String,
    private val service: VpnService,
    private val scope: CoroutineScope,
    private val delegate: TunnelControllerDelegate
) : TunnelController {
    // All accesses must be synchronized against the lock
    private val lock = Any()

    // JNI interactions with Native (Swift)
    private var nativeDelegate: Long = 0
    private var isNativeCancelled = false

    // Network observers
    private val reachabilityObserver = ReachabilityObserver(service)
    private var reachabilityJob: Job? = null
    private var networkInfo = NetworkInfo.empty

    // Retain tun across reconnections
    private var tunDescriptor: ParcelFileDescriptor? = null

    override fun startObserving() {
        reachabilityJob = reachabilityObserver
            .flow()
            .onEach { onReachabilityUpdate(it) }
            .launchIn(scope)
    }

    override fun stopObserving() {
        reachabilityJob?.cancel()
        reachabilityJob = null
    }

    override fun setDelegate(delegate: Long): Long = synchronized(lock) {
        Log.d(logTag, "setDelegate($delegate)")
        val oldDelegate = nativeDelegate
        nativeDelegate = delegate
        if (delegate != 0L) {
            onNativeReachabilityUpdate(
                delegate,
                networkInfo.bestNetworks().firstOrNull()?.networkHandle ?: INVALID_NETWORK_HANDLE
            )
        }
        return oldDelegate
    }

    override fun setTunnel(infoJSON: String): Int = synchronized(lock) {
        if (isNativeCancelled) { return INVALID_TUN_FD }
        Log.d(logTag, "setTunnel()")

        // Decode info modules
        val builder = service.Builder()
        val info: TunnelRemoteInfoWrapper = try {
            json.decodeFromString(infoJSON)
        } catch (e: SerializationException) {
            Log.e(logTag, "Unable to decode tunnel info JSON", e)
            return INVALID_TUN_FD
        }

        // Apply modules to VPN builder
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
            return INVALID_TUN_FD
        }

        // IMPORTANT: By default, establish() returns a non-blocking descriptor.
        val newDescriptor = try {
            builder.establish()
        } catch (e: RuntimeException) {
            Log.e(logTag, "Unable to establish tunnel", e)
            null
        }
        if (newDescriptor == null) {
            Log.e(logTag, "Unable to establish tunnel")
            return INVALID_TUN_FD
        }

        // Close old tun kept as handover kill switch
        if (tunDescriptor != null) {
            Log.d(logTag, "Clear old tun")
            runCatching {
                tunDescriptor?.close()
            }
            tunDescriptor = null
        }

        // Track tun then propagate fd to native layer
        tunDescriptor = newDescriptor
        val fd = newDescriptor.fd
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
            val protected = service.protect(it)
            // FIXME: Throw exception on protect() failure?
            Log.d(logTag, "protect($it) = $protected")
        }
    }

    override fun onSnapshot(snapshotJSON: String) = synchronized(lock) {
        if (isNativeCancelled) { return }
        Log.d(logTag, "onSnapshot(${snapshotJSON})")
        val snapshot = json.decodeFromString<TunnelSnapshot>(snapshotJSON)
        delegate.sendSnapshot(snapshot)
        return@synchronized
    }

    override fun clearTunnel(killSwitch: Boolean) = synchronized(lock) {
        if (isNativeCancelled) { return }

        // Optionally replace with catch-all fake tun
        if (killSwitch) {
            val builder = service.Builder()
            // FIXME: Externalize these constants
            builder.addAddress("192.0.2.1", 32)
            builder.addAddress("fd00::1", 128)
            builder.addRoute("0.0.0.0", 0)
            builder.addRoute("::", 0)
            runCatching {
                val oldDescriptor = tunDescriptor
                val newDescriptor = builder.establish()
                if (newDescriptor == null) {
                    Log.e(logTag, "Unable to set up kill switch")
                    return@synchronized
                }
                tunDescriptor = newDescriptor
                runCatching {
                    oldDescriptor?.close()
                }.onFailure {
                    Log.e(logTag, "Unable to close former tun descriptor", it)
                }
            }.onFailure {
                Log.e(logTag, "Unable to set up kill switch", it)
            }
        }

        return@synchronized
    }

    override fun cancelTunnel(errorCode: String?) = synchronized(lock) {
        if (isNativeCancelled) { return }
        Log.d(logTag, "cancelTunnel()")

        // Prevent further calls
        isNativeCancelled = true

        // Close former tunnel
        runCatching {
            tunDescriptor?.close()
            tunDescriptor = null
        }.onFailure {
            Log.e(logTag, "Unable to close former tun descriptor", it)
        }

        if (errorCode != null) {
            Log.e(logTag, "VPN daemon cancelled: $errorCode")
        } else {
            Log.i(logTag, "VPN daemon cancelled")
        }

        // Signal disconnection to delegate (runtime)
        delegate.disconnect()
        return@synchronized
    }

    override fun onReachabilityUpdate(info: NetworkInfo) = synchronized(lock) {
        networkInfo = info
        val networkHandle = info.bestNetworks().firstOrNull()?.networkHandle
        Log.e(logTag, ">>> Network: onReachabilityUpdate($networkHandle)")
        onNativeReachabilityUpdate(nativeDelegate, networkHandle ?: INVALID_NETWORK_HANDLE)
    }

    override fun getEnvironmentValue(key: String): String? = synchronized(lock) {
        Log.d(logTag, "getEnvironmentValue($key)")
        return getNativeEnvironmentValue(nativeDelegate, key)
    }

    private external fun onNativeReachabilityUpdate(delegate: Long, networkHandle: Long)
    private external fun getNativeEnvironmentValue(delegate: Long, key: String): String?

    companion object {
        private const val INVALID_TUN_FD = -1
        private const val INVALID_NETWORK_HANDLE = -1L

        private val json = Json {
            ignoreUnknownKeys = true
        }
    }
}
