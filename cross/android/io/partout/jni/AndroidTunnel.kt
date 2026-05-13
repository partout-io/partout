// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.jni

import android.content.Context
import android.content.Intent
import android.net.VpnService
import androidx.core.content.ContextCompat
import io.partout.abi.TaggedProfile
import kotlinx.serialization.json.Json

class AndroidTunnel(
    context: Context,
    private val vpnServiceClass: Class<out VpnService>,
    private val requestVpnPermission: (Intent) -> Unit
) {
    private val appContext = context.applicationContext
    private var pendingPermission: PendingPermission? = null

    fun connect(profileJSON: String, ctx: Long, completion: Long) {
        val profile = json.decodeFromString<TaggedProfile>(profileJSON)
        val complete: (Int) -> Unit = { code ->
            callback(ctx, completion, code)
        }
        val permissionIntent = VpnService.prepare(appContext)
        if (permissionIntent != null) {
            pendingPermission?.completion?.invoke(-1)
            pendingPermission = PendingPermission(profile, complete)
            requestVpnPermission(permissionIntent)
            return
        }
        startVpnService(profile)
        complete(0)
    }

    fun disconnect(ctx: Long, completion: Long) {
        pendingPermission?.completion?.invoke(-1)
        pendingPermission = null
        stopVpnService()
        callback(ctx, completion, 0)
    }

    fun onVpnPermissionResult(granted: Boolean) {
        val permission = pendingPermission ?: return
        pendingPermission = null
        if (!granted) {
            permission.completion(-1)
            return
        }
        startVpnService(permission.profile)
        permission.completion(0)
    }

    private fun startVpnService(profile: TaggedProfile) {
        val startIntent = Intent(appContext, vpnServiceClass).apply {
            putExtra(EXTRA_PROFILE_JSON, json.encodeToString(profile))
        }
        ContextCompat.startForegroundService(appContext, startIntent)
    }

    private fun stopVpnService() {
        val stopIntent = Intent(appContext, vpnServiceClass).apply {
            action = ACTION_STOP_VPN
        }
        ContextCompat.startForegroundService(appContext, stopIntent)
    }

    companion object {
        const val ACTION_STOP_VPN = "io.partout.jni.action.STOP_VPN"
        const val EXTRA_PROFILE_JSON = "io.partout.jni.extra.PROFILE_JSON"

        private val json = Json {
            ignoreUnknownKeys = true
        }
    }

    private external fun callback(ctx: Long, completion: Long, errorCode: Int)

    private data class PendingPermission(
        val profile: TaggedProfile,
        val completion: (Int) -> Unit
    )
}
