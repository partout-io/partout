// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.ServiceConnection
import android.net.VpnService
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.RemoteException
import android.util.Log
import androidx.core.content.ContextCompat
import io.partout.models.TaggedProfile
import io.partout.models.TunnelSnapshot
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.json.Json
import java.io.Closeable
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class PartoutTunnel(
    private val logTag: String,
    private val context: Context,
    private val vpnServiceClass: Class<out VpnService>,
    private val isForeground: Boolean,
    private val requestVpnPermission: (Intent) -> Unit
) : Closeable {
    private val appContext = context.applicationContext
    private var pendingPermission: PendingPermission? = null

    // Emitted updates
    private val _state = MutableStateFlow(State())
    val state = _state.asStateFlow()

    // Service updates through binding and broadcasts
    private val clientMessenger: Messenger
    private val deathRecipient: IBinder.DeathRecipient
    private val connection: ServiceConnection
    private val snapshotsReceiver: BroadcastReceiver
    private var isBound: Boolean
    private var serviceMessenger: Messenger? = null

    // Async messaging
    private val nextRequestId = AtomicInteger(1)
    private val pendingRequests = ConcurrentHashMap<Int, kotlinx.coroutines.CancellableContinuation<String?>>()

    //region Initialization
    init {
        clientMessenger = Messenger(object : Handler(Looper.getMainLooper()) {
            override fun handleMessage(msg: Message) {
                when (msg.what) {
                    PartoutVpnServiceRuntime.MSG_GET_STATUS -> {
                        val snapshotJSON = msg.data.getString(PartoutVpnServiceRuntime.MSG_KEY_JSON)
                        if (snapshotJSON == null) {
                            _state.update {
                                it.copy(emptyMap())
                            }
                            return
                        }
                        onSnapshotJSON(snapshotJSON)
                    }
                    PartoutVpnServiceRuntime.MSG_GET_ENVIRONMENT -> {
                        val key = msg.data.getString(PartoutVpnServiceRuntime.MSG_KEY_ENV_NAME)
                        val valueJSON = msg.data.getString(PartoutVpnServiceRuntime.MSG_KEY_JSON)
                        if (key == null) { return }

                        // Invoke continuation
                        val reqId = msg.arg1
                        pendingRequests.remove(reqId)?.resume(valueJSON)
                    }
                    else -> super.handleMessage(msg)
                }
            }
        })
        deathRecipient = IBinder.DeathRecipient {
            serviceMessenger = null
            onServiceDead()
        }
        connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, service: IBinder) {
                serviceMessenger = Messenger(service)
                runCatching {
                    service.linkToDeath(deathRecipient, 0)
                }.onFailure {
                    Log.e(logTag, "Unable to link to death", it)
                }
                // Ask the service for its current snapshot
                requestSnapshot()
            }

            override fun onServiceDisconnected(name: ComponentName) {
                serviceMessenger = null
                onServiceDead()
            }

            override fun onBindingDied(name: ComponentName) {
                serviceMessenger = null
                onServiceDead()
            }

            override fun onNullBinding(name: ComponentName) {
                serviceMessenger = null
                onServiceDead()
            }
        }
        snapshotsReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action != PartoutVpnServiceRuntime.ACTION_SNAPSHOT) {
                    return
                }
                intent.getStringExtra(PartoutVpnServiceRuntime.EXTRA_SNAPSHOT_JSON)?.let {
                    onSnapshotJSON(it)
                }
            }
        }

        // Bind service immediately
        val intent = Intent(context, vpnServiceClass)
        isBound = context.bindService(intent, connection, Context.BIND_AUTO_CREATE)

        // Register for snapshots
        ContextCompat.registerReceiver(
            appContext,
            snapshotsReceiver,
            IntentFilter(PartoutVpnServiceRuntime.ACTION_SNAPSHOT),
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
    }

    override fun close() {
        val oldServiceMessenger = serviceMessenger
        serviceMessenger = null
        failPendingRequests()
        appContext.unregisterReceiver(snapshotsReceiver)
        oldServiceMessenger?.binder?.unlinkToDeath(deathRecipient, 0)
        if (isBound) {
            appContext.unbindService(connection)
            isBound = false
        }
    }
    //endregion

    //region Actions
    fun onVpnPermissionResult(granted: Boolean) {
        val permission = pendingPermission ?: return
        pendingPermission = null
        if (!granted) {
            permission.completion(ERROR_PERMISSION_DENIED)
            return
        }
        startVpnService(permission.profile, permission.onIntent)
        permission.completion(ERROR_NONE)
    }

    fun connect(profile: TaggedProfile, onIntent: (Intent) -> Unit = { _ -> }, completion: (Int) -> Unit) {
        val permissionIntent = VpnService.prepare(appContext)
        if (permissionIntent != null) {
            pendingPermission?.completion?.invoke(ERROR_PERMISSION_DENIED)
            pendingPermission = PendingPermission(profile, onIntent, completion)
            requestVpnPermission(permissionIntent)
            return
        }
        startVpnService(profile, onIntent)
        completion(ERROR_NONE)
    }

    fun disconnect(profileId: String, forget: Boolean = false, completion: (Int) -> Unit) {
        pendingPermission?.completion?.invoke(ERROR_PERMISSION_DENIED)
        pendingPermission = null
        stopVpnService(profileId, forget)
        completion(ERROR_NONE)
    }
    //endregion

    //region Messaging
    fun requestSnapshot() {
        val msg = Message.obtain(null, PartoutVpnServiceRuntime.MSG_GET_STATUS).apply {
            replyTo = clientMessenger
        }
        runCatching {
            serviceMessenger?.send(msg)
        }.onFailure {
            Log.e(logTag, "Unable to request snapshot", it)
        }
    }

    suspend fun requestEnvironmentValue(name: String): String? =
        suspendCancellableCoroutine { continuation ->
            val reqId = nextRequestId.getAndIncrement()
            pendingRequests[reqId] = continuation
            continuation.invokeOnCancellation {
                pendingRequests.remove(reqId)
            }
            val msg = Message.obtain(null, PartoutVpnServiceRuntime.MSG_GET_ENVIRONMENT).apply {
                replyTo = clientMessenger
                arg1 = reqId
                data = Bundle().apply {
                    putString(PartoutVpnServiceRuntime.MSG_KEY_ENV_NAME, name)
                }
            }
            val messenger = serviceMessenger
            if (messenger == null) {
                pendingRequests.remove(reqId)?.resumeWithException(RemoteException())
                return@suspendCancellableCoroutine
            }
            runCatching {
                messenger.send(msg)
            }.onFailure {
                Log.e(logTag, "Unable to request environment", it)
                pendingRequests.remove(reqId)?.resumeWithException(it)
            }
        }

    private fun onServiceDead() {
        failPendingRequests()
        _state.update {
            it.copy(emptyMap())
        }
    }

    private fun failPendingRequests() {
        pendingRequests.entries
            .map { it.key to it.value }
            .forEach { (reqId, continuation) ->
                if (pendingRequests.remove(reqId, continuation)) {
                    continuation.resumeWithException(RemoteException())
                }
            }
    }
    //endregion

    //region Internals
    private fun startVpnService(profile: TaggedProfile, onIntent: (Intent) -> Unit) {
        val startIntent = Intent(appContext, vpnServiceClass).apply {
            putExtra(PartoutVpnServiceRuntime.EXTRA_PROFILE_JSON, json.encodeToString(profile))
            onIntent(this)
        }
        if (isForeground) {
            ContextCompat.startForegroundService(context, startIntent)
        } else {
            appContext.startService(startIntent)
        }
    }

    private fun stopVpnService(profileId: String, forget: Boolean) {
        val stopIntent = Intent(appContext, vpnServiceClass).apply {
            action = PartoutVpnServiceRuntime.ACTION_STOP_VPN
            if (forget) {
                putExtra(PartoutVpnServiceRuntime.EXTRA_FORGET_ID, profileId)
            }
        }
        if (isForeground) {
            ContextCompat.startForegroundService(context, stopIntent)
        } else {
            appContext.startService(stopIntent)
        }
    }

    private fun onSnapshotJSON(snapshotJSON: String) {
        runCatching {
            json.decodeFromString<TunnelSnapshot>(snapshotJSON)
        }.onSuccess { snapshot ->
            Log.d(logTag, ">>> Snapshot received: $snapshot")
            _state.update {
                it.copy(mapOf(snapshot.id to snapshot))
            }
        }.onFailure {
            Log.e(logTag, ">>> Unable to decode snapshot: ${0}")
        }
    }
    //endregion

    companion object {
        const val ERROR_NONE = 0
        const val ERROR_PERMISSION_DENIED = -1

        private val json = Json {
            ignoreUnknownKeys = true
        }
    }

    data class State(
        val snapshots: Map<String, TunnelSnapshot> = emptyMap()
    )

    private data class PendingPermission(
        val profile: TaggedProfile,
        val onIntent: (Intent) -> Unit,
        val completion: (Int) -> Unit
    )
}
