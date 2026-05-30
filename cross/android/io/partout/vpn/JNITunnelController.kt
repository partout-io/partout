// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.vpn

import android.net.Network
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
    fun cancelTunnel(errorCode: String?)

    // Kotlin -> JNI
    fun onReachabilityUpdate(network: Network?)
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
    private val scope: CoroutineScope,
    private val delegate: TunnelControllerDelegate
) : TunnelController {
    // All accesses must be synchronized against the lock
    private val lock = Any()

    // JNI interactions with Native (Swift)
    private var nativeDelegate: Long = 0
    private var isNativeCancelled = false
    private var tunDescriptor: ParcelFileDescriptor? = null

    // Network observers
    private val reachabilityObserver = ReachabilityObserver(service)
    private var reachabilityJob: Job? = null
    private var reachableNetwork: Network? = null

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
                reachableNetwork?.networkHandle ?: INVALID_NETWORK_HANDLE
            )
        }
        return oldDelegate
    }

    override fun setTunnel(infoJSON: String): Int = synchronized(lock) {
        if (isNativeCancelled) { return INVALID_TUN_FD }
        Log.d(logTag, "setTunnel()")
        if (tunDescriptor != null) {
            Log.e(logTag, "Tunnel descriptor already established")
            return INVALID_TUN_FD
        }

        val builder = service.Builder()
        val info: TunnelRemoteInfoWrapper = try {
            json.decodeFromString(infoJSON)
        } catch (e: SerializationException) {
            Log.e(logTag, "Unable to decode tunnel info JSON", e)
            return INVALID_TUN_FD
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
            return INVALID_TUN_FD
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
            return INVALID_TUN_FD
        }

        val fd = tunDescriptor?.detachFd() ?: INVALID_TUN_FD
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

    override fun cancelTunnel(errorCode: String?) = synchronized(lock) {
        if (isNativeCancelled) { return }
        isNativeCancelled = true
        Log.d(logTag, "cancelTunnel()")
        if (errorCode != null) {
            Log.e(logTag, "VPN daemon cancelled: $errorCode")
        } else {
            Log.i(logTag, "VPN daemon cancelled")
        }
        delegate.disconnect()
        return@synchronized
    }

    override fun onReachabilityUpdate(network: Network?) = synchronized(lock) {
        val networkHandle = network?.networkHandle
        Log.e(logTag, ">>> Network: onReachabilityUpdate($networkHandle)")
        onNativeReachabilityUpdate(nativeDelegate, networkHandle ?: INVALID_NETWORK_HANDLE)
    }

    override fun onBetterPathUpdate() = synchronized(lock) {
        Log.e(logTag, ">>> Network: onBetterPathUpdate()")
        onNativeBetterPathUpdate(nativeDelegate)
    }

    override fun getEnvironmentValue(key: String): String? = synchronized(lock) {
        Log.d(logTag, "getEnvironmentValue($key)")
        return getNativeEnvironmentValue(nativeDelegate, key)
    }

    private external fun onNativeReachabilityUpdate(delegate: Long, networkHandle: Long)
    private external fun onNativeBetterPathUpdate(delegate: Long)
    private external fun getNativeEnvironmentValue(delegate: Long, key: String): String?

    companion object {
        private const val INVALID_TUN_FD = -1
        private const val INVALID_NETWORK_HANDLE = -1L

        private val json = Json {
            ignoreUnknownKeys = true
        }
    }
}
