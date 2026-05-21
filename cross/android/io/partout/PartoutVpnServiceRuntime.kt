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
import android.util.Log
import io.partout.models.TunnelSnapshot
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json

class PartoutVpnServiceRuntime(
    private val logTag: String,
    private val service: VpnService,
    private val engine: Engine
) {
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val commandMutex = Mutex()
    private var latestSnapshot: TunnelSnapshot? = null
    private var isRunning = false

    //region Lifecycle
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
        if (!isRunning) {
            close()
            return
        }
        launchCommand {
            stopTunnel()
            close()
        }
    }

    fun onRevoke() {
        Log.i(logTag, "PartoutVpnServiceRuntime.onRevoke()")
        disconnect()
    }
    //endregion

    //region Actions (Service)
    private fun connect(intent: Intent?) = launchCommand {
        val profileJSON = try {
            loadOrPersistProfile(intent)
        } catch (e: Exception) {
            e.throwIfCancellation()
            Log.e(logTag, "Unable to load profile JSON", e)
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

    fun sendSnapshot(snapshot: TunnelSnapshot) = launchCommand {
        Log.d(logTag, "Report daemon snapshot: $snapshot")
        val intent = Intent(ACTION_SNAPSHOT).apply {
            setPackage(service.packageName)
            putExtra(EXTRA_SNAPSHOT_JSON, json.encodeToString(snapshot))
        }
        service.sendBroadcast(intent)
        latestSnapshot = snapshot
    }

    fun disconnect() = launchCommand {
        stopTunnel()
        stopService()
    }
    //endregion

    //region Action helpers
    private suspend fun loadOrPersistProfile(intent: Intent?): String {
        val json = intent?.getStringExtra(EXTRA_PROFILE_JSON)
        if (json.isNullOrBlank()) {
            Log.i(logTag, "No profile from VPN start intent, loading last persisted")
            return engine.readLastProfile()
        }
        Log.i(logTag, "Profile from VPN start intent, persisting it")
        try {
            engine.writeLastProfile(json)
        } catch (e: Exception) {
            e.throwIfCancellation()
            Log.w(logTag, "Unable to persist profile JSON, continuing with intent profile", e)
        }
        return json
    }

    private suspend fun sendFinalSnapshot() {
        val latest = commandMutex.withLock {
            latestSnapshot
        }
        latest?.let {
            sendSnapshot(it.disabled())
        }
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

    private fun stopService() {
        service.stopSelf()
    }

    private fun close() {
        serviceScope.cancel()
    }
    //endregion

    //region Messaging
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
    //endregion

    //region Engine
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
    //endregion

    //region Generic helpers
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
    //endregion

    //region Constants
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
    //endregion
}
