package io.partout.vpn

import android.net.Network
import android.net.VpnService
import android.os.ParcelFileDescriptor
import android.util.Log
import io.partout.NativeTunnelControllerJNI
import io.partout.models.TaggedModuleDNS
import io.partout.models.TaggedModuleHTTPProxy
import io.partout.models.TaggedModuleIP
import io.partout.models.TaggedModuleOnDemand
import io.partout.models.TunnelRemoteInfoWrapper
import io.partout.models.TunnelSnapshot
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json

// Kotlin -> JNI -> C
internal interface NativeTunnelController {
    fun onReachabilityUpdate(info: NetworkInfo)
    fun getEnvironmentValue(key: String): String?
}

// Called by the runtime
internal interface TunnelController: NativeTunnelController, NativeTunnelControllerJNI {
    fun startObserving()
    fun stopObserving()
}

// Delegated to the runtime
internal interface TunnelControllerDelegate {
    fun onSnapshot(snapshot: TunnelSnapshot)
    fun shouldDisconnect(controller: NativeTunnelControllerJNI)
}

internal class JNITunnelController(
    private val logTag: String,
    private val service: VpnService,
    private val scope: CoroutineScope,
    private val delegate: TunnelControllerDelegate
) : TunnelController {
    //region State
    // All accesses must be synchronized against the lock
    private val lock = Any()

    // JNI interactions with Native (Swift)
    private var nativeDelegate: Long = 0
    private var isNativeCancelled = false

    // Network observers
    private val reachabilityObserver = ReachabilityObserver(service)
    private var reachabilityJob: Job? = null
    private var betterPathJob: Job? = null
    private var networkInfo = NetworkInfo.empty
    private var lastEmittedNetwork: Network? = null
    private var lastEmittedNetworkPreference: NetworkPathPreference? = null

    // Retain tun across reconnections
    private var tunDescriptor: ParcelFileDescriptor? = null
    //endregion

    //region Lifecycle
    override fun startObserving() {
        reachabilityJob = reachabilityObserver
            .flow()
            .onEach { onReachabilityUpdate(it) }
            .launchIn(scope)
    }

    override fun stopObserving() {
        reachabilityJob?.cancel()
        reachabilityJob = null
        cancelBetterPathUpdate()
    }
    //endregion

    //region NativeTunnelControllerJNI
    override fun setDelegate(delegate: Long): Long = synchronized(lock) {
        Log.d(logTag, "setDelegate($delegate)")
        val oldDelegate = nativeDelegate
        nativeDelegate = delegate
        if (delegate != 0L) {
            val selection = networkInfo.reachabilitySelection()
            emitReachabilityUpdate(selection)
            rememberEmittedNetwork(selection)
        } else {
            clearEmittedNetwork()
            cancelBetterPathUpdate()
        }
        return oldDelegate
    }

    override fun setTunnel(infoJSON: String): Int = synchronized(lock) {
        if (isNativeCancelled) { return INVALID_TUN_FD }
        Log.d(logTag, "setTunnel()")

        // Decode info modules
        val builder = service.Builder()
        val info = runCatching {
            json.decodeFromString<TunnelRemoteInfoWrapper>(infoJSON)
        }.getOrElse {
            Log.e(logTag, "Unable to decode tunnel info JSON", it)
            return@synchronized INVALID_TUN_FD
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
            Log.e(logTag, "Unable to set interface address")
            return INVALID_TUN_FD
        }

        // IMPORTANT: By default, establish() returns a non-blocking descriptor.
        val newDescriptor = runCatching {
            builder.establish()
        }.getOrElse {
            Log.e(logTag, "Unable to establish tunnel", it)
            null
        }
        if (newDescriptor == null) {
            Log.e(logTag, "Unable to establish tunnel, null descriptor")
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
            require(it >= 0) {
                "Invalid Android file descriptor: $it"
            }
            val protected = service.protect(it)
            Log.d(logTag, "protect($it) = $protected")
            if (!protected) {
                throw IllegalStateException("Unable to protect Android file descriptor: $it")
            }
        }
    }

    override fun onSnapshot(snapshotJSON: String) = synchronized(lock) {
        if (isNativeCancelled) { return }
        Log.d(logTag, "onSnapshot(${snapshotJSON})")
        val snapshot = json.decodeFromString<TunnelSnapshot>(snapshotJSON)
        delegate.onSnapshot(snapshot)
        return@synchronized
    }

    override fun clearTunnel(killSwitch: Boolean) = synchronized(lock) {
        if (isNativeCancelled) { return }

        // Optionally replace with catch-all fake tun
        if (killSwitch) {
            val builder = service.Builder().setUpKillSwitch()
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
        cancelBetterPathUpdate()

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

        // Request disconnection from delegate (runtime)
        delegate.shouldDisconnect(this)
        return@synchronized
    }
    //endregion

    //region NativeTunnelController
    override fun onReachabilityUpdate(info: NetworkInfo) = synchronized(lock) {
        networkInfo = info
        val selection = info.reachabilitySelection()
        emitReachabilityUpdate(selection)
        if (selection.isBetterThanLastEmitted()) {
            scheduleBetterPathUpdate(selection)
        } else {
            cancelBetterPathUpdate()
        }
        rememberEmittedNetwork(selection)
    }

    override fun getEnvironmentValue(key: String): String? = synchronized(lock) {
        Log.d(logTag, "getEnvironmentValue($key)")
        return getNativeEnvironmentValue(nativeDelegate, key)
    }
    //endregion

    //region Reachability
    private data class ReachabilitySelection(
        val network: Network?,
        val preference: NetworkPathPreference?
    ) {
        val networkHandle: Long?
            get() = network?.networkHandle
    }

    // Signatures in tun_android.c MUST MATCH!
    private external fun onNativeReachabilityUpdate(delegate: Long, networkHandle: Long)
    private external fun onNativeBetterPathUpdate(delegate: Long)
    private external fun getNativeEnvironmentValue(delegate: Long, key: String): String?

    private fun NetworkInfo.reachabilitySelection(): ReachabilitySelection {
        val currentNetwork = bestNetworks().firstOrNull()
        return ReachabilitySelection(
            network = currentNetwork,
            preference = preferenceFor(currentNetwork)
        )
    }

    private fun ReachabilitySelection.isBetterThanLastEmitted(): Boolean {
        val currentPreference = preference ?: return false
        val previousPreference = lastEmittedNetworkPreference ?: return false
        if (lastEmittedNetwork == null) {
            return false
        }
        return currentPreference > previousPreference
    }

    private fun emitReachabilityUpdate(selection: ReachabilitySelection) {
        Log.d(logTag, "Reachability: onReachabilityUpdate(${selection.networkHandle})")
        onNativeReachabilityUpdate(
            nativeDelegate,
            selection.networkHandle ?: INVALID_NETWORK_HANDLE
        )
    }

    private fun emitBetterPathUpdate(selection: ReachabilitySelection) {
        Log.d(logTag, "Reachability: onBetterPathUpdate(${selection.networkHandle})")
        onNativeBetterPathUpdate(nativeDelegate)
    }

    private fun scheduleBetterPathUpdate(selection: ReachabilitySelection) {
        betterPathJob?.cancel()
        betterPathJob = scope.launch {
            delay(BETTER_PATH_DELAY_MS)
            synchronized(lock) {
                if (!isNativeCancelled &&
                    nativeDelegate != 0L &&
                    selection == networkInfo.reachabilitySelection()
                ) {
                    emitBetterPathUpdate(selection)
                }
                betterPathJob = null
            }
        }
    }

    private fun cancelBetterPathUpdate() {
        betterPathJob?.cancel()
        betterPathJob = null
    }

    private fun rememberEmittedNetwork(selection: ReachabilitySelection) {
        if (nativeDelegate == 0L) {
            return
        }
        lastEmittedNetwork = selection.network
        lastEmittedNetworkPreference = selection.preference
    }

    private fun clearEmittedNetwork() {
        lastEmittedNetwork = null
        lastEmittedNetworkPreference = null
    }
    //endregion

    private fun VpnService.Builder.setUpKillSwitch(): VpnService.Builder {
        addAddress("192.0.2.1", 32)
        addAddress("fd00::1", 128)
        addRoute("0.0.0.0", 0)
        addRoute("::", 0)
        return this
    }

    companion object {
        private const val INVALID_TUN_FD = -1
        private const val INVALID_NETWORK_HANDLE = -1L
        private const val BETTER_PATH_DELAY_MS = 300L

        private val json = Json {
            ignoreUnknownKeys = true
        }
    }
}
