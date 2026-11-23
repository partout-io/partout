// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

package io.partout

private class RecordingController : NativeTunnelControllerJNI {
    val calls = mutableListOf<String>()
    var nativeDelegate = 0L
    val delegates = mutableListOf<Long>()

    override fun setDelegate(delegate: Long): Long {
        calls += "delegate"
        delegates += delegate
        val previous = nativeDelegate
        nativeDelegate = delegate
        return previous
    }

    override fun setTunnel(infoJSON: String): Int {
        calls += "tunnel:$infoJSON"
        return 42
    }

    override fun configureSockets(fds: IntArray) {
        calls += "sockets:${fds.joinToString(",")}"
    }

    override fun onSnapshot(snapshotJSON: String) {
        calls += "snapshot:$snapshotJSON"
    }

    override fun setEnvironmentValue(key: String, value: String?) {
        calls += "environment:$key=$value"
    }

    override fun clearTunnel(killSwitch: Boolean) {
        calls += "clear:$killSwitch"
    }

    override fun cancelTunnel(errorCode: String?) {
        calls += "cancel:$errorCode"
    }
}

object ControllerBindingsTest {
    @JvmStatic
    private external fun exercise(controller: NativeTunnelControllerJNI): Boolean

    @JvmStatic
    fun main(args: Array<String>) {
        System.load(args.single())
        val controller = RecordingController()
        check(exercise(controller)) { "C did not receive the expected Kotlin return values" }
        check(controller.calls == listOf(
            "delegate", "delegate", "delegate",
            "tunnel:{\"test\":true}", "sockets:7,11",
            "snapshot:{\"connected\":true}",
            "environment:key=value", "environment:key=null",
            "clear:true", "clear:false", "cancel:error", "cancel:null"
        )) { "Unexpected Kotlin calls: ${controller.calls}" }
        check(controller.delegates.size == 3)
        check(controller.delegates[0] != 0L && controller.delegates[1] != 0L)
        check(controller.delegates[0] != controller.delegates[1])
        check(controller.delegates[2] == 0L && controller.nativeDelegate == 0L)
        println("C → Kotlin controller bindings passed (all seven callbacks)")
    }
}
