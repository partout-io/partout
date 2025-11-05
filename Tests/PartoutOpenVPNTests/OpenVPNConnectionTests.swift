// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutCore
@testable import PartoutOpenVPN
import Testing

struct OpenVPNConnectionTests {
    private let constants = Constants()

    @Test
    func givenConnection_whenStart_thenConnects() async throws {
        let session = MockOpenVPNSession()
        var status: ConnectionStatus

        let expLink = Expectation()
        let expTunnel = Expectation()
        session.onSetLink = {
            Task {
                await expLink.fulfill()
            }
        }
        session.onSetTunnel = {
            Task {
                await expTunnel.fulfill()
            }
        }

        let sut = try await constants.newConnection(with: session)
        status = await sut.backend.status
        #expect(status == .disconnected)

        try await sut.start()
        try await expLink.fulfillment(timeout: 300)
        try await expTunnel.fulfillment(timeout: 300)
        status = await sut.backend.status
        #expect(status == .connected)
    }

    @Test
    func givenConnectionFailingLink_whenStart_thenFails() async throws {
        let session = MockOpenVPNSession()
        var status: ConnectionStatus
        let controller = MockTunnelController()

        let expLink = Expectation()
        session.onSetLink = {
            throw PartoutError(.crypto)
        }
        session.onDidFailToSetLink = {
            Task {
                await expLink.fulfill()
            }
        }

        let sut = try await constants.newConnection(with: session, controller: controller)
        status = await sut.backend.status
        #expect(status == .disconnected)

        do {
            try await sut.start()
            try await expLink.fulfillment(timeout: 300)
        } catch {
            #expect((error as? PartoutError)?.code == .crypto)
        }
    }

    @Test
    func givenConnectionFailingTunnelSetup_whenStart_thenFails() async throws {
        let session = MockOpenVPNSession()
        var status: ConnectionStatus
        let controller = MockTunnelController()
        controller.onSetTunnelSettings = { _ in
            throw PartoutError(.incompatibleModules)
        }

        session.onStop = {
            #expect(($0 as? PartoutError)?.code == .incompatibleModules)
        }

        let sut = try await constants.newConnection(with: session, controller: controller)
        status = await sut.backend.status
        #expect(status == .disconnected)

        do {
            try await sut.start()
        } catch {
            #expect((error as? PartoutError)?.code == .incompatibleModules)
        }
    }

    @Test
    func givenConnectionFailingAsynchronously_whenStart_thenCancelsShortlyAfter() async throws {
        let session = MockOpenVPNSession()
        var status: ConnectionStatus
        let controller = MockTunnelController()

        let expStop = Expectation()
        session.onSetLink = {
            Task {
                try? await Task.sleep(milliseconds: 200)
                await session.shutdown(PartoutError(.crypto))
            }
        }
        session.onStop = {
            #expect(($0 as? PartoutError)?.code == .crypto)
            Task {
                await expStop.fulfill()
            }
        }

        let sut = try await constants.newConnection(with: session, controller: controller)
        status = await sut.backend.status
        #expect(status == .disconnected)

        try await sut.start()
        try await expStop.fulfillment(timeout: 1000)
    }

    @Test
    func givenConnectionFailingWithRecoverableError_whenStart_thenDisconnects() async throws {
        let session = MockOpenVPNSession()
        var status: ConnectionStatus
        let controller = MockTunnelController()
        let recoverableError = PartoutError(.timeout)
        assert(recoverableError.isOpenVPNRecoverable)

        let expStart = Expectation()
        let expStop = Expectation()
        session.onSetLink = {
            Task {
                await expStart.fulfill()
            }
        }
        session.onStop = {
            #expect(($0 as? PartoutError)?.code == recoverableError.code)
            Task {
                await expStop.fulfill()
            }
        }
        controller.onCancelTunnelConnection = { _ in
            #expect(Bool(false), "Should not cancel connection")
        }

        let sut = try await constants.newConnection(
            with: session,
            controller: controller
        )
        status = await sut.backend.status
        #expect(status == .disconnected)

        try await sut.start()
        try await expStart.fulfillment(timeout: 300)
        status = await sut.backend.status
        #expect(status == .connected)

        Task {
            await session.shutdown(recoverableError)
        }

        try await expStop.fulfillment(timeout: 500)
        status = await sut.backend.status
        #expect(status == .disconnected)
    }

    @Test
    func givenStartedConnection_whenStop_thenDisconnects() async throws {
        let session = MockOpenVPNSession()
        var status: ConnectionStatus

        let expLink = Expectation()
        let expStop = Expectation()
        session.onSetLink = {
            Task {
                await expLink.fulfill()
            }
        }
        session.onStop = {
            #expect($0 == nil)
            Task {
                await expStop.fulfill()
            }
        }

        let sut = try await constants.newConnection(with: session)
        status = await sut.backend.status
        #expect(status == .disconnected)

        try await sut.start()
        try await expLink.fulfillment(timeout: 200)
        status = await sut.backend.status
        #expect(status == .connected)

        await sut.stop(timeout: 100)
        try await expStop.fulfillment(timeout: 300)
        status = await sut.backend.status
        #expect(status == .disconnected)
    }

