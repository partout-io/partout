// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCore_C

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
        var hints = addrinfo()
#if canImport(Darwin)
        // Beware that DNS breaks on Android when AI_ALL + AF_UNSPEC is set
        hints.ai_flags = flags.contains(.allAddresses) ? AI_ALL : 0
#endif
        hints.ai_family = AF_UNSPEC // IPv4/IPv6
        // XXX: Choosing either would dedup results
//        hints.ai_socktype = SOCK_STREAM SOCK_DGRAM
        var infoPointer: UnsafeMutablePointer<addrinfo>?
        let result = hostname.withCString {
#if os(Android)
            android_getaddrinfofornetwork(networkHandle, $0, nil, &hints, &infoPointer)
#else
            getaddrinfo($0, nil, &hints, &infoPointer)
#endif
        }
        guard result == 0 else {
            switch result {
            case EAI_BADFLAGS:
                pp_log_g(.core, .fault, "getaddrinfo() failed with EAI_BADFLAGS")
            case EAI_NODATA:
                pp_log_g(.core, .fault, "getaddrinfo() failed with EAI_NODATA")
            default:
                pp_log_g(.core, .fault, "getaddrinfo() failed with result \(result)")
            }
            throw PartoutError(.dnsFailure)
        }

        defer {
            if let infoPointer {
                freeaddrinfo(infoPointer)
            }
        }

        var records: [DNSRecord] = []
        var currentPointer = infoPointer
        while let pointer = currentPointer {
            let info = pointer.pointee
            currentPointer = info.ai_next
            guard !Task.isCancelled else { return nil }
            guard let addr = info.ai_addr else { continue }
            let addrLength = socklen_t(info.ai_addrlen)
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
#if os(Windows)
            let hostBufLength = DWORD(hostBuffer.count)
#elseif os(Android)
            let hostBufLength = Int(hostBuffer.count)
#else
            let hostBufLength = socklen_t(hostBuffer.count)
#endif
            let result = getnameinfo(
                addr,
                addrLength,
                &hostBuffer,
                hostBufLength,
                nil,
                0,
                NI_NUMERICHOST
            )
            if result == 0 {
                let address = hostBuffer.string
                let isIPv6 = info.ai_family == AF_INET6
                records.append(DNSRecord(address: address, isIPv6: isIPv6))
            }
        }
        return records
    }
}
