package io.partout.jni

import android.content.Context
import android.content.Intent
import android.net.VpnService
import androidx.core.content.ContextCompat
import io.partout.abi.TaggedProfile
import kotlinx.serialization.json.Json

class AndroidTunnelStrategy(
    context: Context,
    private val vpnServiceClass: Class<out VpnService>,
    private val requestVpnPermission: (Intent) -> Unit
) {
    private val appContext = context.applicationContext
    private var pendingInstall: TaggedProfile? = null

    suspend fun connect(profile: TaggedProfile) {
        val permissionIntent = VpnService.prepare(appContext)
        if (permissionIntent != null) {
            pendingInstall = profile
            requestVpnPermission(permissionIntent)
            return
        }
        startVpnService(profile)
    }

    suspend fun disconnect() {
        stopVpnService()
    }

    fun onVpnPermissionResult(granted: Boolean) {
        val profile = pendingInstall
        pendingInstall = null
        if (!granted || profile == null) { return }
        startVpnService(profile)
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
        const val EXTRA_PROFILE_ID = "io.partout.jni.extra.PROFILE_ID"
        const val EXTRA_PROFILE_JSON = "io.partout.jni.extra.PROFILE_JSON"

        private val json = Json {
            ignoreUnknownKeys = true
        }
    }
}
