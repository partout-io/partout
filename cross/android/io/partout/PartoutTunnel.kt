// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.VpnService
import androidx.core.content.ContextCompat
import io.partout.models.TaggedProfile
import io.partout.models.TunnelSnapshot
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.json.Json
import java.io.Closeable

class PartoutTunnel(
    context: Context,
    private val vpnServiceClass: Class<out VpnService>,
    private val requestVpnPermission: (Intent) -> Unit,
) : Closeable {
    private val appContext = context.applicationContext
    private var pendingPermission: PendingPermission? = null
    private val _state = MutableStateFlow(State())
    val state = _state.asStateFlow()
    private val snapshotsReceiver: BroadcastReceiver

    init {
        snapshotsReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action != PartoutVpnServiceRuntime.ACTION_SNAPSHOTS) {
                    return
                }
                val extra = intent.getStringExtra(PartoutVpnServiceRuntime.EXTRA_SNAPSHOT_JSON)
                if (extra != null) {
                    val snapshot = json.decodeFromString<TunnelSnapshot>(extra)
                    _state.update {
                        it.copy(mapOf(Pair(snapshot.id, snapshot)))
                    }
                } else {
                    _state.update {
                        it.copy(emptyMap())
                    }
                }
            }
        }
        ContextCompat.registerReceiver(
            appContext,
            snapshotsReceiver,
            IntentFilter(PartoutVpnServiceRuntime.ACTION_SNAPSHOTS),
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
    }

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

    private fun startVpnService(profile: TaggedProfile) {
        val startIntent = Intent(appContext, vpnServiceClass).apply {
            putExtra(PartoutVpnServiceRuntime.EXTRA_PROFILE_JSON, json.encodeToString(profile))
        }
        ContextCompat.startForegroundService(appContext, startIntent)
    }

    private fun stopVpnService(profileId: String?) {
        val stopIntent = Intent(appContext, vpnServiceClass).apply {
            action = PartoutVpnServiceRuntime.ACTION_STOP_VPN
            if (profileId != null) {
                putExtra(PartoutVpnServiceRuntime.EXTRA_PROFILE_ID, profileId)
            }
        }
        ContextCompat.startForegroundService(appContext, stopIntent)
    }

    override fun close() {
        appContext.unregisterReceiver(snapshotsReceiver)
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
