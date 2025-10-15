// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

/// Implementation of ``SimpleDNSStrategy`` with the POSIX C library.
public actor POSIXDNSStrategy: SimpleDNSStrategy {
    private let hostname: String

    private var task: Task<[DNSRecord]?, Error>?

    public init(hostname: String) {
        self.hostname = hostname
    }

    public func startResolution() async throws {
    }

    public func waitForResolution() async throws -> [DNSRecord] {
        let records: [DNSRecord]?
        if let task {
            records = try await task.value
        } else {
            let hostname = self.hostname
            let newTask = Task.detached { @Sendable in
                try Self.resolveAndBlock(hostname: hostname)
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
    static func resolveAndBlock(hostname: String) throws -> [DNSRecord]? {
        let addr = hostname.cString(using: .utf8)
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC // IPv4/IPv6
        var infoPointer: UnsafeMutablePointer<addrinfo>?
        let result = getaddrinfo(addr, nil, &hints, &infoPointer)
        if result != 0 {
            throw PartoutError(.dnsFailure)
        }

        defer {
            if let infoPointer {
                freeaddrinfo(infoPointer)
            }
        }

        var records: [DNSRecord] = []
        var currentPointer = infoPointer
        while let info = currentPointer?.pointee {
            guard !Task.isCancelled else {
                return nil
            }
            guard let addr = info.ai_addr else {
                continue
            }
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
                records.append(DNSRecord(address: address, isIPv6: addrLength == 128))
            }
            currentPointer = info.ai_next
        }
        return records
    }
}
