// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Foundation
internal import _PartoutCore_C
import Testing

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct POSIXBlockingSocketTests {
    @Test
    func givenPendingRead_whenShutdown_thenUnblocksWithoutBadDescriptor() async throws {
        var fds = [Int32](repeating: 0, count: 2)
#if canImport(Darwin)
        let socketType = SOCK_STREAM
#else
        let socketType = Int32(SOCK_STREAM.rawValue)
#endif
        #expect(socketpair(AF_UNIX, socketType, 0, &fds) == 0)

        let peerFD = fds[1]
        defer {
            _ = close(peerFD)
        }

        let sock = pp_socket_create(UInt64(fds[0]), true)
        let sut = POSIXBlockingSocket(
            .global,
            sock: sock,
            closesOnEmptyRead: true,
            maxReadLength: 16
        )

        let readTask = Task<Result<[Data], Error>, Never> {
            do {
                return .success(try await sut.readPackets())
            } catch {
                return .failure(error)
            }
        }

        try await Task.sleep(for: .milliseconds(50))
        await sut.shutdown()

        #expect(sut.fileDescriptor == nil)

        let result = await readTask.value
        switch result {
        case .success:
            #expect(Bool(false), "Expected shutdown to stop the pending read")
        case .failure(let error):
            #expect(PartoutError(error) == PartoutError(.linkNotActive))
        }
    }
}
