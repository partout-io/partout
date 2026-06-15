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
    static func registerDefaultLogger() {
        var logger = PartoutLogger.Builder()
        logger.setDestination(
            SimpleLogDestination(tag: nil),
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
        block: @escaping @Sendable @PartoutABI (RunCallback) async -> Void
    ) {
        let completer = RunCallback(completion: completion)
        Task { @PartoutABI in
            await block(completer)
        }
    }
}

extension ABI {
    struct RunCallback: @unchecked Sendable {
        private let completion: partout_completion

        fileprivate init(completion: partout_completion) {
            self.completion = completion
        }

        func complete(_ code: partout_completion_code) {
            completion.callback?(completion.ctx, code, nil)
        }

        func complete<T>(_ code: partout_completion_code, payload: T) where T: Encodable {
            let payloadJSON: String?
            do {
                payloadJSON = try JSONEncoder.shared().encodeJSON(payload)
            } catch {
                pp_log_g(.abi, .error, "Unable to encode returned payload: \(error)")
                payloadJSON = nil
            }
            completion.callback?(completion.ctx, code, payloadJSON)
        }
    }
}
