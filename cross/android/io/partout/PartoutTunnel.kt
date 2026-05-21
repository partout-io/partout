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
import android.util.Log
import androidx.core.content.ContextCompat
import io.partout.models.TaggedProfile
import io.partout.models.TunnelSnapshot
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.json.Json
import java.io.Closeable

class PartoutTunnel(
    private val logTag: String,
    private val context: Context,
    private val vpnServiceClass: Class<out VpnService>,
    private val isForeground: Boolean,
    private val requestVpnPermission: (Intent) -> Unit,
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

    // Initialization

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
                        if (key == null || valueJSON == null) { return }
                        Log.i(logTag, "Got environment: $key = $valueJSON")
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
                service.linkToDeath(deathRecipient, 0)

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
        appContext.unregisterReceiver(snapshotsReceiver)
        serviceMessenger?.binder?.unlinkToDeath(deathRecipient, 0)
        serviceMessenger = null
        if (isBound) {
            appContext.unbindService(connection)
            isBound = false
        }
    }

    // Actions

    fun onVpnPermissionResult(granted: Boolean) {
        val permission = pendingPermission ?: return
        pendingPermission = null
        if (!granted) {
            permission.completion(ERROR_PERMISSION_DENIED)
            return
        }
        startVpnService(permission.profile)
        permission.completion(ERROR_NONE)
    }

    fun connect(profile: TaggedProfile, completion: (Int) -> Unit) {
        val permissionIntent = VpnService.prepare(appContext)
        if (permissionIntent != null) {
            pendingPermission?.completion?.invoke(ERROR_PERMISSION_DENIED)
            pendingPermission = PendingPermission(profile, completion)
            requestVpnPermission(permissionIntent)
            return
        }
        startVpnService(profile)
        completion(ERROR_NONE)
    }

    fun disconnect(profileId: String? = null, completion: (Int) -> Unit) {
        pendingPermission?.completion?.invoke(ERROR_PERMISSION_DENIED)
        pendingPermission = null
        stopVpnService(profileId)
        completion(ERROR_NONE)
    }

    // Messaging

    fun requestSnapshot() {
        val msg = Message.obtain(null, PartoutVpnServiceRuntime.MSG_GET_STATUS).apply {
            replyTo = clientMessenger
        }
        serviceMessenger?.send(msg)
    }

    fun requestEnvironmentValue(name: String) {
        val msg = Message.obtain(null, PartoutVpnServiceRuntime.MSG_GET_ENVIRONMENT).apply {
            replyTo = clientMessenger
            data = Bundle().apply {
                putString(PartoutVpnServiceRuntime.MSG_KEY_ENV_NAME, name)
            }
        }
        serviceMessenger?.send(msg)
    }

    private fun onServiceDead() {
        _state.update {
            it.copy(emptyMap())
        }
    }

    // Internals

    private fun startVpnService(profile: TaggedProfile) {
        val startIntent = Intent(appContext, vpnServiceClass).apply {
            putExtra(PartoutVpnServiceRuntime.EXTRA_PROFILE_JSON, json.encodeToString(profile))
        }
        if (isForeground) {
            ContextCompat.startForegroundService(context, startIntent)
        } else {
            appContext.startService(startIntent)
        }
    }

    private fun stopVpnService(profileId: String?) {
        val stopIntent = Intent(appContext, vpnServiceClass).apply {
            action = PartoutVpnServiceRuntime.ACTION_STOP_VPN
            if (profileId != null) {
                putExtra(PartoutVpnServiceRuntime.EXTRA_PROFILE_ID, profileId)
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
            Log.e(logTag, ">>> Snapshot received: ${snapshot}")
            _state.update {
                it.copy(mapOf(snapshot.id to snapshot))
            }
        }.onFailure {
            Log.e(logTag, ">>> Unable to decode snapshot: ${0}")
        }
    }

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
        val completion: (Int) -> Unit
    )
}
