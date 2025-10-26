// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !os(iOS) && !os(tvOS)

import Foundation
import PartoutABI_C
import PartoutCore_C
#if !PARTOUT_MONOLITH
import PartoutCore
import PartoutOS
#endif

@globalActor
actor ABIActor {
    static let shared = ABIActor()
}

// FIXME: #188, ABI is still optimistic
//
// - should receive callback arguments for completion and error handling
// - doesn't handle concurrency
// - doesn't check preconditions like double start/stop calls
// - doesn't exit on async failure becuase exceptions are thrown inside tasks
// - doesn't handle interrupts/signals (should exit or at least handle them)
//

@_cdecl("partout_init")
@ABIActor
public func partout_init(cArgs: UnsafePointer<partout_init_args>) -> UnsafeMutableRawPointer {
    pp_log_g(.core, .debug, "Partout: Initialize")

    // Test callback
    if let callback = cArgs.pointee.test_callback {
        pp_log_g(.core, .debug, "Partout: Test callback...")
        callback()
        pp_log_g(.core, .debug, "Partout: Callback successful!")
    }

    // Global directory e.g. for temporary files
    let cacheDir = String(cString: cArgs.pointee.cache_dir)

    // Logging and implementations, consider optionals
    var logBuilder = PartoutLogger.Builder()
    var logCategories: [LoggerCategory] = [.core, .os]
    var allImplementations: [ModuleImplementation] = []

#if PARTOUT_OPENVPN
    logCategories.append(.openvpn)
    allImplementations.append(OpenVPNModule.Implementation(
        importerBlock: { StandardOpenVPNParser() },
        connectionBlock: {
            let ctx = PartoutLoggerContext($0.profile.id)
            return try OpenVPNConnection(
                ctx,
                parameters: $0,
                module: $1,
                cachesURL: URL(fileURLWithPath: cacheDir)
            )
        }
    ))
#endif
#if PARTOUT_WIREGUARD
    logCategories.append(.wireguard)
    allImplementations.append(WireGuardModule.Implementation(
        keyGenerator: StandardWireGuardKeyGenerator(),
        importerBlock: { StandardWireGuardParser() },
        validatorBlock: { StandardWireGuardParser() },
        connectionBlock: {
            let ctx = PartoutLoggerContext($0.profile.id)
            return try WireGuardConnection(
                ctx,
                parameters: $0,
                module: $1
            )
        }
    ))
#endif

    // Finalize configuration
    logBuilder.setDestination(NSLogDestination(), for: logCategories)
    logBuilder.logsAddresses = true
    logBuilder.logsModules = true
    PartoutLogger.register(logBuilder.build())
    let registry = Registry(withKnown: true, allImplementations: allImplementations)

    // Create global context
    let ctx = ABIContext(registry: registry)
    let cCtx = ctx.push()
    pp_log_g(.core, .debug, "Partout: Initialize with ctx: \(cCtx)")
    return cCtx
}

@_cdecl("partout_deinit")
@ABIActor
public func partout_deinit(cCtx: UnsafeMutableRawPointer) {
    ABIContext.pop(cCtx)
}

@_cdecl("partout_daemon_start")
@ABIActor
public func partout_daemon_start(
    cCtx: UnsafeMutableRawPointer,
    cArgs: UnsafePointer<partout_daemon_start_args>
) -> Int {
    pp_log_g(.core, .debug, "Partout: Start daemon with ctx: \(cCtx)")
    let ctx = ABIContext.peek(cCtx)
    pp_log_g(.core, .debug, "Partout: Start daemon with ctx (ABIContext): \(ctx)")

    // Profile is a command line argument
    let daemon: SimpleConnectionDaemon
    do {
        let contents: String
        if let cProfile = cArgs.pointee.profile {
            contents = String(cString: cProfile)
        } else if let cProfilePath = cArgs.pointee.profile_path {
            let path = String(cString: cProfilePath)
            contents = try String(contentsOfFile: path, encoding: .utf8)
        } else {
            throw PartoutError(.notFound)
        }
        let module = try ctx.registry.module(fromContents: contents, object: nil)
        var builder = Profile.Builder()
        builder.modules = [module]
        builder.activateAllModules()
        let profile = try builder.tryBuild()

        // Map tunnel controller to external C functions (optional)
        let ctrl = cArgs.pointee.ctrl.map(\.pointee)

        daemon = try makeDaemon(with: profile, registry: ctx.registry, ctrl: ctrl)
    } catch {
        pp_log_g(.core, .error, "Partout: Unable to create daemon: \(error)")
        return -1
    }

    // Throws .unknownImportedModule if missing implementation
    // let ovpnCfg = try StandardOpenVPNParser().parsed(fromContents: str).configuration
    // let ovpn = try OpenVPNModule.Builder(configurationBuilder: ovpnCfg.builder()).tryBuild()
    // print(ovpn)

    // This task is short-lived
    Task {
        // try await Task.sleep(interval: 3.0)
        do {
            try await ctx.startDaemon(daemon)
        } catch {
            pp_log_g(.core, .error, "Partout: Unable to start daemon: \(error)")
            exit(-1)
        }
    }

    return 0
}

@_cdecl("partout_daemon_stop")
@ABIActor
public func partout_daemon_stop(cCtx: UnsafeMutableRawPointer) {
    pp_log_g(.core, .debug, "Partout: Stop daemon with ctx: \(cCtx)")
    let ctx = ABIContext.peek(cCtx)
    pp_log_g(.core, .debug, "Partout: Stop daemon with ctx (ABIContext): \(ctx)")
    Task {
        await ctx.stopDaemon()
    }
}

#endif
