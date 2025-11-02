// SPDX-FileCopyrightText: 2025 Davide De Rosa
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

    private var pendingStrategy: SimpleDNSStrategy?

    public init(strategy: @escaping (String) -> SimpleDNSStrategy) {
        self.strategy = strategy
    }

    public func resolve(_ hostname: String, timeout: Int) async throws -> [DNSRecord] {
        if pendingStrategy != nil {
            await pendingStrategy?.cancelResolution()
            _ = try? await pendingStrategy?.waitForResolution()
        }

        let newStrategy = strategy(hostname)
        let timeoutTask = Task {
            try await Task.sleep(milliseconds: timeout)
            guard !Task.isCancelled else {
                return
            }
            await newStrategy.cancelResolution()
        }

        self.pendingStrategy = newStrategy
        try await newStrategy.startResolution()
        let result = try await newStrategy.waitForResolution()
        timeoutTask.cancel()
        pendingStrategy = nil
        return result
    }
}
