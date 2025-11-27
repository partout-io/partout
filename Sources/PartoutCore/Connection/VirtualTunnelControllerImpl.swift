// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !os(iOS) && !os(tvOS)

@_implementationOnly import _PartoutCore_C

public struct VirtualTunnelControllerImpl {
    let thiz: UnsafeMutableRawPointer
    let setTunnel: (_ thiz: UnsafeMutableRawPointer, TunnelRemoteInfo) -> UnsafeMutableRawPointer?
    let configureSockets: (_ thiz: UnsafeMutableRawPointer, [UInt64]) -> Void
    let clearTunnel: (_ thiz: UnsafeMutableRawPointer, _ tun: UnsafeMutableRawPointer?) -> Void
    let testCallback: (_ thiz: UnsafeMutableRawPointer) -> Void

    public init(thiz: UnsafeMutableRawPointer, setTunnel: @escaping (_: UnsafeMutableRawPointer, TunnelRemoteInfo) -> UnsafeMutableRawPointer?, configureSockets: @escaping (_: UnsafeMutableRawPointer, [UInt64]) -> Void, clearTunnel: @escaping (_: UnsafeMutableRawPointer, _: UnsafeMutableRawPointer?) -> Void, testCallback: @escaping (_: UnsafeMutableRawPointer) -> Void) {
        self.thiz = thiz
        self.setTunnel = setTunnel
        self.configureSockets = configureSockets
        self.clearTunnel = clearTunnel
        self.testCallback = testCallback
    }
}

#endif
