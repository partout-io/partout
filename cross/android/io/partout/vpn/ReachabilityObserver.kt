// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.vpn

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow

interface ReachabilityObserverProtocol {
    fun flow(): Flow<Network?>
}

class ReachabilityObserver(
    context: Context,
    private val appContext: Context = context.applicationContext,
    private val connectivityManager: ConnectivityManager =
        appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
) : ReachabilityObserverProtocol {
    override fun flow(): Flow<Network?> = callbackFlow {
        val lock = Any()
        val reachableNetworks = linkedSetOf<Network>()
        var lastNetwork: Network? = null
        var didEmit = false

        class Evaluation(val network: Network?)

        fun currentNetwork(): Network? {
            return reachableNetworks.firstOrNull()
        }

        fun evaluateLocked(): Evaluation? {
            val network = currentNetwork()
            if (didEmit && network == lastNetwork) {
                return null
            }
            didEmit = true
            lastNetwork = network
            return Evaluation(network)
        }

        fun update(network: Network, capabilities: NetworkCapabilities?) {
            val evaluation = synchronized(lock) {
                if (capabilities.isUsableUnderlying()) {
                    reachableNetworks.add(network)
                } else {
                    reachableNetworks.remove(network)
                }
                evaluateLocked()
            }
            evaluation?.let {
                trySend(it.network)
            }
        }

        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                update(network, connectivityManager.getNetworkCapabilities(network))
            }

            override fun onCapabilitiesChanged(
                network: Network,
                networkCapabilities: NetworkCapabilities
            ) {
                update(network, networkCapabilities)
            }

            override fun onLost(network: Network) {
                update(network, null)
            }
        }

        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()

        connectivityManager.registerNetworkCallback(request, callback)

        // Emit initial event
        val initialEvaluation = synchronized(lock) {
            evaluateLocked()
        }
        initialEvaluation?.let {
            trySend(it.network)
        }

        awaitClose {
            runCatching {
                connectivityManager.unregisterNetworkCallback(callback)
            }
        }
    }

    private fun NetworkCapabilities?.isUsableUnderlying(): Boolean {
        if (this == null) {
            return false
        }
        return hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) &&
                hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) &&
                hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED) &&
                hasCapability(NetworkCapabilities.NET_CAPABILITY_TRUSTED)
    }
}