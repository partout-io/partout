// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

// Wrap in OS target conditionals when each daemon will have its implementation
// #if PARTOUT_MONOLITH || canImport(Darwin)
// #if PARTOUT_MONOLITH || os(Android)
// #if PARTOUT_MONOLITH || os(Linux)
// #if PARTOUT_MONOLITH || os(Windows)

#if !os(iOS) && !os(tvOS)

import _PartoutABI_C
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

#endif
