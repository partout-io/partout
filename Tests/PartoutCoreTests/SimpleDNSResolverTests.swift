// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct SimpleDNSResolverTests {
    @Test
    func givenResolver_whenResolveBeforeTimeout_thenReturnsResolvedRecords() async throws {
        let records = [DNSRecord(address: "1.2.3.4", isIPv6: false)]
        let sut = SimpleDNSResolver { _ in
            MockStrategy(records: records, delay: 100)
        }
        let result = try await sut.resolve("foobar.com", timeout: 500)
        #expect(result == records)
    }

    @Test
    func givenResolver_whenResolveAfterTimeout_thenFailsWithTimeout() async throws {
        let records = [DNSRecord(address: "1.2.3.4", isIPv6: false)]
        let sut = SimpleDNSResolver { _ in
            MockStrategy(records: records, delay: 500)
        }
        do {
            _ = try await sut.resolve("foobar.com", timeout: 100)
            #expect(Bool(false), ".resolve must fail")
        } catch let error as PartoutError {
            #expect(error.code == .timeout)
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }
}

// MARK: -

private actor MockStrategy: SimpleDNSStrategy {
    private let records: [DNSRecord]

    private let delay: Int

    private var resolutionTask: Task<[DNSRecord], Error>?

    init(records: [DNSRecord], delay: Int) {
        self.records = records
        self.delay = delay
    }

    func startResolution() throws {
        print("startResolution")
        resolutionTask = Task {
            do {
                try await Task.sleep(milliseconds: delay)
            } catch is CancellationError {
                throw PartoutError(.timeout)
            }
            return records
        }
    }

    func waitForResolution() async throws -> [DNSRecord] {
        print("waitForResolution")
        let result = try await resolutionTask?.value
        print("endResolution")
        return result ?? []
    }

    func cancelResolution() {
        print("cancelResolution")
        resolutionTask?.cancel()
    }
}
