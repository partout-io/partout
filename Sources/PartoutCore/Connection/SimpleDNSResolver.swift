// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// The strategy for a ``SimpleDNSResolver``.
public protocol SimpleDNSStrategy: Sendable {
    func startResolution() async throws

    func waitForResolution() async throws -> [DNSRecord]

    func cancelResolution() async
}

/// ``DNSResolver`` with support for timeout cancellation.
public actor SimpleDNSResolver: DNSResolver {
    private let strategy: (String) -> SimpleDNSStrategy

    private var pendingResolutions: [String: Task<[DNSRecord], Error>]

    public init(strategy: @escaping (String) -> SimpleDNSStrategy) {
        self.strategy = strategy
        pendingResolutions = [:]
    }

    public func resolve(_ hostname: String, timeout: Int) async throws -> [DNSRecord] {
        if let pendingResolutionTask = pendingResolutions[hostname] {
            return try await pendingResolutionTask.value
        }
        let newStrategy = strategy(hostname)
        let timeoutTask = Task {
            try await Task.sleep(milliseconds: timeout)
            guard !Task.isCancelled else { return }
            await newStrategy.cancelResolution()
        }
        let resolutionTask = Task {
            try await newStrategy.startResolution()
            let result = try await newStrategy.waitForResolution()
            timeoutTask.cancel()
            return result
        }
        pendingResolutions[hostname] = resolutionTask
        defer {
            pendingResolutions.removeValue(forKey: hostname)
        }
        return try await resolutionTask.value
    }
}
