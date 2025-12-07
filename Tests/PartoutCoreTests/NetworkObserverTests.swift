// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct NetworkObserverTests {
    @Test
    func givenUnboundStatus_whenAnyStatus_thenObserverFires() async throws {
        let reachability = PassthroughStream<UniqueID, Bool>()
        let status = PassthroughStream<UniqueID, ConnectionStatus>()

        let sut = NetworkObserver(
            .global,
            reachabilityStream: reachability.subscribe(),
            statusStream: status.subscribe(),
            isStatusReady: { _ in true }
        )
        let readyStream = sut.onReady.subscribe()

        let observerExpectation = Expectation()
        sut.setEnabled(true)
        Task {
            for await _ in readyStream {
                await observerExpectation.fulfill()
                return
            }
        }

        reachability.send(true)
        status.send(.connecting)
        try await observerExpectation.fulfillment(timeout: 200)
    }

    @Test
    func givenBoundStatus_whenStatusMatches_thenObserverFires() async throws {
        let reachability = PassthroughStream<UniqueID, Bool>()
        let status = PassthroughStream<UniqueID, ConnectionStatus>()

        let sut = NetworkObserver(
            .global,
            reachabilityStream: reachability.subscribe(),
            statusStream: status.subscribe(),
            isStatusReady: { $0 == .disconnected }
        )
        let readyStream = sut.onReady.subscribe()

        let observerExpectation = Expectation()
        nonisolated(unsafe) var didFire = false
        sut.setEnabled(true)
        Task { @Sendable in
            for await _ in readyStream {
                guard !didFire else {
                    #expect(Bool(false), "Did fire already")
                    return
                }
                didFire = true
                await observerExpectation.fulfill()
                return
            }
        }

        reachability.send(true)
        status.send(.connecting)
        status.send(.connected)
        status.send(.disconnecting)
        status.send(.disconnected)
        try await observerExpectation.fulfillment(timeout: 200)
        #expect(didFire)
    }

    @Test
    func givenBoundStatus_whenStatusMatches_thenObserverFiresAfterEnabling() async {
        let reachability = PassthroughStream<UniqueID, Bool>()
        let status = PassthroughStream<UniqueID, ConnectionStatus>()
        let reachabilityStream = reachability.subscribe()
        let statusStream = status.subscribe()

        let sut = NetworkObserver(
            .global,
            reachabilityStream: reachability.subscribe(),
            statusStream: status.subscribe(),
            isStatusReady: { $0 == .disconnected }
        )
        let readyStream = sut.onReady.subscribe()

        sut.setEnabled(true)
        status.send(.disconnected)
        reachability.send(true)          // 1
        #expect(await statusStream.nextElement() == .disconnected)
        #expect(await reachabilityStream.nextElement() == true)
        await readyStream.nextElement()

        sut.setEnabled(false)
        status.send(.disconnected)
        reachability.send(false)
        status.send(.connecting)
        status.send(.connected)
        status.send(.disconnecting)
        status.send(.disconnected)
        reachability.send(true)
        #expect(await statusStream.nextElement() == .disconnected)
        #expect(await statusStream.nextElement() == .connecting)
        #expect(await statusStream.nextElement() == .connected)
        #expect(await statusStream.nextElement() == .disconnecting)
        #expect(await statusStream.nextElement() == .disconnected)
        #expect(await reachabilityStream.nextElement() == false)
        #expect(await reachabilityStream.nextElement() == true)
        sut.setEnabled(true)        // 2
        await readyStream.nextElement()

        reachability.send(false)
        sut.setEnabled(false)
        reachability.send(true)
        #expect(await reachabilityStream.nextElement() == false)
        #expect(await reachabilityStream.nextElement() == true)
        sut.setEnabled(true)        // 3
        await readyStream.nextElement()
    }
}
