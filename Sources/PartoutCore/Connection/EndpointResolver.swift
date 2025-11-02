// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Cycles through a list of DNS-resolvable endpoints.
public struct EndpointResolver: Sendable {
    private let ctx: PartoutLoggerContext

    let currentResolvable: Resolvable?

    private let nextResolvables: [Resolvable]

    public init(_ ctx: PartoutLoggerContext, endpoints: [ExtendedEndpoint]) {
        precondition(!endpoints.isEmpty)
        self.init(ctx, resolvables: endpoints.map {
            Resolvable(ctx, $0)
        })
    }

    init(_ ctx: PartoutLoggerContext, resolvables: [Resolvable]) {
        precondition(!resolvables.isEmpty)
        self.ctx = ctx
        currentResolvable = resolvables.first
        nextResolvables = Array(resolvables.suffix(from: 1))
    }

    init(_ ctx: PartoutLoggerContext, currentResolvable: Resolvable?, nextResolvables: [Resolvable]) {
        self.ctx = ctx
        self.currentResolvable = currentResolvable
        self.nextResolvables = nextResolvables
    }

    public func withNextEndpoint(
        dns: DNSResolver,
        timeout: Int
    ) async throws -> (nextResolver: Self, endpoint: ExtendedEndpoint) {
        var copy = self
        var lastError: Error?

        while true {
            guard let currentResolvable = copy.currentResolvable else {
                pp_log(ctx, .core, .info, "Exhausted endpoints")
                throw PartoutError(.exhaustedEndpoints)
            }

            if currentResolvable.isResolved {
                if let endpoint = currentResolvable.currentEndpoint {
                    pp_log(ctx, .core, .info, "Try current endpoint in current resolvable: \(currentResolvable.asSensitiveAddress(ctx))")
                    return (copy.withNextEndpoint(in: currentResolvable), endpoint)
                }
            } else {
                pp_log(ctx, .core, .info, "Try DNS resolution: \(currentResolvable.asSensitiveAddress(ctx))")
                let newResolvable: EndpointResolver.Resolvable
                do {
                    newResolvable = try await currentResolvable.resolved(with: dns, timeout: timeout)
                } catch {
                    pp_log(ctx, .core, .fault, "DNS resolution failed: \(error)")
                    newResolvable = currentResolvable.with(newResolvedEndpoints: [])
                    lastError = error
                }
                if let endpoint = newResolvable.currentEndpoint {
                    return (copy.withNextEndpoint(in: newResolvable), endpoint)
                }
            }

            pp_log(ctx, .core, .info, "Try next endpoint in current resolvable: \(currentResolvable.asSensitiveAddress(ctx))")
            if let newResolvable = currentResolvable.withNextEndpoint() {
                guard let endpoint = newResolvable.currentEndpoint else {
                    fatalError("withNextEndpoint succeeds but has no currentEndpoint?")
                }
                let resolver = copy.withNextEndpoint(in: newResolvable)
                return (resolver, endpoint)
            }

            pp_log(ctx, .core, .info, "Exhausted endpoints in current resolvable, advance to next resolvable")
            guard !copy.nextResolvables.isEmpty else {
                pp_log(ctx, .core, .info, "Exhausted endpoints")
                if let lastError {
                    throw PartoutError(.exhaustedEndpoints, lastError)
                }
                throw PartoutError(.exhaustedEndpoints)
            }
            copy = copy.withNextResolvable()
        }
    }
}

extension EndpointResolver {
    func withNextEndpoint(in resolvable: Resolvable) -> Self {
        EndpointResolver(
            ctx,
            currentResolvable: resolvable.withNextEndpoint(),
            nextResolvables: nextResolvables
        )
    }

    func withNextResolvable() -> Self {
        EndpointResolver(
            ctx,
            currentResolvable: nextResolvables.first,
            nextResolvables: Array(nextResolvables.suffix(from: 1))
        )
    }
}
