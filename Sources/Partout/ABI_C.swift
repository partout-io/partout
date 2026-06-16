// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutPortable_C
import Partout_C

// MARK: Daemon

nonisolated(unsafe)
private var globalDaemon: ABIDaemon?

@c(partout_init)
public func __partout_init(
    cTag: UnsafePointer<CChar>?
) {
    let tag = cTag.map { String(cString: $0) }
    ABI.registerDefaultLogger(tag: tag)
}

@c(partout_daemon_start)
public func __partout_daemon_start(
    argsPointer: UnsafePointer<partout_daemon_start_args>?
) -> partout_completion_code {
    guard globalDaemon == nil else {
        fatalError("Daemon already started")
    }
    guard let args = argsPointer?.pointee else {
        return PartoutCompletionCodeArgs
    }
    let options: ABIDaemon.Options
    nonisolated(unsafe) let bindings = args.bindings?.pointee
    do {
        options = try ABIDaemon.Options(args)
    } catch {
        pp_log_g(.abi, .fault, "Unable to decode args: \(error)")
        return PartoutCompletionCodeArgs
    }
    let result = ABI.runBlocking {
        do {
            globalDaemon = try ABIDaemon(options: options, bindings: bindings)
            try await globalDaemon?.start()
            return PartoutCompletionCodeOK
        } catch {
            pp_log_id(options.profile.id, .abi, .fault, "Unable to start daemon: \(error)")
            await globalDaemon?.stop()
            globalDaemon = nil
            return PartoutCompletionCodeFailure
        }
    }
    if result == PartoutCompletionCodeOK, options.isDaemon {
        lockProcess()
    }
    return result
}

@c(partout_daemon_stop)
public func __partout_daemon_stop(completion: partout_completion) {
    guard globalDaemon != nil else {
        assertionFailure("Daemon not started")
        return
    }
    ABI.run(completion) { callback in
        await globalDaemon?.stop()
        globalDaemon = nil
        callback.succeed()
    }
}

private func lockProcess() {
#if canImport(Darwin)
    CFRunLoopRun()
#else
    // Block main thread indefinitely to keep the process running
    let semaphore = DispatchSemaphore(value: 0)
    semaphore.wait()
#endif
}

// MARK: - Stateless

@c(partout_import_profile)
public func __partout_import_profile(
    cText: UnsafePointer<CChar>?,
    cName: UnsafePointer<CChar>?,
    completion: partout_completion
) {
    guard let cText else {
        completion.arguments(name: "text")
        return
    }
    let text = String(cString: cText)
    let name = cName.map { String(cString: $0) }
    ABI.run(completion) { callback in
        let registry = Registry.forImport(.global)
        let coding = CodingRegistry(registry: registry, withLegacyEncoding: { false })
        do {
            let profile = try coding.profileOrModule(fromString: text, name: name)
            callback.succeed(profile.asTaggedProfile)
        } catch {
            callback.fail(error.localizedDescription)
        }
    }
}

@c(partout_readfile)
public func __partout_readfile(
    cRelativePath: UnsafePointer<CChar>?,
    cParent: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    guard let cRelativePath else { return nil }
    return pp_file_read(cRelativePath, cParent)
}
