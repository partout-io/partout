// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

extension EndpointResolver {
    struct Resolvable: Sendable {
        private let ctx: PartoutLoggerContext

        let originalEndpoint: ExtendedEndpoint

        private let resolvedEndpoints: [ExtendedEndpoint]

        let isResolved: Bool

        var currentEndpoint: ExtendedEndpoint? {
            resolvedEndpoints.first
        }

        init(_ ctx: PartoutLoggerContext, _ originalEndpoint: ExtendedEndpoint) {
            self.init(ctx, originalEndpoint, resolvedRecords: nil)
        }

        init(_ ctx: PartoutLoggerContext, _ originalEndpoint: ExtendedEndpoint, resolvedRecords: [DNSRecord]?) {
            let resolvedEndpoints: [ExtendedEndpoint]
            let isResolved: Bool
            if let resolvedRecords {
                resolvedEndpoints = originalEndpoint.unrolledEndpoints(ctx, records: resolvedRecords)
                isResolved = true
            } else {
                resolvedEndpoints = []
                isResolved = false
            }
            self.init(ctx, originalEndpoint: originalEndpoint, resolvedEndpoints: resolvedEndpoints, isResolved: isResolved)
        }

        fileprivate init(_ ctx: PartoutLoggerContext, originalEndpoint: ExtendedEndpoint, resolvedEndpoints: [ExtendedEndpoint], isResolved: Bool) {
            self.ctx = ctx
            self.originalEndpoint = originalEndpoint
            self.resolvedEndpoints = resolvedEndpoints
            self.isResolved = isResolved
        }

        func resolved(with dns: DNSResolver, timeout: Int) async throws -> Self {
            let records = try await dns.resolve(originalEndpoint.address.rawValue, timeout: timeout)
            pp_log(ctx, .core, .notice, "DNS resolved addresses: \(records.map { $0.address.asSensitiveAddress(ctx) })")
            return with(newResolvedEndpoints: originalEndpoint.unrolledEndpoints(ctx, records: records))
        }
    }
}

extension EndpointResolver.Resolvable {
    func with(newResolvedEndpoints: [ExtendedEndpoint]) -> Self {
        EndpointResolver.Resolvable(
            ctx,
            originalEndpoint: originalEndpoint,
            resolvedEndpoints: newResolvedEndpoints,
            isResolved: true
        )
    }

    func withNextEndpoint() -> Self? {
        guard !resolvedEndpoints.isEmpty else {
            return nil
        }
        return EndpointResolver.Resolvable(
            ctx,
            originalEndpoint: originalEndpoint,
            resolvedEndpoints: Array(resolvedEndpoints.suffix(from: 1)),
            isResolved: isResolved
        )
    }
}

private extension ExtendedEndpoint {
    func unrolledEndpoints(_ ctx: PartoutLoggerContext, records: [DNSRecord]) -> [ExtendedEndpoint] {
        let endpoints = records
            .filter {
                $0.isCompatible(withProtocol: proto)
            }
            .compactMap {
                do {
                    return try ExtendedEndpoint($0.address, proto)
                } catch {
                    pp_log(ctx, .core, .error, "Malformed endpoint: \($0.address.asSensitiveAddress(ctx))")
                    return nil
                }
            }

        pp_log(ctx, .core, .notice, "Unrolled endpoints: \(endpoints.map { $0.asSensitiveAddress(ctx) })")
        return endpoints
    }
}

// MARK: - SensitiveDebugStringConvertible

extension EndpointResolver.Resolvable: SensitiveDebugStringConvertible {
    public func encode(to encoder: Encoder) throws {
        try encodeSensitiveDescription(to: encoder)
    }

    func debugDescription(withSensitiveData: Bool) -> String {
        let endpointDescription = originalEndpoint.debugDescription(withSensitiveData: withSensitiveData)
        let resolvedEndpointsDescription = resolvedEndpoints.map { $0.debugDescription(withSensitiveData: withSensitiveData)
        }
        return "{\(endpointDescription), isResolved: \(isResolved), endpoints: \(resolvedEndpointsDescription)}"
    }
}

// MARK: - Helpers

private extension DNSRecord {
    func isCompatible(withProtocol proto: EndpointProtocol) -> Bool {
        if isIPv6 {
            return proto.socketType != .udp4 && proto.socketType != .tcp4
        } else {
            return proto.socketType != .udp6 && proto.socketType != .tcp6
        }
    }
}
