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
class AndroidTunnelController: AutoCloseable {
    private val logTag = "Partout"
    private val service: VpnService
    private val builder: VpnService.Builder
    private var descriptor: ParcelFileDescriptor?

    constructor(service: VpnService) {
        this.service = service
        builder = service.Builder()
        descriptor = null
    }

    fun testWorking() {
        Log.e(logTag, ">>> PartoutVpnWrapper: Working!")
    }

    fun setAddress(address: String, prefix: Int) {
        builder.addAddress(address, prefix)
    }

    fun build(infoJSON: String): Int? {
        assert(descriptor == null)

        // Decode info
        Log.e(logTag, ">>> PartoutVpnWrapper: infoJSON = $infoJSON")
        val info: TunnelRemoteInfoWrapper = try {
            Json.decodeFromString(infoJSON)
        } catch (e: SerializationException) {
            Log.e(logTag, ">>> PartoutVpnWrapper: Failed to decode tunnel info JSON", e)
            return null
        }
        val remoteFds = info.fileDescriptors

        info.modules?.forEach {
            when (it) {
                is TaggedModuleDNS -> {
                    Log.i(logTag, "DNS: ${it.value}")
                }
                is TaggedModuleIP -> {
                    Log.i(logTag, "IP: ${it.value}")
                }
                is TaggedModuleHTTPProxy -> {
                    Log.i(logTag, "HTTP Proxy: ${it.value}")
                }
                is TaggedModuleOnDemand -> {
                    Log.i(logTag, "OnDemand: ${it.value}")
                }
                else -> {}
            }
        }

        // Protect remote socket to escape tunnel
        Log.e(logTag, ">>> PartoutVpnWrapper: Building with remoteFds = " + remoteFds + " (" + remoteFds.size + ")")
        remoteFds.forEach {
            service.protect(it)
        }

        // FIXME: hardcode network settings to try tun fd
//        builder.setSession()
        builder
            // OpenVPN
            .addAddress("10.8.0.2", 24)
            .addRoute("10.8.0.0", 24)
            // WireGuard
//            .addAddress("192.168.30.2", 32)
            // All
            .addRoute("0.0.0.0", 0)
            .addDnsServer("1.1.1.1")

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
        Log.e(logTag, ">>> PartoutVpnWrapper: Establishing...")
        descriptor = builder.establish()
        if (descriptor == null) {
            Log.e(logTag, ">>> PartoutVpnWrapper: Unable to establish")
            return null
        }

        // Success
        val fd = descriptor?.fd
        Log.e(logTag, ">>> PartoutVpnWrapper: Established descriptor: " + fd)
//        descriptor?.detachFd()
        return fd
    }

    fun configureSockets(fds: Array<Int>) {
        Log.e(logTag, ">>> PartoutVpnWrapper: Configuring with fds = " + fds + " (" + fds.size + ")")
        fds.forEach {
            service.protect(it)
        }
    }

    override fun close() {
        Log.e(logTag, ">>> PartoutVpnWrapper: Closing...")
        descriptor?.close()
        descriptor = null
    }
}
