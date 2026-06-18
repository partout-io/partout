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
import io.partout.models.TunnelStatus
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
    private val engine: Engine,
    logsSnapshots: Boolean
): TunnelControllerDelegate {
    // Execute actions in serial queue
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val commandQueue = Channel<suspend () -> Unit>(Channel.UNLIMITED)
    private var isRunning = false
    private var activeProfileId: String? = null

    // C/JNI controller
    private var controller: JNITunnelController? = null

    // Deliver snapshots with mutex
    private val snapshotEmitter = SnapshotEmitter(
        if (logsSnapshots) logTag else null,
        service
    )

    init {
        serviceScope.launch {
            for (action in commandQueue) {
                runCatching {
                    action()
                }.onFailure {
                    it.throwIfCancellation()
                    Log.e(logTag, "Unhandled VPN command failure", it)
                    stopService()
                }
            }
        }
    }

    //region Lifecycle
    @Suppress("UNUSED_PARAMETER")
    fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(logTag, "PartoutVpnServiceRuntime.onStartCommand()")
        when (intent?.action) {
            ACTION_STOP_VPN -> {
                disconnect(intent)
                return Service.START_NOT_STICKY
            }
        }
        connect(intent)
        return Service.START_STICKY
    }

    fun onDestroy() {
        Log.d(logTag, "PartoutVpnServiceRuntime.onDestroy()")
        launchCommand {
            stopTunnel()
            close()
        }
    }

    fun onRevoke() {
        Log.d(logTag, "PartoutVpnServiceRuntime.onRevoke()")
        disconnect(null)
    }
    //endregion

    //region Actions (Service)
    private fun connect(intent: Intent?) = launchCommand {
        val profileJSON = runCatching {
            loadOrPersistProfile(intent)
        }.getOrElse {
            it.throwIfCancellation()
            Log.e(logTag, "Unable to load profile JSON", it)
            stopService()
            return@launchCommand
        }
        val profileId = runCatching {
            decodeProfileId(profileJSON)
        }.getOrElse {
            it.throwIfCancellation()
            Log.e(logTag, "Unable to decode profile JSON", it)
            stopService()
            return@launchCommand
        }

        // Stop current tunnel if running
        stopTunnel()

        // Observe snapshots during start attempt
        snapshotEmitter.accept(profileId)

        isRunning = true
        activeProfileId = profileId
        Log.i(logTag, "Starting VPN daemon")
        runCatching {
            val newController = JNITunnelController(
                jniLogTag,
                service,
                serviceScope,
                logsSnapshots,
                this
            )
            engine.start(intent, newController, profileJSON)
            // Does not throw from now
            Log.i(logTag, "Started VPN daemon")
            controller = newController
            newController.startObserving()
        }.onFailure {
            snapshotEmitter.emitInactive(profileId)
            controller = null
            isRunning = false
            activeProfileId = null
            it.throwIfCancellation()
            Log.e(logTag, "Unable to start VPN daemon", it)
            stopService()
            return@launchCommand
        }
    }

    override fun onSnapshot(snapshot: TunnelSnapshot) {
        snapshotEmitter.emit(snapshot)
        engine.onSnapshot(snapshot)
    }

    override fun shouldDisconnect(controller: NativeTunnelControllerJNI) = launchCommand {
        if (controller != this.controller) { return@launchCommand }
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
        runCatching {
            engine.writeLastProfile(json)
        }.onFailure {
            it.throwIfCancellation()
            Log.w(logTag, "Unable to persist profile JSON, continuing with intent profile", it)
        }
        return json
    }

    private fun decodeProfileId(profileJSON: String): String {
        return json.decodeFromString<TaggedProfile>(profileJSON).id
    }

    private suspend fun stopTunnel() {
        if (!isRunning) {
            activeProfileId = null
            return
        }
        Log.i(logTag, "Stopping VPN daemon")
        runCatching {
            engine.stop()
        }.onFailure {
            Log.e(logTag, "Unable to stop VPN daemon", it)
        }
        isRunning = false
        controller?.stopObserving()
        controller?.cancelTunnel(null)
        controller = null
        activeProfileId = null
        snapshotEmitter.emitFinal()
    }

    private fun disconnect(intent: Intent?) = launchCommand {
        val forgetId = intent?.getStringExtra(EXTRA_FORGET_ID)
        if (forgetId != null) {
            engine.deleteLastProfile(forgetId)
            if (forgetId != activeProfileId) {
                Log.i(logTag, "Forgot profile $forgetId without stopping active profile $activeProfileId")
                if (!isRunning) {
                    stopService()
                }
                return@launchCommand
            }
        }
        stopTunnel()
        stopService()
    }

    private fun stopService() {
        service.stopSelf()
        engine.onServiceStopped()
    }

    private fun close() {
        Log.d(logTag, "PartoutVpnServiceRuntime.close()")
        commandQueue.close()
        serviceScope.cancel()
    }
    //endregion

    //region Snapshots
    private class SnapshotEmitter(
        private val logTag: String?,
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
                logIfNeeded("Drop stale daemon snapshot: $snapshot")
                return
            }
            broadcast(snapshot)
        }

        fun emitFinal() = synchronized(lock) {
            logIfNeeded("Emit final daemon snapshot")
            latestSnapshot?.let {
                emit(it.disabled())
            }
            isAccepting = false
            activeProfileId = null
        }

        fun emitInactive(profileId: String) {
            emit(
                TunnelSnapshot(
                    id = profileId,
                    isEnabled = false,
                    onDemand = false,
                    status = TunnelStatus.inactive
                )
            )
            shutdown()
        }

        fun latest(): TunnelSnapshot? = synchronized(lock) {
            latestSnapshot
        }

        private fun broadcast(snapshot: TunnelSnapshot) {
            logIfNeeded("Emit daemon snapshot: $snapshot")
            val intent = Intent(ACTION_SNAPSHOT).apply {
                setPackage(service.packageName)
                putExtra(EXTRA_SNAPSHOT_JSON, json.encodeToString(snapshot))
            }
            latestSnapshot = snapshot
            service.sendBroadcast(intent)
        }

        private fun logIfNeeded(message: String) {
            logTag?.let {
                Log.d(it, message)
            }
        }

        private fun TunnelSnapshot.disabled() = TunnelSnapshot(
            id,
            false,
            false,
            TunnelStatus.inactive,
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
        runCatching {
            client.send(msg)
        }.onFailure {
            Log.w(logTag, "Unable to reply with VPN snapshot", it)
        }
    }

    private fun replyEnvironmentValue(client: Messenger, reqId: Int, name: String) {
        val value = controller?.getEnvironmentValue(name)
        Log.i(logTag, "Reply with environment: $name = $value")
        val msg = Message.obtain(null, MSG_GET_ENVIRONMENT).apply {
            arg1 = reqId
            data = Bundle().apply {
                putString(MSG_KEY_ENV_NAME, name)
                putString(MSG_KEY_JSON, value)
            }
        }
        runCatching {
            client.send(msg)
        }.onFailure {
            Log.w(logTag, "Unable to reply with environment value of '$name'", it)
        }
    }
    //endregion

    //region Engine
    interface Engine {
        suspend fun start(intent: Intent?, controller: NativeTunnelControllerJNI, profileJSON: String)
        suspend fun stop()
        suspend fun readLastProfile(): String
        suspend fun writeLastProfile(json: String)
        suspend fun deleteLastProfile(id: String)
        fun onSnapshot(snapshot: TunnelSnapshot)
        fun onServiceStopped() {}
    }
    //endregion

    //region Generic helpers
    private fun launchCommand(action: suspend () -> Unit) {
        commandQueue.trySend(action).onFailure {
            Log.w(logTag, "Unable to enqueue VPN command", it)
        }
    }

    private fun Throwable.throwIfCancellation() {
        if (this is CancellationException) {
            throw this
        }
    }
    //endregion

    //region Constants
    companion object {
        const val ACTION_STOP_VPN = "io.partout.action.STOP_VPN"
        const val ACTION_SNAPSHOT = "io.partout.action.SNAPSHOT"
        const val EXTRA_PROFILE_JSON = "io.partout.extra.PROFILE_JSON"
        const val EXTRA_SNAPSHOT_JSON = "io.partout.extra.SNAPSHOT_JSON"
        const val EXTRA_FORGET_ID = "io.partout.extra.FORGET_ID"

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
