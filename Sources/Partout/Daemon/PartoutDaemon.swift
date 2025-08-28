// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

// Wrap in OS target conditionals when each daemon will have its implementation
//#if PARTOUT_MONOLITH || canImport(_PartoutOSAndroid)
//#if PARTOUT_MONOLITH || canImport(_PartoutOSApple)
//#if PARTOUT_MONOLITH || canImport(_PartoutOSLinux)
//#if PARTOUT_MONOLITH || canImport(_PartoutOSWindows)

#if !PARTOUT_MONOLITH
import PartoutCore
import _PartoutOSWrapper
#endif

public func makeDaemon(with profile: Profile, registry: Registry) throws -> SimpleConnectionDaemon {
    let ctx = PartoutLoggerContext(profile.id)
    let factory = POSIXInterfaceFactory(ctx) {
        PassthroughStream()
    }
    let tun = DummyTunnelinterface()
    let controller = DummyTunnelController(profile: profile)
    let reachability = DummyReachabilityObserver()

    let environment = SharedTunnelEnvironment(profileId: profile.id)
    let messageHandler = DefaultMessageHandler(ctx, environment: environment)
    let connParams = ConnectionParameters(
        controller: controller,
        factory: factory,
        tunnelInterface: tun,
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
