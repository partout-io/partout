// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.vpn

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest

class UnderlyingNetworkTracker(
    context: Context,
    private val onNetworkHandleChanged: (Network?) -> Unit
) {
    private val cm =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    private var currentNetwork: Network? = null

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            maybeUse(network)
        }

        override fun onCapabilitiesChanged(
            network: Network,
            caps: NetworkCapabilities
        ) {
            if (isUsableUnderlying(caps)) {
                currentNetwork = network
                onNetworkHandleChanged(network)
            } else if (currentNetwork == network) {
                currentNetwork = null
                onNetworkHandleChanged(null)
            }
        }

        override fun onLost(network: Network) {
            if (currentNetwork == network) {
                currentNetwork = null
                selectInitialNetwork()
            }
        }
    }

    fun start() {
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()

        cm.registerNetworkCallback(request, callback)
        selectInitialNetwork()
    }

    fun stop() {
        cm.unregisterNetworkCallback(callback)
    }

    private fun selectInitialNetwork() {
        val network = cm.allNetworks.firstOrNull { network ->
            val caps = cm.getNetworkCapabilities(network)
            caps != null && isUsableUnderlying(caps)
        }

        currentNetwork = network
        onNetworkHandleChanged(network)
    }

    private fun maybeUse(network: Network) {
        val caps = cm.getNetworkCapabilities(network) ?: return
        if (isUsableUnderlying(caps)) {
            currentNetwork = network
            onNetworkHandleChanged(network)
        }
    }

    private fun isUsableUnderlying(caps: NetworkCapabilities): Boolean {
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
    }
}