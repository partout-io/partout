// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout

import android.app.Service
import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.ParcelFileDescriptor
import android.util.Log
import io.partout.models.TaggedModuleDNS
import io.partout.models.TaggedModuleHTTPProxy
import io.partout.models.TaggedModuleIP
import io.partout.models.TaggedModuleOnDemand
import io.partout.models.TunnelRemoteInfoWrapper
import io.partout.models.TunnelSnapshot
import io.partout.vpn.DNSModuleApplying
import io.partout.vpn.HTTPProxyModuleApplying
import io.partout.vpn.IPModuleApplying
import io.partout.vpn.OnDemandModuleApplying
import kotlinx.coroutines.CancellationException
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
    private val engine: Engine
) {
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val commandMutex = Mutex()
    private var descriptor: ParcelFileDescriptor? = null
    private var isRunning = false
    private var latestSnapshot: TunnelSnapshot? = null

    // Service lifecycle

    @Suppress("UNUSED_PARAMETER")
    fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.i(logTag, "PartoutVpnServiceRuntime.onStartCommand()")
        if (intent?.action == ACTION_STOP_VPN) {
            disconnect()
            return Service.START_NOT_STICKY
        }
        connect(intent)
        return Service.START_STICKY
    }

    fun onDestroy() {
        Log.i(logTag, "PartoutVpnServiceRuntime.onDestroy()")
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
        Log.i(logTag, "PartoutVpnServiceRuntime.onRevoke()")
        disconnect()
    }

    // Actions

    private suspend fun loadOrPersistProfile(intent: Intent?): String {
        val json = intent?.getStringExtra(EXTRA_PROFILE_JSON)
        if (json.isNullOrBlank()) {
            Log.i(logTag, "No profile from VPN start intent, loading last persisted")
            return engine.readLastProfile()
        }
        Log.i(logTag, "Profile from VPN start intent, persisting it")
        engine.writeLastProfile(json)
        return json
    }

    private fun connect(intent: Intent?) = launchCommand {
        val profileJSON = try {
            loadOrPersistProfile(intent)
        } catch (e: Exception) {
            e.throwIfCancellation()
            Log.e(logTag, "Unable to load or persist profile JSON", e)
            stopService()
            return@launchCommand
        }

        // Stop current tunnel if running
        stopTunnel()

        isRunning = true
        Log.i(logTag, "Starting VPN daemon")

        val result = engine.start(this, profileJSON)
        if (result.code != 0) {
            Log.e(logTag, "Unable to start VPN daemon (code=${result.code}): ${result.payload}")
            stopService()
            isRunning = false
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
        sendFinalSnapshot()
    }

    private fun launchCommand(action: suspend () -> Unit) {
        serviceScope.launch {
            commandMutex.withLock {
                try {
                    action()
                } catch (e: Exception) {
                    e.throwIfCancellation()
                    Log.e(logTag, "Unhandled VPN command failure", e)
                    stopService()
                }
            }
        }
    }

    private fun close() {
        serviceScope.cancel()
    }

    // Messaging

    @Suppress("UNUSED_PARAMETER")
    fun onBind(intent: Intent?): IBinder? {
        return messenger.binder
    }

    private val messenger = Messenger(
        object : Handler(Looper.getMainLooper()) {
            override fun handleMessage(msg: Message) {
                when (msg.what) {
                    MSG_GET_STATUS -> {
                        msg.replyTo?.let { replySnapshot(it) }
                    }
                    else -> super.handleMessage(msg)
                }
            }
        }
    )

    private fun replySnapshot(client: Messenger) {
        val snapshotJSON = latestSnapshot?.let {
            json.encodeToString(it)
        }
        val bundle = Bundle().apply {
            snapshotJSON?.let {
                putString(MSG_KEY_SNAPSHOT, it)
            }
        }
        val msg = Message.obtain(null, MSG_GET_STATUS).apply {
            data = bundle
        }
        client.send(msg)
    }

    // WARNING: These methods are called from a JNI background thread

    // JNI
    fun testWorking() {
        Log.d(logTag, "PartoutVpnServiceRuntime.testWorking()")
    }

    // JNI
    fun setTunnel(infoJSON: String): Int {
        Log.d(logTag, "PartoutVpnServiceRuntime.setTunnel()")
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

    // JNI
    fun configureSockets(fds: IntArray) {
        Log.d(logTag, "PartoutVpnServiceRuntime.configureSockets(${fds.toList()})")
        fds.forEach {
            val protected = service.protect(it)
            Log.d(logTag, "protect($it) = $protected")
        }
    }

    // JNI
    fun onSnapshot(snapshotJSON: String) {
        Log.d(logTag, "PartoutVpnServiceRuntime.onSnapshot()")
        val snapshot = json.decodeFromString<TunnelSnapshot>(snapshotJSON)
        sendSnapshot(snapshot)
    }

    // JNI
    fun cancelTunnel(errorMessage: String?) {
        Log.d(logTag, "PartoutVpnServiceRuntime.cancelTunnel()")
        if (errorMessage != null) {
            Log.e(logTag, "VPN daemon cancelled: $errorMessage")
        } else {
            Log.i(logTag, "VPN daemon cancelled")
        }
        disconnect()
    }

    // Broadcasts emitters

    private fun sendSnapshot(snapshot: TunnelSnapshot) {
        Log.d(logTag, "Report daemon snapshot: $snapshot")
        val intent = Intent(ACTION_SNAPSHOT).apply {
            setPackage(service.packageName)
            putExtra(EXTRA_SNAPSHOT_JSON, json.encodeToString(snapshot))
        }
        service.sendBroadcast(intent)
        latestSnapshot = snapshot
    }

    private fun sendFinalSnapshot() {
        latestSnapshot?.let {
            sendSnapshot(it.disabled())
        }
    }

    // Helpers

    data class Result(
        val code: Int,
        val payload: String?
    )

    interface Engine {
        suspend fun start(runtime: PartoutVpnServiceRuntime, profileJSON: String): Result
        suspend fun stop(): Result
        suspend fun readLastProfile(): String
        suspend fun writeLastProfile(json: String)
    }

    private fun stopService() {
        service.stopSelf()
    }

    private fun TunnelSnapshot.disabled() = TunnelSnapshot(
        id,
        false,
        false,
        status,
        environment
    )

    private fun Exception.throwIfCancellation() {
        if (this is CancellationException) {
            throw this
        }
    }

    companion object {
        const val ACTION_STOP_VPN = "io.partout.action.STOP_VPN"
        const val ACTION_SNAPSHOT = "io.partout.action.SNAPSHOT"
        const val EXTRA_PROFILE_ID = "io.partout.extra.PROFILE_ID"
        const val EXTRA_PROFILE_JSON = "io.partout.extra.PROFILE_JSON"
        const val EXTRA_SNAPSHOT_JSON = "io.partout.extra.SNAPSHOT_JSON"

        const val MSG_GET_STATUS = 1
        const val MSG_KEY_SNAPSHOT = "snapshot"

        private val json = Json {
            ignoreUnknownKeys = true
        }
    }
}
