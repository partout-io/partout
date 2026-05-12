// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.jni

import android.net.VpnService
import android.os.ParcelFileDescriptor
import android.util.Log
import io.partout.abi.TaggedModuleDNS
import io.partout.abi.TaggedModuleHTTPProxy
import io.partout.abi.TaggedModuleIP
import io.partout.abi.TaggedModuleOnDemand
import io.partout.abi.TunnelRemoteInfoWrapper
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json

// WARNING: These methods are called from a JNI background thread
class AndroidTunnelController {
    private val logTag = "Partout"
    private val service: VpnService
    private var descriptor: ParcelFileDescriptor?

    constructor(service: VpnService) {
        this.service = service
        descriptor = null
    }

    fun testWorking() {
        Log.e(logTag, ">>> AndroidTunnelController: Working!")
    }

    // FIXME: Pass Profile
    fun setTunnel(infoJSON: String): Int {
        assert(descriptor == null)
        val builder = service.Builder()

        // Decode info
        Log.e(logTag, ">>> AndroidTunnelController: infoJSON = $infoJSON")
        val info: TunnelRemoteInfoWrapper = try {
            Json.decodeFromString(infoJSON)
        } catch (e: SerializationException) {
            Log.e(logTag, ">>> AndroidTunnelController: Failed to decode tunnel info JSON", e)
            return -1
        }
        val remoteFds = info.fileDescriptors
        var appliedAddressSettings = false
        var appliedDnsSettings = false

        info.modules?.forEach {
            when (it) {
                is TaggedModuleDNS -> {
                    Log.i(logTag, "DNS: ${it.value}")
                    appliedDnsSettings = it.value.apply(builder) || appliedDnsSettings
                }
                is TaggedModuleIP -> {
                    Log.i(logTag, "IP: ${it.value}")
                    appliedAddressSettings = it.value.apply(builder) || appliedAddressSettings
                }
                is TaggedModuleHTTPProxy -> {
                    Log.i(logTag, "HTTP Proxy: ${it.value}")
                    it.value.apply(builder)
                }
                is TaggedModuleOnDemand -> {
                    Log.i(logTag, "OnDemand: ${it.value}")
                    it.value.apply(builder)
                }
                else -> {}
            }
        }

        if (!appliedAddressSettings) {
            Log.e(logTag, ">>> AndroidTunnelController: No valid interface address")
            return -1
        }

        // Protect remote socket to escape tunnel
        Log.e(logTag, ">>> AndroidTunnelController: Building with remoteFds = " + remoteFds + " (" + remoteFds.size + ")")
        remoteFds.forEach {
            val protected = service.protect(it)
            Log.e(logTag, ">>> AndroidTunnelController: protect($it) = $protected")
        }

        // FIXME: Register callback to update protected sockets?
        // FIXME: Set session name from profile name
//        builder.setSession(profile.name)

        // IMPORTANT: this is a requirement for VirtualTunnelInterface
        //
        // The effect of not doing this is the tun connection dying
        // on the first 0, because the fd is non-blocking by
        // default (EAGAIN).
        //
        // https://developer.android.com/reference/android/net/VpnService.Builder#setBlocking(boolean)
        //
        // Sets the VPN interface's file descriptor to be in blocking/non-blocking
        // mode. By default, the file descriptor returned by establish() is non-blocking.
        builder.setBlocking(true)

        // Get fd to tun device
        Log.e(logTag, ">>> AndroidTunnelController: Establishing...")
        descriptor = try {
            builder.establish()
        } catch (e: RuntimeException) {
            Log.e(logTag, ">>> AndroidTunnelController: Unable to establish", e)
            null
        }
        if (descriptor == null) {
            Log.e(logTag, ">>> AndroidTunnelController: Unable to establish")
            return -1
        }

        // Success
        val fd = descriptor?.detachFd() ?: -1
        descriptor = null
        Log.e(logTag, ">>> AndroidTunnelController: Established descriptor: " + fd)
        return fd
    }

    fun configureSockets(fds: IntArray) {
        Log.e(logTag, ">>> AndroidTunnelController: Configuring with fds = " + fds + " (" + fds.size + ")")
        fds.forEach {
            val protected = service.protect(it)
            Log.e(logTag, ">>> AndroidTunnelController: protect($it) = $protected")
        }
    }
}
