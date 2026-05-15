// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.jni

import android.content.Context
import android.content.Intent
import android.net.VpnService
import androidx.core.content.ContextCompat
import io.partout.abi.TaggedProfile
import io.partout.abi.TunnelSnapshot
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.serialization.json.Json

class PartoutTunnel(
    context: Context,
    private val vpnServiceClass: Class<out VpnService>,
    private val channel: PartoutVpnServiceRuntime.Channel,
    private val requestVpnPermission: (Intent) -> Unit,
    private val coroutineScope: CoroutineScope
) {
    private val appContext = context.applicationContext
    private var pendingPermission: PendingPermission? = null
    private val scope = CoroutineScope(
        coroutineScope.coroutineContext + SupervisorJob(coroutineScope.coroutineContext[Job])
    )

    init {
        channel
            .activeSnapshot
            .onEach(::onSnapshot)
            .launchIn(scope)
    }

    // JNI
    fun connect(profileJSON: String, ctx: Long, completion: Long) {
        val profile = json.decodeFromString<TaggedProfile>(profileJSON)
        connect(profile) { code ->
            callback(ctx, completion, code)
        }
    }

    // JNI
    fun disconnect(ctx: Long, completion: Long) {
        disconnect { code ->
            callback(ctx, completion, code)
        }
    }

    // JNI
    private external fun callback(ctx: Long, completion: Long, errorCode: Int)

    fun onSnapshot(snapshot: TunnelSnapshot?) {
        val snapshots: Map<String, TunnelSnapshot> = if (snapshot == null || !snapshot.isEnabled) {
            emptyMap()
        } else {
            mapOf(Pair(snapshot.id, snapshot))
        }
        // FIXME: Send back to NativeTunnel via JNI
//        abi.submitSnapshots(snapshots)
    }

    fun onVpnPermissionResult(granted: Boolean) {
        val permission = pendingPermission ?: return
        pendingPermission = null
        if (!granted) {
            permission.completion(ERROR_PERMISSION_DENIED)
            return
        }
        startVpnService(permission.profile)
        permission.completion(0)
    }

    private fun connect(profile: TaggedProfile, completion: (Int) -> Unit) {
        val permissionIntent = VpnService.prepare(appContext)
        if (permissionIntent != null) {
            pendingPermission?.completion?.invoke(ERROR_PERMISSION_DENIED)
            pendingPermission = PendingPermission(profile, completion)
            requestVpnPermission(permissionIntent)
            return
        }
        startVpnService(profile)
        completion(0)
    }

    private fun disconnect(profileId: String? = null, completion: (Int) -> Unit) {
        pendingPermission?.completion?.invoke(ERROR_PERMISSION_DENIED)
        pendingPermission = null
        stopVpnService(profileId)
        completion(0)
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

    companion object {
        private const val ERROR_PERMISSION_DENIED = -1

        private val json = Json {
            ignoreUnknownKeys = true
        }
    }

    private data class PendingPermission(
        val profile: TaggedProfile,
        val completion: (Int) -> Unit
    )
}
