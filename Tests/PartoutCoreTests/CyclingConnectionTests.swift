// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct CyclingConnectionTests {
    @Test
    func givenLink_whenStart_thenConnectsToCurrentEndpoint() async throws {
        let sut = newConnection(
            withFactory: MockNetworkInterfaceFactory(),
            endpoints: [
                ExtendedEndpoint(rawValue: "hostname:UDP:1000")!
            ]
        )
        let statusStream = sut.statusStream.ignoreErrors()

        let dns = MockDNSResolver()
        dns.setResolvedIPv4(["1.1.1.1", "2.2.2.2", "3.3.3.3"], for: "hostname")
        await sut.setHooks(.init(
            dns: dns,
            startBlock: { _ in
                await sut.sendStatus(.connected)
            }
        ))

        #expect(await statusStream.nextElement() == .disconnected)
        print("start()")
        try await sut.start()
        #expect(await statusStream.nextElement() == .connecting)
        #expect(await statusStream.nextElement() == .connected)

        let currentAddress = await sut.currentLink?.remoteAddress
        let currentProto = await sut.currentLink?.remoteProtocol.rawValue
        #expect(currentAddress == "1.1.1.1")
        #expect(currentProto == "UDP:1000")
        let nextEndpoint = await sut.endpointResolver.currentResolvable?.currentEndpoint
        #expect(nextEndpoint?.rawValue == "2.2.2.2:UDP:1000")
    }

    @Test
    func givenUnresolvedLink_whenStart_thenConnectsToNextEndpoint() async throws {
        let sut = newConnection(
            withFactory: MockNetworkInterfaceFactory(),
            endpoints: [
                ExtendedEndpoint(rawValue: "bogus-hostname:UDP:1000")!,
                ExtendedEndpoint(rawValue: "hostname:UDP:1000")!
            ])
        let statusStream = sut.statusStream.ignoreErrors()

        let dns = MockDNSResolver()
        dns.setResolvedIPv4(["1.1.1.1", "2.2.2.2", "3.3.3.3"], for: "hostname")
        await sut.setHooks(.init(
            dns: dns,
            startBlock: { _ in
                await sut.sendStatus(.connected)
            }
        ))

        #expect(await statusStream.nextElement() == .disconnected)
        print("start()")
        try await sut.start()
        #expect(await statusStream.nextElement() == .connecting)
        #expect(await statusStream.nextElement() == .connected)

        let currentAddress = await sut.currentLink?.remoteAddress
        let currentProto = await sut.currentLink?.remoteProtocol.rawValue
        #expect(currentAddress == "1.1.1.1")
        #expect(currentProto == "UDP:1000")
        let nextEndpoint = await sut.endpointResolver.currentResolvable?.currentEndpoint
        #expect(nextEndpoint?.rawValue == "2.2.2.2:UDP:1000")
    }

    @Test
    func givenLinkFailure_whenStart_thenDisconnectsAndCyclesToNextEndpoint() async throws {
        let factory = MockNetworkInterfaceFactory()
        factory.observerBlock = {
            if $0.remoteAddress == "1.1.1.1" {
                $0.activityError = ActivityError()
            }
        }
        let sut = newConnection(
            withFactory: factory,
            endpoints: [
                ExtendedEndpoint(rawValue: "hostname:UDP:1000")!
            ]
        )
        let statusStream = sut.statusStream.ignoreErrors()

        let dns = MockDNSResolver()
        dns.setResolvedIPv4(["1.1.1.1", "2.2.2.2", "3.3.3.3"], for: "hostname")
        await sut.setHooks(.init(
            dns: dns,
            startBlock: { _ in
                await sut.sendStatus(.connected)
            }
        ))

        #expect(await statusStream.nextElement() == .disconnected)
        do {
            print("start()")
            try await sut.start()
        } catch is ActivityError {
            #expect(await statusStream.nextElement() == .connecting)
            #expect(await statusStream.nextElement() == .disconnected)
            let nextEndpoint = await sut.endpointResolver.currentResolvable?.currentEndpoint
            #expect(nextEndpoint?.address.rawValue == "2.2.2.2")
            #expect(nextEndpoint?.proto.rawValue == "UDP:1000")
        } catch {
            #expect(Bool(false), error.localizedComment)
        }
    }

    @Test
    func givenAllLinksFailure_whenStart_thenFailsWithExhaustedEndpoints() async throws {
        let factory = MockNetworkInterfaceFactory()
        factory.observerBlock = {
            $0.activityError = ActivityError()
        }
        let sut = newConnection(
            withFactory: factory,
            endpoints: [
                ExtendedEndpoint(rawValue: "hostname:UDP:1000")!
            ]
        )
        let statusStream = sut.statusStream.ignoreErrors()

        let dns = MockDNSResolver()
        dns.setResolvedIPv4(["1.1.1.1", "2.2.2.2", "3.3.3.3"], for: "hostname")
        await sut.setHooks(.init(
            dns: dns,
            startBlock: { _ in
                await sut.sendStatus(.connected)
            }
        ))

        #expect(await statusStream.nextElement() == .disconnected)
        do {
            print("start()")
            try await sut.start()
        } catch is ActivityError {
            #expect(await statusStream.nextElement() == .connecting)
            #expect(await statusStream.nextElement() == .disconnected)
        } catch {
            #expect(Bool(false), error.localizedComment)
        }
    }

    @Test
    func givenLink_whenStartThenGetsBetterLink_thenReconnects() async throws {
        let hasBetterPath = PassthroughStream<UniqueID, Void>()
        let factory = MockNetworkInterfaceFactory()
        factory.linkBlock = {
            $0.hasBetterPath = hasBetterPath.subscribe()
        }
        let sut = newConnection(
            withFactory: factory,
            endpoints: [
                ExtendedEndpoint(rawValue: "hostname:UDP:1000")!
            ]
        )
        let statusStream = sut.statusStream.ignoreErrors()

        let dns = MockDNSResolver()
        dns.setResolvedIPv4(["1.1.1.1"], for: "hostname")
        let upgradeExpectation = Expectation()
        await sut.setHooks(.init(
            dns: dns,
            startBlock: { _ in
                await sut.sendStatus(.connected)
            },
            upgradeBlock: {
                await sut.sendStatus(.disconnecting)
                await upgradeExpectation.fulfill()
            }
        ))

        #expect(await statusStream.nextElement() == .disconnected)
        print("start()")
        try await sut.start()
        #expect(await statusStream.nextElement() == .connecting)
        #expect(await statusStream.nextElement() == .connected)
        hasBetterPath.send()
        try await upgradeExpectation.fulfillment(timeout: 300)
        #expect(await statusStream.nextElement() == .disconnecting)
    }

    @Test
    func givenLink_whenStartThenStop_thenStops() async throws {
        let sut = newConnection(
            withFactory: MockNetworkInterfaceFactory(),
            endpoints: [
                ExtendedEndpoint(rawValue: "hostname:UDP:1000")!
            ]
        )
        let statusStream = sut.statusStream.ignoreErrors()

        let dns = MockDNSResolver()
        dns.setResolvedIPv4(["1.1.1.1"], for: "hostname")
        let stopExpectation = Expectation()
        await sut.setHooks(.init(
            dns: dns,
            startBlock: { _ in
                print("startBlock()")
                await sut.sendStatus(.connected)
            },
            stopBlock: { _, timeout in
                print("stopBlock()")
                #expect(timeout == 500)
                try? await Task.sleep(milliseconds: 100)
                await sut.sendStatus(.disconnected)
                await stopExpectation.fulfill()
            }
        ))

        print("start()")
        try await sut.start()
        #expect(await statusStream.nextElement() == .disconnected)
        #expect(await statusStream.nextElement() == .connecting)
        #expect(await statusStream.nextElement() == .connected)

        print("stop()")
        await sut.stop(timeout: 500)
        try await stopExpectation.fulfillment(timeout: 300)
        #expect(await statusStream.nextElement() == .disconnecting)
        #expect(await statusStream.nextElement() == .disconnected)
    }
}

// MARK: - Helpers

private struct ActivityError: Error {
}

private extension CyclingConnectionTests {
    func newConnection(
        withFactory factory: NetworkInterfaceFactory,
        endpoints: [ExtendedEndpoint]
    ) -> CyclingConnection {
        CyclingConnection(
            .global,
            factory: factory,
            options: .init(),
            endpoints: endpoints
        )
    }
}
