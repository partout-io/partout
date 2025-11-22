// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !os(iOS) && !os(tvOS)

import _PartoutABI_C
internal import _PartoutCore_C

public struct VirtualTunnelControllerImpl {
    let thiz: UnsafeMutableRawPointer
    let setTunnel: (_ thiz: UnsafeMutableRawPointer, TunnelRemoteInfo) -> UnsafeMutableRawPointer?
    let configureSockets: (_ thiz: UnsafeMutableRawPointer, [UInt64]) -> Void
    let clearTunnel: (_ thiz: UnsafeMutableRawPointer, _ tun: UnsafeMutableRawPointer?) -> Void
    let testCallback: (_ thiz: UnsafeMutableRawPointer) -> Void
}

extension partout_tun_ctrl {
    public var asPartoutCtrl: VirtualTunnelControllerImpl {
        VirtualTunnelControllerImpl(
            thiz: thiz,
            setTunnel: { thiz, info in
                let rawDescs = info.fileDescriptors.map(Int32.init)
                return rawDescs.withUnsafeBufferPointer {
                    var cInfo = partout_tun_ctrl_info()
                    cInfo.remote_fds = $0.baseAddress
                    cInfo.remote_fds_len = info.fileDescriptors.count
                    return set_tunnel(thiz, &cInfo)
                }
            },
            configureSockets: { thiz, fds in
                fds.map(Int32.init).withUnsafeBufferPointer {
                    configure_sockets(thiz, $0.baseAddress, $0.count)
                }
            },
            clearTunnel: { thiz, tun in
                clear_tunnel(thiz, tun)
            },
            testCallback: { thiz in
                test_callback(thiz)
            }
        )
    }
}

#endif
