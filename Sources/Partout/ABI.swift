// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !os(iOS) && !os(tvOS)

import PartoutABI_C
internal import _PartoutCore_C

/// The actor that all ABI methods execute on.
@globalActor
public actor ABIActor {
    public static let shared = ABIActor()
}

// FIXME: #188, ABI is still optimistic
//
// - should receive callback arguments for completion and error handling
// - doesn't handle concurrency
// - doesn't check preconditions like double start/stop calls
// - doesn't exit on async failure becuase exceptions are thrown inside tasks
// - doesn't handle interrupts/signals (should exit or at least handle them)
//

@_cdecl("partout_version")
public func __partout_version() -> UnsafePointer<CChar>! {
    PARTOUT_VERSION
}

/// Initializes the library and returns a opaque context for use with subsequent calls.
@_cdecl("partout_init")
@ABIActor
public func __partout_init(cArgs: UnsafePointer<partout_init_args>!) -> UnsafeMutableRawPointer! {
    pp_log_g(.core, .debug, "Initialize")

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
                module: $1,
                preferringIPv4: true
            )
        }
    ))
#endif

    // Finalize configuration
    logBuilder.setDestination(SimpleLogDestination(), for: logCategories)
    logBuilder.logsAddresses = true
    logBuilder.logsModules = true
    PartoutLogger.register(logBuilder.build())

    // Test callback
    if let callback = cArgs.pointee.test_callback {
        pp_log_g(.core, .debug, "Test callback...")
        callback()
        pp_log_g(.core, .debug, "Callback successful!")
    }

    // Create global context
    let registry = Registry(withKnown: true, allImplementations: allImplementations)
    let ctx = ABIContext(registry: registry)
    let cCtx = ctx.push()
    pp_log_g(.core, .debug, "Initialize with ctx: \(cCtx)")
    return cCtx
}

/// Deinitializes the library context created with ``partout_init(cArgs:)``.
@_cdecl("partout_deinit")
@ABIActor
public func __partout_deinit(cCtx: UnsafeMutableRawPointer!) {
    ABIContext.pop(cCtx)
}

/// Starts the connection daemon.
@_cdecl("partout_daemon_start")
@ABIActor
public func __partout_daemon_start(
    cCtx: UnsafeMutableRawPointer!,
    cArgs: UnsafePointer<partout_daemon_start_args>!
) -> Bool {
    pp_log_g(.core, .debug, "Start daemon with ctx: \(cCtx.debugDescription)")
    let ctx = ABIContext.peek(cCtx)
    pp_log_g(.core, .debug, "Start daemon with ctx (ABIContext): \(ctx)")

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

        // Parse profile first, then module
        let profile: Profile
        do {
            profile = try ctx.registry.profile(fromJSON: contents)
        } catch {
            pp_log_g(.core, .error, "Unable to parse profile, trying module: \(error)")

            let module = try ctx.registry.module(fromContents: contents, object: nil)
            var builder = Profile.Builder()
            builder.modules = [module]
            builder.activateAllModules()
            profile = try builder.build()
        }

        // Optional reference to tunnel controller implementation (e.g. JNI wrapper)
        let ctrlImpl = cArgs.pointee.ctrl_impl

        daemon = try makeDaemon(with: profile, registry: ctx.registry, ctrlImpl: ctrlImpl)
    } catch {
        pp_log_g(.core, .error, "Unable to create daemon: \(error)")
        return false
    }

    // Throws .unknownImportedModule if missing implementation
    // let ovpnCfg = try StandardOpenVPNParser().parsed(fromContents: str).configuration
    // let ovpn = try OpenVPNModule.Builder(configurationBuilder: ovpnCfg.builder()).build()
    // print(ovpn)

    // This task is short-lived
    Task {
        // try await Task.sleep(interval: 3.0)
        do {
            try await ctx.startDaemon(daemon)
        } catch {
            pp_log_g(.core, .error, "Unable to start daemon: \(error)")
            exit(-1)
        }
    }

    return true
}

/// Stops the connection daemon.
@_cdecl("partout_daemon_stop")
@ABIActor
public func __partout_daemon_stop(cCtx: UnsafeMutableRawPointer!) {
    pp_log_g(.core, .debug, "Stop daemon with ctx: \(cCtx.debugDescription)")
    let ctx = ABIContext.peek(cCtx)
    pp_log_g(.core, .debug, "Stop daemon with ctx (ABIContext): \(ctx)")
    Task {
        await ctx.stopDaemon()
    }
}

/// Logs to the global context from C code.
@_cdecl("partout_log")
@ABIActor
public func __partout_log(cLevel: Int32, cMessage: UnsafePointer<CChar>!) {
    let category: LoggerCategory = .abi
    let level = DebugLog.Level(rawValue: Int(cLevel)) ?? .info
    let message = String(cString: cMessage)
    pp_log_g(category, level, message)
}

private extension LoggerCategory {
    static let abi = Self(rawValue: "abi")
}

#endif
