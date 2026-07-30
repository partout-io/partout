// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// The strategy for a ``SimpleDNSResolver``.
public protocol SimpleDNSStrategy: Sendable {
    func startResolution() async throws

    func waitForResolution(reachability: ReachabilityInfo?) async throws -> [DNSRecord]

    func cancelResolution() async
}

/// ``DNSResolver`` with support for timeout cancellation.
public actor SimpleDNSResolver: DNSResolver {
    private struct PendingKey: Hashable, Sendable {
        let hostname: String
        let flags: Set<DNSResolverFlag>

        init(_ hostname: String, _ flags: Set<DNSResolverFlag>) {
            self.hostname = hostname
            self.flags = flags
        }
    }

    private let strategy: (String, Set<DNSResolverFlag>) -> SimpleDNSStrategy

    private var pendingResolutions: [PendingKey: Task<[DNSRecord], Error>]

    public init(strategy: @escaping (String, Set<DNSResolverFlag>) -> SimpleDNSStrategy) {
        self.strategy = strategy
        pendingResolutions = [:]
    }

    public func resolve(
        _ hostname: String,
        flags: Set<DNSResolverFlag>,
        reachability: ReachabilityInfo?,
        timeout: Int
    ) async throws -> [DNSRecord] {
        let key = PendingKey(hostname, flags)
        if let pendingResolutionTask = pendingResolutions[key] {
            return try await pendingResolutionTask.value
        }
        let newStrategy = strategy(hostname, flags)
        let resolutionTask = Task {
            try await newStrategy.startResolution()
            return try await Self.waitForResolution(
                newStrategy,
                reachability: reachability,
                timeout: timeout
            )
        }
        pendingResolutions[key] = resolutionTask
        defer {
            pendingResolutions.removeValue(forKey: key)
        }
        return try await resolutionTask.value
    }
}

private extension SimpleDNSResolver {
    nonisolated static func waitForResolution(
        _ strategy: SimpleDNSStrategy,
        reachability: ReachabilityInfo?,
        timeout: Int
    ) async throws -> [DNSRecord] {
        try await withCheckedThrowingContinuation { continuation in
            let state = DNSResolutionState(continuation: continuation)
            // Keep this unstructured. Blocking DNS resolution may ignore
            // cancellation, and a task group would still wait for that
            // child before returning the timeout.
            let waitTask = Task {
                do {
                    let records = try await strategy.waitForResolution(
                        reachability: reachability
                    )
                    await state.resume(with: .success(records))
                } catch {
                    await state.resume(with: .failure(error))
                }
            }
            let timeoutTask = Task {
                do {
                    try await Task.sleep(milliseconds: timeout)
                } catch {
                    return
                }
                await strategy.cancelResolution()
                await state.resume(with: .failure(PartoutError(.timeout)))
            }
            Task {
                await state.setTasks(waitTask: waitTask, timeoutTask: timeoutTask)
            }
        }
    }
}

private actor DNSResolutionState {
    private var continuation: CheckedContinuation<[DNSRecord], Error>?

    private var waitTask: Task<Void, Never>?

    private var timeoutTask: Task<Void, Never>?

    init(continuation: CheckedContinuation<[DNSRecord], Error>) {
        self.continuation = continuation
    }

    func setTasks(waitTask: Task<Void, Never>, timeoutTask: Task<Void, Never>) {
        guard continuation != nil else {
            waitTask.cancel()
            timeoutTask.cancel()
            return
        }
        self.waitTask = waitTask
        self.timeoutTask = timeoutTask
    }

    func resume(with result: Result<[DNSRecord], Error>) {
        guard let continuation else { return }
        self.continuation = nil
        waitTask?.cancel()
        timeoutTask?.cancel()
        waitTask = nil
        timeoutTask = nil
        switch result {
        case .success(let records):
            continuation.resume(returning: records)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
