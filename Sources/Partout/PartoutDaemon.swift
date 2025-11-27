// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

// Wrap in OS target conditionals when each daemon will have its implementation
// #if PARTOUT_MONOLITH || canImport(Darwin)
// #if PARTOUT_MONOLITH || os(Android)
// #if PARTOUT_MONOLITH || os(Linux)
// #if PARTOUT_MONOLITH || os(Windows)

#if !os(iOS) && !os(tvOS)

import PartoutABI_C
#if !PARTOUT_MONOLITH
import PartoutCore
import PartoutOS
#endif

func makeDaemon(
    with profile: Profile,
    registry: Registry,
    ctrl: partout_tun_ctrl?
) throws -> SimpleConnectionDaemon {
    let ctx = PartoutLoggerContext(profile.id)
    let factory = POSIXInterfaceFactory(ctx) {
        PassthroughStream()
    }
    let controllerImpl = try VirtualTunnelController(ctx, ctrl: ctrl?.asPartoutCtrl)
    let reachability = DummyReachabilityObserver()
    let environment = SharedTunnelEnvironment(profileId: profile.id)
    let messageHandler = DefaultMessageHandler(ctx, environment: environment)
    let connParams = ConnectionParameters(
        profile: profile,
        controller: controllerImpl,
        factory: factory,
        reachability: reachability,
        environment: environment,
        options: ConnectionParameters.Options()
    )
    let params = SimpleConnectionDaemon.Parameters(
        registry: registry,
        connectionParameters: connParams,
        reachability: reachability,
        messageHandler: messageHandler,
        stopDelay: 2000,
        reconnectionDelay: 3000
    )
    return try SimpleConnectionDaemon(params: params)
}

private extension partout_tun_ctrl {
    var asPartoutCtrl: VirtualTunnelControllerImpl {
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
