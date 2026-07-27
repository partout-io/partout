// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutPortable_C

/// Implementation of ``SimpleDNSStrategy`` with the POSIX C library.
public actor POSIXDNSStrategy: SimpleDNSStrategy {
    private let hostname: String
    private let flags: Set<DNSResolverFlag>
    private var task: Task<[DNSRecord]?, Error>?

    public init(hostname: String, flags: Set<DNSResolverFlag>) {
        self.hostname = hostname
        self.flags = flags
    }

    public func startResolution() async throws {
    }

    public func waitForResolution(reachability: ReachabilityInfo?) async throws -> [DNSRecord] {
        let records: [DNSRecord]?
        if let task {
            records = try await task.value
        } else {
            let hostname = self.hostname
            let flags = self.flags
            let reachabilityCopy = reachability
            let newTask = Task.detached { @Sendable in
                try Self.resolveAndBlock(
                    hostname: hostname,
                    flags: flags,
                    reachability: reachabilityCopy
                )
            }
            task = newTask
            records = try await newTask.value
        }
        guard let records else {
            throw PartoutError(.operationCancelled)
        }
        task = nil
        return records
    }

    public func cancelResolution() async {
        task?.cancel()
    }
}

private extension POSIXDNSStrategy {
    static func resolveAndBlock(hostname: String, flags: Set<DNSResolverFlag>, reachability: ReachabilityInfo?) throws -> [DNSRecord]? {
#if os(Android)
        guard let networkHandle = reachability?.networkHandle else {
            throw PartoutError(.networkUnreachable)
        }
        pp_log_g(.core, .info, "resolveAndBlock() with Android network handle: \(networkHandle)")
#endif
        var infoPointer: pp_dns_result?
        var cReachability = reachability?.toCReachability ?? pp_reachability_none()
        let result = hostname.withCString {
            pp_dns_resolve(
                $0,
                nil,
                flags.contains(.allAddresses),
                &cReachability,
                &infoPointer
            )
        }
        guard result == 0 else {
            if pp_dns_error_is_bad_flags(result) {
                pp_log_g(.core, .fault, "pp_dns_resolve() failed with EAI_BADFLAGS")
            } else {
                pp_log_g(.core, .fault, "pp_dns_resolve() failed with result \(result)")
            }
            throw PartoutError(.dnsFailure)
        }

        defer {
            if let infoPointer {
                pp_dns_free(infoPointer)
            }
        }

        var records: [DNSRecord] = []
        var current = infoPointer
        while let result = current {
            current = pp_dns_next(result)
            guard !Task.isCancelled else { return nil }
            var hostBuffer = [CChar](repeating: 0, count: Int(PPDNSAddressStringMax))
            var isIPv6 = false
            let isResolved = hostBuffer.withUnsafeMutableBufferPointer {
                pp_dns_address_string(
                    result,
                    $0.baseAddress!,
                    $0.count,
                    &isIPv6
                )
            }
            if isResolved {
                let address = hostBuffer.string
                records.append(DNSRecord(address: address, isIPv6: isIPv6))
            }
        }
        return records
    }
}
