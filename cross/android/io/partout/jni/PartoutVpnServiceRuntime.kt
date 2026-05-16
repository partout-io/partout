// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.jni

import android.app.Service
import android.content.Intent
import android.net.VpnService
import android.os.ParcelFileDescriptor
import android.util.Log
import io.partout.abi.ConnectionStatus
import io.partout.abi.OnConnectionStatus
import io.partout.abi.TaggedModuleDNS
import io.partout.abi.TaggedModuleHTTPProxy
import io.partout.abi.TaggedModuleIP
import io.partout.abi.TaggedModuleOnDemand
import io.partout.abi.TaggedProfile
import io.partout.abi.TunnelRemoteInfoWrapper
import io.partout.abi.TunnelSnapshot
import io.partout.abi.TunnelStatus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json

class PartoutVpnServiceRuntime(
    private val logTag: String,
    private val service: VpnService,
    private val engine: Engine,
    private val stopService: () -> Unit,
) {
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val commandMutex = Mutex()
    private var descriptor: ParcelFileDescriptor? = null
    private var isRunning = false
    private var profileId: String? = null
    @Volatile
    private var enabledProfileId: String? = null

    // Service lifecycle

    @Suppress("UNUSED_PARAMETER")
    fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP_VPN) {
            disconnect()
            return Service.START_NOT_STICKY
        }
        val profileJSON = intent?.getStringExtra(EXTRA_PROFILE_JSON)
        if (profileJSON.isNullOrBlank()) {
            Log.e(logTag, "Missing profile in VPN start intent")
            stopService()
            return Service.START_NOT_STICKY
        }
        connect(profileJSON)
        return Service.START_STICKY
    }

    fun onDestroy() {
        if (isRunning) {
            launchCommand {
                stopTunnel()
                close()
            }
        } else {
            close()
        }
    }

    fun onRevoke() {
        Log.i(logTag, "VPN permission revoked")
        disconnect()
    }

    // Actions

    private fun connect(profileJSON: String) = launchCommand {
        stopTunnel()

        profileId = runCatching {
            json.decodeFromString<TaggedProfile>(profileJSON).id
        }.getOrNull()
        isRunning = true
        setEnabledProfile(profileId)

        Log.i(logTag, "Starting VPN daemon")

        val result = engine.start(this, profileJSON)
        if (result.code != 0) {
            Log.e(logTag, "Unable to start VPN daemon (code=${result.code}): ${result.payload}")
            stopService()
            isRunning = false
            setEnabledProfile(null)
            profileId = null
            return@launchCommand
        }
        Log.i(logTag, "Started VPN daemon")
    }

    private fun disconnect() = launchCommand {
        stopTunnel()
        stopService()
    }

    private suspend fun stopTunnel() {
        if (!isRunning) { return }

        Log.i(logTag, "Stopping VPN daemon")
        val result = engine.stop()
        if (result.code == 0) {
            Log.i(logTag, "Stopped VPN daemon")
        } else {
            Log.e(logTag, "Unable to stop VPN daemon (code=${result.code}): ${result.payload}")
        }
        isRunning = false
        setEnabledProfile(null)
        profileId = null
    }

    private fun launchCommand(action: suspend () -> Unit) {
        serviceScope.launch {
            commandMutex.withLock {
                action()
            }
        }
    }

    private fun close() {
        serviceScope.cancel()
    }

    // WARNING: These methods are called from a JNI background thread

    // JNI
    fun testWorking() {
        Log.d(logTag, "PartoutVpnServiceRuntime: working")
    }

    // JNI
    fun setTunnel(infoJSON: String): Int {
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
            val protected = service.protect(it)
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

    // JNI
    fun configureSockets(fds: IntArray) {
        Log.d(logTag, "Configuring sockets: ${fds.toList()}")
        fds.forEach {
            val protected = service.protect(it)
            Log.d(logTag, "protect($it) = $protected")
        }
    }

    // JNI
    fun onStatus(statusJSON: String) {
        val status = json.decodeFromString<OnConnectionStatus>(statusJSON)
        Log.i(logTag, "VPN status: $status")
        sendSnapshot(TunnelSnapshot(
            id = status.profileId,
            isEnabled = enabledProfileId == status.profileId,
            onDemand = false,
            status = status.status.toTunnelStatus()
        ))
    }

    // Broadcasts emitters

    private fun setEnabledProfile(profileId: String?) {
        enabledProfileId = profileId
        if (profileId == null) {
            sendSnapshot(null)
        }
    }

    private fun sendSnapshot(snapshot: TunnelSnapshot?) {
        val snapshots = if (snapshot == null || !snapshot.isEnabled) {
            emptyMap()
        } else {
            mapOf(snapshot.id to snapshot)
        }
        val intent = Intent(ACTION_SNAPSHOTS).apply {
            setPackage(service.packageName)
            putExtra(EXTRA_SNAPSHOTS_JSON, json.encodeToString(snapshots))
        }
        service.sendBroadcast(intent)
    }

    private fun ConnectionStatus.toTunnelStatus(): TunnelStatus = when (this) {
        ConnectionStatus.disconnected -> TunnelStatus.inactive
        ConnectionStatus.connecting -> TunnelStatus.activating
        ConnectionStatus.connected -> TunnelStatus.active
        ConnectionStatus.disconnecting -> TunnelStatus.deactivating
    }

    // Nested classes

    data class Result(
        val code: Int,
        val payload: String?
    )

    interface Engine {
        suspend fun start(runtime: PartoutVpnServiceRuntime, profileJSON: String): Result

        suspend fun stop(): Result
    }

    companion object {
        const val ACTION_STOP_VPN = "io.partout.jni.action.STOP_VPN"
        const val ACTION_SNAPSHOTS = "io.partout.jni.action.SNAPSHOTS"
        const val EXTRA_PROFILE_ID = "io.partout.jni.extra.PROFILE_ID"
        const val EXTRA_PROFILE_JSON = "io.partout.jni.extra.PROFILE_JSON"
        const val EXTRA_SNAPSHOTS_JSON = "io.partout.jni.extra.SNAPSHOTS_JSON"

        private val json = Json {
            ignoreUnknownKeys = true
        }
    }
}
