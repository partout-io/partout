// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.vpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import androidx.core.content.ContextCompat
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.launch

interface ReachabilityObserverProtocol {
    fun flow(): Flow<Network?>
}

class ReachabilityObserver(
    context: Context,
    private val appContext: Context = context.applicationContext,
    private val connectivityManager: ConnectivityManager =
        appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
) : ReachabilityObserverProtocol {
    @Suppress("DEPRECATION")
    override fun flow(): Flow<Network?> = callbackFlow {
        val producerScope = this
        val lock = Any()
        val reachableNetworks = linkedSetOf<Network>()
        var lastNetwork: Network? = null

        class Evaluation(val network: Network?)

        fun currentNetwork(): Network? {
            return reachableNetworks.firstOrNull()
        }

        fun evaluateLocked(): Evaluation? {
            val network = currentNetwork()
            if (network == lastNetwork) {
                return null
            }
            lastNetwork = network
            return Evaluation(network)
        }

        fun currentReachableNetworks(): List<Network> {
            return connectivityManager.allNetworks.filter { network ->
                connectivityManager.getNetworkCapabilities(network).isReachablePath
            }
        }

        fun replaceCurrentNetworks() {
            val evaluation = synchronized(lock) {
                reachableNetworks.clear()
                reachableNetworks.addAll(currentReachableNetworks())
                evaluateLocked()
            }
            evaluation?.let {
                trySend(it.network)
            }
        }

        fun replaceWithUnreachable() {
            val evaluation = synchronized(lock) {
                reachableNetworks.clear()
                evaluateLocked()
            }
            evaluation?.let {
                trySend(it.network)
            }
        }

        fun refreshCurrentNetworks() {
            replaceCurrentNetworks()
            producerScope.launch {
                delay(CONNECTIVITY_REFRESH_DELAY_MS)
                replaceCurrentNetworks()
            }
        }

        fun update(network: Network, capabilities: NetworkCapabilities?) {
            val evaluation = synchronized(lock) {
                if (capabilities.isReachablePath) {
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

        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                when (intent?.action) {
                    Intent.ACTION_AIRPLANE_MODE_CHANGED -> {
                        if (intent.getBooleanExtra("state", false)) {
                            replaceWithUnreachable()
                        } else {
                            refreshCurrentNetworks()
                        }
                    }
                    ConnectivityManager.CONNECTIVITY_ACTION -> {
                        refreshCurrentNetworks()
                    }
                }
            }
        }

        // Keep the callback unfiltered so paths that stop matching INTERNET/NOT_VPN
        // can still trigger null.
        val request = NetworkRequest.Builder()
            .clearCapabilities()
            .build()

        connectivityManager.registerNetworkCallback(request, callback)

        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_AIRPLANE_MODE_CHANGED)
            addAction(ConnectivityManager.CONNECTIVITY_ACTION)
        }

        ContextCompat.registerReceiver(
            appContext,
            receiver,
            filter,
            ContextCompat.RECEIVER_NOT_EXPORTED
        )

        refreshCurrentNetworks()

        awaitClose {
            runCatching {
                connectivityManager.unregisterNetworkCallback(callback)
            }
            runCatching {
                appContext.unregisterReceiver(receiver)
            }
        }
    }

    private companion object {
        const val CONNECTIVITY_REFRESH_DELAY_MS = 500L
    }
}

private val NetworkCapabilities?.isReachablePath: Boolean
    get() {
        if (this == null) {
            return false
        }
        return hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) &&
                hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
    }
