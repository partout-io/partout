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
import io.partout.models.TaggedProfile
import io.partout.models.TunnelSnapshot
import io.partout.vpn.JNITunnelController
import io.partout.vpn.TunnelControllerDelegate
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.onFailure
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json

class PartoutVpnServiceRuntime(
    private val logTag: String,
    private val jniLogTag: String,
    val service: VpnService,
    private val engine: Engine
): TunnelControllerDelegate {
    // Execute actions in serial queue
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val commandQueue = Channel<suspend () -> Unit>(Channel.UNLIMITED)
    private var isRunning = false

    // C/JNI controller
    private var controller: JNITunnelController? = null

    // Deliver snapshots with mutex
    private val snapshotEmitter = SnapshotEmitter(logTag, service)

    init {
        serviceScope.launch {
            for (action in commandQueue) {
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
        val profileId = try {
            decodeProfileId(profileJSON)
        } catch (e: Exception) {
            e.throwIfCancellation()
            Log.e(logTag, "Unable to decode profile JSON", e)
            stopService()
            return@launchCommand
        }

        // Stop current tunnel if running
        stopTunnel()

        // Observe snapshots during start attempt
        snapshotEmitter.accept(profileId)

        isRunning = true
        Log.i(logTag, "Starting VPN daemon")
        try {
            val newController = JNITunnelController(jniLogTag, service, this)
            engine.start(newController, profileJSON)
            controller = newController
            Log.i(logTag, "Started VPN daemon")
        } catch (e: Exception) {
            e.throwIfCancellation()
            Log.e(logTag, "Unable to start VPN daemon", e)
            stopService()
            snapshotEmitter.shutdown()
            isRunning = false
            return@launchCommand
        }
    }

    override fun sendSnapshot(snapshot: TunnelSnapshot) {
        snapshotEmitter.emit(snapshot)
    }

    override fun disconnect() = launchCommand {
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

    private fun decodeProfileId(profileJSON: String): String {
        return json.decodeFromString<TaggedProfile>(profileJSON).id
    }

    private suspend fun stopTunnel() {
        if (!isRunning) { return }
        Log.i(logTag, "Stopping VPN daemon")
        try {
            engine.stop()
            controller = null
        } catch (e: Exception) {
            Log.e(logTag, "Unable to stop VPN daemon", e)
        }
        isRunning = false
        snapshotEmitter.emitFinal()
    }

    private fun stopService() {
        service.stopSelf()
    }

    private fun close() {
        Log.d(logTag, "Cancelling VPN runtime")
        commandQueue.close()
        serviceScope.cancel()
    }
    //endregion

    //region Snapshots
    private class SnapshotEmitter(
        private val logTag: String,
        private val service: Service
    ) {
        private val lock = Any()
        private var isAccepting = false
        private var activeProfileId: String? = null
        @Volatile private var latestSnapshot: TunnelSnapshot? = null

        fun accept(profileId: String) {
            synchronized(lock) {
                isAccepting = true
                activeProfileId = profileId
                latestSnapshot = null
            }
        }

        fun shutdown() {
            synchronized(lock) {
                isAccepting = false
                activeProfileId = null
            }
        }

        fun emit(snapshot: TunnelSnapshot) = synchronized(lock) {
            if (!isAccepting) { return }
            if (snapshot.id != activeProfileId) {
                Log.d(logTag, "Drop stale daemon snapshot: $snapshot")
                return
            }
            broadcast(snapshot)
        }

        fun emitFinal() = synchronized(lock) {
            Log.d(logTag, "Emit final daemon snapshot")
            latestSnapshot?.let {
                emit(it.disabled())
            }
            isAccepting = false
            activeProfileId = null
        }

        fun latest(): TunnelSnapshot? = synchronized(lock) {
            latestSnapshot
        }

        private fun broadcast(snapshot: TunnelSnapshot) {
            Log.d(logTag, "Emit daemon snapshot: $snapshot")
            val intent = Intent(ACTION_SNAPSHOT).apply {
                setPackage(service.packageName)
                putExtra(EXTRA_SNAPSHOT_JSON, json.encodeToString(snapshot))
            }
            latestSnapshot = snapshot
            service.sendBroadcast(intent)
        }

        private fun TunnelSnapshot.disabled() = TunnelSnapshot(
            id,
            false,
            false,
            status,
            environment
        )
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
                        msg.replyTo?.let { client ->
                            launchCommand {
                                replySnapshot(client)
                            }
                        }
                    }
                    MSG_GET_ENVIRONMENT -> {
                        val reqId = msg.arg1
                        val name = msg.data?.getString(MSG_KEY_ENV_NAME)
                        if (name == null) {
                            assert(false)
                            return
                        }
                        msg.replyTo?.let { client ->
                            launchCommand {
                                replyEnvironmentValue(client, reqId, name)
                            }
                        }
                    }
                    else -> super.handleMessage(msg)
                }
            }
        }
    )

    private fun replySnapshot(client: Messenger) {
        val snapshotJSON = snapshotEmitter.latest()?.let {
            json.encodeToString(it)
        }
        val msg = Message.obtain(null, MSG_GET_STATUS).apply {
            data = Bundle().apply {
                snapshotJSON?.let {
                    putString(MSG_KEY_JSON, it)
                }
            }
        }
        try {
            client.send(msg)
        } catch (e: Exception) {
            Log.w(logTag, "Unable to reply with VPN snapshot", e)
        }
    }

    private fun replyEnvironmentValue(client: Messenger, reqId: Int, name: String) {
        val currentController = controller
        if (currentController == null) { return }
        val value = currentController.environmentValue(name)
        Log.i(logTag, "Reply with environment: $name = $value")
        val msg = Message.obtain(null, MSG_GET_ENVIRONMENT).apply {
            arg1 = reqId
            data = Bundle().apply {
                putString(MSG_KEY_ENV_NAME, name)
                putString(MSG_KEY_JSON, value)
            }
        }
        try {
            client.send(msg)
        } catch (e: Exception) {
            Log.w(logTag, "Unable to reply with environment value", e)
        }
    }
    //endregion

    //region Engine
    interface Engine {
        suspend fun start(controller: JNITunnelController, profileJSON: String)
        suspend fun stop()
        suspend fun readLastProfile(): String
        suspend fun writeLastProfile(json: String)
    }
    //endregion

    //region Generic helpers
    private fun launchCommand(action: suspend () -> Unit) {
        commandQueue.trySend(action).onFailure {
            Log.w(logTag, "Unable to enqueue VPN command", it)
        }
    }

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
        const val MSG_GET_ENVIRONMENT = 2
        const val MSG_KEY_JSON = "json"
        const val MSG_KEY_ENV_NAME = "envName"

        private val json = Json {
            ignoreUnknownKeys = true
        }
    }
    //endregion
}
