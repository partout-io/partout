// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.jni

import android.content.Context
import android.content.Intent
import android.net.VpnService
import androidx.core.content.ContextCompat
import io.partout.abi.TaggedProfile
import kotlinx.coroutines.CompletableDeferred
import kotlinx.serialization.json.Json

class AndroidTunnelStrategy(
    context: Context,
    private val vpnServiceClass: Class<out VpnService>,
    private val requestVpnPermission: (Intent) -> Unit
) {
    private val appContext = context.applicationContext
    private var pendingPermission: CompletableDeferred<Boolean>? = null

    suspend fun connect(profile: TaggedProfile): Boolean {
        val permissionIntent = VpnService.prepare(appContext)
        if (permissionIntent != null) {
            pendingPermission?.complete(false)
            val permission = CompletableDeferred<Boolean>()
            pendingPermission = permission
            requestVpnPermission(permissionIntent)
            val isGranted = try {
                permission.await()
            } finally {
                if (pendingPermission === permission) {
                    pendingPermission = null
                }
            }
            if (!isGranted) {
                return false
            }
        }
        startVpnService(profile)
        return true
    }

    suspend fun disconnect() {
        pendingPermission?.complete(false)
        pendingPermission = null
        stopVpnService()
    }

    fun onVpnPermissionResult(granted: Boolean) {
        pendingPermission?.complete(granted)
        pendingPermission = null
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
}
