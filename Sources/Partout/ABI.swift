// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import _PartoutOSPortable_C
import Foundation
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

var ctx: ABIContext?

// FIXME: #188, ABI is still optimistic
//
// - doesn't handle concurrency
// - doesn't check preconditions like double start/stop calls
// - doesn't exit on async failure becuase exceptions are thrown inside tasks
// - doesn't handle interrupts/signals (should exit or at least handle them)
//

@_cdecl("partout_version")
public func partout_version() -> UnsafePointer<CChar> {
    UnsafePointer(pp_dup(Partout.version))
}

@_cdecl("partout_initialize")
public func partout_initialize(cCacheDir: UnsafePointer<CChar>) -> UnsafeMutableRawPointer {
    let cacheDir = String(cString: cCacheDir)

    var logBuilder = PartoutLogger.Builder()
    // FIXME: #187, check defines for conditional areas
    logBuilder.setDestination(NSLogDestination(), for: [
        .core,
        .api,
        .providers,
        //.ne,
        .openvpn
        //.wireguard
    ])
    logBuilder.logsAddresses = true
    PartoutLogger.register(logBuilder.build())

    let registry = Registry(withKnown: true, allImplementations: [
        OpenVPNModule.Implementation(
            importer: StandardOpenVPNParser(),
            connectionBlock: {
                let ctx = PartoutLoggerContext($0.controller.profile.id)
                return try OpenVPNConnection(
                    ctx,
                    parameters: $0,
                    module: $1,
                    cachesURL: URL(fileURLWithPath: cacheDir)
                )
            }
        )
        // FIXME: #118, support WireGuard
        // WireGuardModule.Implementation(
        //     keyGenerator: StandardWireGuardKeyGenerator(),
        //     importer: StandardWireGuardParser(),
        //     validator: StandardWireGuardParser(),
        //     connectionBlock: {
        //         let ctx = PartoutLoggerContext($0.controller.profile.id)
        //         return try WireGuardConnection(
        //             ctx,
        //             parameters: $0,
        //             module: $1
        //         )
        //     }
        // )
    ])

    let ctx = ABIContext(registry: registry)
    return ctx.toOpaque
}

@_cdecl("partout_daemon_start")
public func partout_daemon_start(cCtx: UnsafeMutableRawPointer, cProfile: UnsafePointer<CChar>) -> Int {
    let ctx = ABIContext.fromOpaque(cCtx)

    // Profile is a command line argument
    let daemon: SimpleConnectionDaemon
    do {
        let contents = String(cString: cProfile)
        let module = try ctx.registry.module(fromContents: contents, object: nil)
        var builder = Profile.Builder()
        builder.modules = [module]
        builder.activateAllModules()
        let profile = try builder.tryBuild()

        daemon = try makeDaemon(with: profile, registry: ctx.registry)
    } catch {
        pp_log_g(.core, .error, "Unable to create daemon: \(error)")
        return -1
    }

    // Throws .unknownImportedModule if missing implementation
    //let ovpnCfg = try StandardOpenVPNParser().parsed(fromContents: str).configuration
    //let ovpn = try OpenVPNModule.Builder(configurationBuilder: ovpnCfg.builder()).tryBuild()
    //print(ovpn)

    // This task is short-lived
    Task {
        do {
            // try await Task.sleep(interval: 3.0)
            try await daemon.start()
            ctx.daemon = daemon
        } catch {
            pp_log_g(.core, .error, "Unable to start daemon: \(error)")
            exit(-1)
        }
    }

    return 0
}

@_cdecl("partout_daemon_stop")
public func partout_daemon_stop(cCtx: UnsafeMutableRawPointer) {
    let ctx = ABIContext.fromOpaque(cCtx)
    Task {
        await ctx.daemon?.stop()
        ctx.daemon = nil
    }
}
