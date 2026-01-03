// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

// Wrap in OS target conditionals when each daemon will have its implementation
// #if canImport(Darwin)
// #if os(Android)
// #if os(Linux)
// #if os(Windows)

#if !os(iOS) && !os(tvOS)

internal import _PartoutCore_C

func makeDaemon(
    with profile: Profile,
    registry: Registry,
    ctrlImpl: UnsafeMutableRawPointer?
) throws -> SimpleConnectionDaemon {
    let ctx = PartoutLoggerContext(profile.id)
    let factory = POSIXInterfaceFactory(ctx) {
        PassthroughStream()
    }
    let controllerImpl = try VirtualTunnelController(ctx, impl: ctrlImpl)
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
