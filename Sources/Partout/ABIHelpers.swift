// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Partout_C

#if canImport(Darwin)
public typealias PartoutABI = MainActor
#else
@globalActor
public actor PartoutABI: GlobalActor {
    public static let shared = PartoutABI()
}
#endif

// Run ABI initialization synchronously.
//
// WARNING: This method is potentially DANGEROUS and fights Concurrency
// only to simplify the app initialization flow. Any other ABI function
// MUST NEVER block the current thread. Use run() variants instead.
//
enum ABI {
    static func registerDefaultLogger(tag: String?, logsPrivateData: Bool) {
        var logger = PartoutLogger.Builder()
        logger.logsAddresses = logsPrivateData
        logger.logsModules = logsPrivateData
        logger.setDestination(
            SimpleLogDestination(tag: tag),
            for: LoggerCategory.partoutCategories
        )
        PartoutLogger.register(logger.build())
    }

    static func runBlocking(
        _ block: @escaping @Sendable @PartoutABI () async -> partout_completion_code
    ) -> partout_completion_code {
        let isABIRunningOnMainThread = PartoutABI.self == MainActor.self
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result = PartoutCompletionCodeFailure
        Task { @Sendable @PartoutABI in
            result = await block()
            semaphore.signal()
        }
#if canImport(Darwin)
        // ABI code runs on MainActor on macOS
        guard isABIRunningOnMainThread else {
            fatalError("ABI actor must be MainActor")
        }
        // Yield the main thread otherwise the block() invocation may deadlock
        // on the first async call to business objects, as they run on MainActor
        let isMainThread = pthread_main_np() == 1
        if isMainThread {
            let yield = 0.001
            while semaphore.wait(timeout: .now()) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: yield))
            }
            return result
        }
#else
        // Ensure that non-Apple business runs off of MainActor
        // because other UI engines may lock the main thread
        guard !isABIRunningOnMainThread else {
            fatalError("ABI actor must not be MainActor")
        }
#endif
        semaphore.wait()
        return result
    }

    static func run(
        _ completion: partout_completion,
        block: @escaping @Sendable @PartoutABI (partout_completion) async -> Void
    ) {
        nonisolated(unsafe) let unsafeCompletion = completion
        Task { @Sendable @PartoutABI in
            await block(unsafeCompletion)
        }
    }
}

extension partout_completion {
    func arguments(name: String) {
        complete(PartoutCompletionCodeArgs, name)
    }

    func succeed() {
        complete(PartoutCompletionCodeOK)
    }

    func succeed<T>(_ payload: T) where T: Encodable {
        complete(PartoutCompletionCodeOK, payload)
    }

    func fail() {
        complete(PartoutCompletionCodeFailure)
    }

    func fail(_ error: Error) {
        complete(PartoutCompletionCodeFailure, ABIErrorPayload(error))
    }
}

private extension partout_completion {
    func complete(_ code: partout_completion_code) {
        callback?(ctx, code, nil)
    }

    func complete<T>(_ code: partout_completion_code, _ payload: T) where T: Encodable {
        let payloadJSON: String?
        do {
            payloadJSON = try JSONEncoder.shared().encodeJSON(payload)
        } catch {
            pp_log_g(.abi, .error, "Unable to encode returned payload: \(error)")
            payloadJSON = nil
        }
        callback?(ctx, code, payloadJSON)
    }
}

func stringsFromCStrings(
    _ ptrs: UnsafePointer<UnsafePointer<CChar>?>?,
    count: Int
) -> [String] {
    (0..<count)
        .compactMap { i in
            ptrs?[i].map {
                String(cString: $0)
            }
        }
}
