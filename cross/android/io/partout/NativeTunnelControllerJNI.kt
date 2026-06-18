// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout

/*
Three layers are involved in this:
- PartoutVpnServiceRuntime.kt
- JNITunnelController.kt
- NativeTunnelController.swift (+ tun_android.c)

Where:
- PartoutVpnServiceRuntime owns JNITunnelController and forwards its JNI ref to Engine.start()
- The engine sets up the Swift/C NativeTunnelController with the JNI ref
- On setup, NativeTunnelController sets itself (via C) as the JNITunnelController delegate
- When needed, NativeTunnelController calls JNITunnelController methods via JNI
- When needed, JNITunnelController calls NativeTunnelController methods via the JNI delegate
 */

// Swift/C -> Kotlin: ProGuard rules MUST MATCH!
interface NativeTunnelControllerJNI {
    fun setDelegate(delegate: Long): Long
    fun setTunnel(infoJSON: String): Int
    fun configureSockets(fds: IntArray)
    fun onSnapshot(snapshotJSON: String)
    fun clearTunnel(killSwitch: Boolean)
    fun cancelTunnel(errorCode: String?)
}
