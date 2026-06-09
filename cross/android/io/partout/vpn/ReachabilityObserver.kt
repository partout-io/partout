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
    fun flow(): Flow<NetworkInfo>
}

class NetworkInfo private constructor(
    val currentNetworks: Set<Network>,
    private val preferences: Map<Network, NetworkPathPreference>,
    private val sortedNetworks: List<Network>
) {
    fun bestNetworks(): List<Network> {
        return sortedNetworks
    }

    internal fun preferenceFor(network: Network?): NetworkPathPreference? {
        if (network == null) {
            return null
        }
        return preferences[network]
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) {
            return true
        }
        if (other !is NetworkInfo) {
            return false
        }
        return currentNetworks == other.currentNetworks &&
                preferences == other.preferences &&
                sortedNetworks == other.sortedNetworks
    }

    override fun hashCode(): Int {
        var result = currentNetworks.hashCode()
        result = 31 * result + preferences.hashCode()
        result = 31 * result + sortedNetworks.hashCode()
        return result
    }

    override fun toString(): String {
        return "NetworkInfo(currentNetworks=$currentNetworks, bestNetworks=$sortedNetworks)"
    }

    companion object {
        internal val empty = NetworkInfo(emptySet(), emptyMap(), emptyList())

        internal fun from(
            currentNetworks: Set<Network>,
            preferences: Map<Network, NetworkPathPreference>
        ): NetworkInfo {
            val sortedNetworks = currentNetworks.sortedWith { lhs, rhs ->
                val lhsPreference = preferences[lhs] ?: NetworkPathPreference.unavailable
                val rhsPreference = preferences[rhs] ?: NetworkPathPreference.unavailable
                rhsPreference.compareTo(lhsPreference)
            }
            return NetworkInfo(currentNetworks, preferences, sortedNetworks)
        }
    }
}

class ReachabilityObserver(
    context: Context,
    private val appContext: Context = context.applicationContext,
    private val connectivityManager: ConnectivityManager =
        appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
) : ReachabilityObserverProtocol {
    override fun flow(): Flow<NetworkInfo> = callbackFlow {
        val lock = Any()
        val reachableNetworks = linkedSetOf<Network>()
        val preferences = mutableMapOf<Network, NetworkPathPreference>()
        var lastNetworkInfo: NetworkInfo? = null
        var didEmit = false

        fun evaluateLocked(): NetworkInfo? {
            val networkInfo = NetworkInfo.from(
                reachableNetworks.toSet(),
                preferences.toMap()
            )
            if (didEmit && networkInfo == lastNetworkInfo) {
                return null
            }
            didEmit = true
            lastNetworkInfo = networkInfo
            return networkInfo
        }

        fun update(network: Network, capabilities: NetworkCapabilities?) {
            val evaluation = synchronized(lock) {
                if (capabilities.isUsableUnderlying()) {
                    reachableNetworks.add(network)
                    capabilities?.asNetworkPathPreference()?.let {
                        preferences[network] = it
                    }
                } else {
                    reachableNetworks.remove(network)
                    preferences.remove(network)
                }
                evaluateLocked()
            }
            evaluation?.let {
                trySend(it)
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
            trySend(it)
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

internal data class NetworkPathPreference(
    private val statusScore: Int,
    private val isUnrestricted: Boolean,
    private val isInexpensive: Boolean,
    private val transportScore: Int
) : Comparable<NetworkPathPreference> {

    constructor(capabilities: NetworkCapabilities) : this(
        statusScore = capabilities.statusScore,
        isUnrestricted = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED),
        isInexpensive = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED),
        transportScore = capabilities.transportScore
    )

    override fun compareTo(other: NetworkPathPreference): Int {
        if (statusScore != other.statusScore) {
            return statusScore.compareTo(other.statusScore)
        }
        if (isUnrestricted != other.isUnrestricted) {
            return isUnrestricted.comparePreference(other.isUnrestricted)
        }
        if (isInexpensive != other.isInexpensive) {
            return isInexpensive.comparePreference(other.isInexpensive)
        }
        return transportScore.compareTo(other.transportScore)
    }

    companion object {
        val unavailable = NetworkPathPreference(
            statusScore = 0,
            isUnrestricted = false,
            isInexpensive = false,
            transportScore = 0
        )
    }
}

internal fun NetworkCapabilities.asNetworkPathPreference(): NetworkPathPreference? {
    if (!hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
        return null
    }
    if (!hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)) {
        return null
    }
    return NetworkPathPreference(this)
}

private val NetworkCapabilities.statusScore: Int
    get() {
        if (hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) {
            return 2
        }
        if (hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
            return 1
        }
        return 0
    }

private val NetworkCapabilities.transportScore: Int
    get() {
        if (hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) {
            return 5
        }
        if (hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
            return 4
        }
        if (hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) {
            return 3
        }
        if (hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH)) {
            return 2
        }
        return 0
    }

private fun Boolean.comparePreference(other: Boolean): Int {
    if (this == other) {
        return 0
    }
    return if (this) 1 else -1
}