    @Test
    func givenStartedConnectionWithHangingLink_whenStop_thenDisconnectsAfterTimeout() async throws {
        let session = MockOpenVPNSession()
        var status: ConnectionStatus

        let expLink = Expectation()
        let expStop = Expectation()
        session.onSetLink = {
            session.mockHasLink = true
            Task {
                await expLink.fulfill()
            }
        }
        session.onStop = {
            #expect($0 == nil)
            Task {
                await expStop.fulfill()
            }
        }

        let sut = try await constants.newConnection(with: session)
        status = await sut.backend.status
        #expect(status == .disconnected)

        try await sut.start()
        try await expLink.fulfillment(timeout: 200)
        status = await sut.backend.status
        #expect(status == .connected)

        await sut.stop(timeout: 100)
        try await expStop.fulfillment(timeout: 300)
        status = await sut.backend.status
        #expect(status == .disconnected)
    }

    @Test
    func givenStartedConnection_whenUpgraded_thenDisconnectsWithNetworkChanged() async throws {
        let session = MockOpenVPNSession()
        var status: ConnectionStatus
        let hasBetterPath = PassthroughStream<Void>()
        let factory = MockNetworkInterfaceFactory()
        factory.linkBlock = {
            $0.hasBetterPath = hasBetterPath.subscribe()
        }

        let expInitialLink = Expectation()
        let expConnected = Expectation()
        let expStop = Expectation()
        session.onSetLink = {
            Task {
                await expInitialLink.fulfill()
            }
        }
        session.onConnected = {
            Task {
                await expConnected.fulfill()
            }
        }
        session.onStop = {
            #expect(($0 as? PartoutError)?.code == .networkChanged)
            Task {
                await expStop.fulfill()
            }
        }

        let sut = try await constants.newConnection(
            with: session,
            factory: factory
        )
        status = await sut.backend.status
        #expect(status == .disconnected)

        try await sut.start()
        try await expInitialLink.fulfillment(timeout: 500)
        try await expConnected.fulfillment(timeout: 500)
        status = await sut.backend.status
        #expect(status == .connected)

        hasBetterPath.send()
        try await expStop.fulfillment(timeout: 500)
        status = await sut.backend.status
        #expect(status == .disconnected)
    }
}

// MARK: - Helpers

private struct Constants {
    private let prng = SimplePRNG()

    private let dns = MockDNSResolver()

    private let hostname = "hostname"

    private let module: OpenVPNModule

    init() {
        dns.setResolvedIPv4(["1.2.3.4"], for: hostname)

        var cfg = OpenVPN.Configuration.Builder()
        cfg.ca = OpenVPN.CryptoContainer(pem: "")
        cfg.cipher = .aes128cbc
        cfg.remotes = [ExtendedEndpoint(rawValue: "\(hostname):UDP:1194")!]
        do {
            module = try OpenVPNModule.Builder(configurationBuilder: cfg).build()
        } catch {
            fatalError("Cannot build OpenVPNModule: \(error)")
        }
    }

    func newConnection(
        with session: OpenVPNSessionProtocol,
        controller: TunnelController = MockTunnelController(),
        factory: NetworkInterfaceFactory = MockNetworkInterfaceFactory(),
        environment: TunnelEnvironment = SharedTunnelEnvironment(profileId: nil)
    ) async throws -> OpenVPNConnection {
        let profile = try Profile.Builder().build()
        let impl = OpenVPNModule.Implementation(
            importerBlock: {
                StandardOpenVPNParser(decrypter: nil)
            },
            connectionBlock: {
                try OpenVPNConnection(
                    .global,
                    parameters: $0,
                    module: $1,
                    prng: prng,
                    dns: dns,
                    sessionFactory: { session }
                )
            }
        )
        let options = ConnectionParameters.Options()
        let conn = try module.newConnection(with: impl, parameters: .init(
            profile: profile,
            controller: controller,
            factory: factory,
            reachability: MockReachabilityObserver(),
            environment: environment,
            options: options
        ))
        return try #require(conn as? OpenVPNConnection)
    }
}

private final class MockOpenVPNSession: OpenVPNSessionProtocol, @unchecked Sendable {
    private let options: OpenVPN.Configuration = {
        do {
            return try OpenVPN.Configuration.Builder().build(isClient: false)
        } catch {
            fatalError("Cannot build remote options: \(error)")
        }
    }()

    var onSetLink: () throws -> Void = {}

    var onConnected: () -> Void = {}

    var onDidFailToSetLink: () -> Void = {}

    var onSetTunnel: () -> Void = {}

    var onStop: (Error?) -> Void = { _ in }

    var mockHasLink = false

    // MARK: OpenVPNSessionProtocol

    weak var delegate: OpenVPNSessionDelegate?

    func setDelegate(_ delegate: OpenVPNSessionDelegate) async {
        self.delegate = delegate
    }

    func setLink(_ link: LinkInterface) async throws {
        do {
            try onSetLink()
            await delegate?.sessionDidStart(
                self,
                remoteAddress: "100.200.100.200",
                remoteProtocol: .init(.udp, 1234),
                remoteOptions: options,
                remoteFd: nil
            )
            onConnected()
        } catch {
            await delegate?.sessionDidStop(self, withError: error)
            onDidFailToSetLink()
        }
    }

    func hasLink() async -> Bool {
        mockHasLink
    }

    func setTunnel(_ tunnel: IOInterface) async {
        onSetTunnel()
    }

    func shutdown(_ error: (any Error)?, timeout: TimeInterval?) async {
        await delegate?.sessionDidStop(self, withError: error)
        onStop(error)
    }
}

final class MockReachabilityObserver: ReachabilityObserver {
    func startObserving() {
    }

    let isReachable = true

    var isReachableStream: AsyncStream<Bool> {
        AsyncStream { nil }
    }
}
