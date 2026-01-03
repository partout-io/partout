// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct SimpleConnectionDaemonTests {
    init() {
        setUpLogging()
    }

    @Test
    func givenNoConnection_whenStartDaemon_thenStarts() async throws {
        let profile = try Profile.Builder()
            .build()

        let sut = try await newDaemon(with: profile)
        do {
            try await sut.start()
        } catch {
            #expect(Bool(false), error.localizedComment)
        }
    }

    @Test
    func givenConnection_whenStartDaemon_thenStartsAndConnects() async throws {
        let connectionModule = MockConnectionModule()
        let profile = try Profile.Builder(
            modules: [connectionModule],
            activeModulesIds: [connectionModule.id]
        ).build()
        #expect(profile.activeConnectionModule != nil)

        let reachability = MockReachabilityObserver()
        let sut = try await newDaemon(with: profile, reachability: reachability)
        let stream = try #require(await sut.statusStream)

        try await sut.start()
        #expect(await stream.nextElement() == .disconnected)
        #expect(await stream.nextElement() == .connecting)
        #expect(await stream.nextElement() == .connected)
    }

    @Test
    func givenConnectionFailingToCreate_whenInitDaemon_thenThrowsError() async throws {
        var connectionModule = MockConnectionModule()
        connectionModule.creationError = PartoutError(.authentication)
        let profile = try Profile.Builder(
            modules: [connectionModule],
            activeModulesIds: [connectionModule.id]
        ).build()
        #expect(profile.activeConnectionModule != nil)

        let environment = SharedTunnelEnvironment(profileId: profile.id)
        do {
            _ = try await newDaemon(with: profile, environment: environment)
        } catch let error as PartoutError {
            #expect(error.code == .authentication)
        } catch {
            #expect(Bool(false), error.localizedComment)
        }
    }

    @Test
    func givenConnectionFailingToStart_whenStartDaemon_thenStarts() async throws {
        var connectionModule = MockConnectionModule()
        connectionModule.options.startError = PartoutError(.dnsFailure)
        let profile = try Profile.Builder(
            modules: [connectionModule],
            activeModulesIds: [connectionModule.id]
        ).build()
        #expect(profile.activeConnectionModule != nil)

        let sut = try await newDaemon(with: profile)
        do {
            try await sut.start()
        } catch {
            #expect(Bool(false), error.localizedComment)
        }
    }

    @Test
    func givenStartedDaemonWithNetworkUnreachable_whenNetworkIsReachable_thenConnects() async throws {
        let connectionModule = MockConnectionModule()
        let profile = try Profile.Builder(
            modules: [connectionModule],
            activeModulesIds: [connectionModule.id]
        ).build()
        #expect(profile.activeConnectionModule != nil)

        let reachability = MockReachabilityObserver()
        reachability.isReachable = false
        let sut = try await newDaemon(
            with: profile,
            reachability: reachability,
            reconnectionDelay: 100
        )
        let stream = try #require(await sut.statusStream)

        let expAvailable = Expectation()
        await sut.setTestEvaluateConnection {
            Task {
                await expAvailable.fulfill()
            }
        }

        try await sut.start()
        Task {
            reachability.isReachable = true
        }
        try await expAvailable.fulfillment(timeout: 500)
        #expect(await stream.nextElement() == .disconnected)
        #expect(await stream.nextElement() == .connecting)
        #expect(await stream.nextElement() == .connected)
    }

    @Test
    func givenStartedDaemon_whenStop_thenDisconnects() async throws {
        let connectionModule = MockConnectionModule()
        let profile = try Profile.Builder(
            modules: [connectionModule],
            activeModulesIds: [connectionModule.id]
        ).build()
        #expect(profile.activeConnectionModule != nil)

        let reachability = MockReachabilityObserver()
        let sut = try await newDaemon(
            with: profile,
            reachability: reachability,
            stopDelay: 100,
            reconnectionDelay: 5000
        )
        let stream = try #require(await sut.statusStream)

        try await sut.start()
        #expect(await stream.nextElement() == .disconnected)
        #expect(await stream.nextElement() == .connecting)
        #expect(await stream.nextElement() == .connected)
        reachability.isReachable = false
        await sut.stop()
        #expect(await stream.nextElement() == .disconnected)
        await sut.destroy()
    }

    @Test
    func givenStartedDaemon_whenFailToStop_thenDisconnectsOnTimeout() async throws {
        var connectionModule = MockConnectionModule()
        connectionModule.options.shouldTimeout = true
        let profile = try Profile.Builder(
            modules: [connectionModule],
            activeModulesIds: [connectionModule.id]
        ).build()
        #expect(profile.activeConnectionModule != nil)

        let reachability = MockReachabilityObserver()
        let sut = try await newDaemon(
            with: profile,
            reachability: reachability,
            stopDelay: 200
        )
        let stream = try #require(await sut.statusStream)

        try await sut.start()
        #expect(await stream.nextElement() == .disconnected)
        #expect(await stream.nextElement() == .connecting)
        #expect(await stream.nextElement() == .connected)
        reachability.isReachable = false
        await sut.stop()
        #expect(await stream.nextElement() == .disconnected)
    }
}

// MARK: - Helpers

private extension SimpleConnectionDaemonTests {
    func newDaemon(
        with profile: Profile,
        reachability: ReachabilityObserver = MockReachabilityObserver(),
        environment: TunnelEnvironment? = nil,
        onCancel: @escaping (Error?) -> Void = { _ in },
        stopDelay: Int = 1000,
        reconnectionDelay: Int = 1000
    ) async throws -> SimpleConnectionDaemon {
        let controller = MockTunnelController()
        controller.onCancelTunnelConnection = onCancel
        let options = ConnectionParameters.Options()
        let environment = environment ?? SharedTunnelEnvironment(profileId: profile.id)
        return try SimpleConnectionDaemon(params: .init(
            registry: Registry(allHandlers: [
                MockConnectionModule.moduleHandler
            ]),
            connectionParameters: .init(
                profile: profile,
                controller: controller,
                factory: MockNetworkInterfaceFactory(),
                reachability: MockReachabilityObserver(),
                environment: environment,
                options: options
            ),
            reachability: reachability,
            messageHandler: DefaultMessageHandler(.global, environment: environment),
            stopDelay: stopDelay,
            reconnectionDelay: reconnectionDelay
        ))
    }
}

private final class MockReachabilityObserver: ReachabilityObserver, @unchecked Sendable {
    private nonisolated let isReachableSubject = PassthroughStream<UniqueID, Bool>()

    func startObserving() {
        isReachable = true
    }

    var isReachable: Bool = false {
        didSet {
            isReachableSubject.send(isReachable)
        }
    }

    var isReachableStream: AsyncStream<Bool> {
        isReachableSubject.subscribe()
    }
}

private struct MockConnectionModule: ConnectionModule {
    var creationError: Error?

    var options = MockConnection.Options()

    func newConnection(with impl: ModuleImplementation?, parameters: ConnectionParameters) throws -> Connection {
        if let creationError {
            throw creationError
        }
        return MockConnection(options: options)
    }
}

private final class MockConnection: Connection {
    struct Options {
        var startError: Error?

        var failure: (interval: Int, error: Error)?

        var shouldTimeout = false
    }

    let options: Options

    private let statusSubject = CurrentValueStream<UniqueID, ConnectionStatus>(.disconnected)

    var statusStream: AsyncThrowingStream<ConnectionStatus, Error> {
        statusSubject.subscribeThrowing()
    }

    nonisolated(unsafe)
    private var sleepTask: Task<Void, Never>?

    init(options: Options) {
        self.options = options
    }

    func start() async throws -> Bool {
        statusSubject.send(.connecting)
        if let startError = options.startError {
            statusSubject.send(.disconnected)
            throw startError
        }
        statusSubject.send(.connected)

        if let failure = options.failure {
            Task {
                try? await Task.sleep(milliseconds: failure.interval)
                statusSubject.send(completion: .failure(failure.error))
            }
        }
        return true
    }

    func stop(timeout: Int) async {
        if timeout == 0 {
            sleepTask?.cancel()
            return
        }
        if timeout > 0 {
            sleepTask?.cancel()
            if options.shouldTimeout {
                sleepTask = Task {
                    try? await Task.sleep(milliseconds: 2 * timeout) // slow enough to timeout
                }
                await sleepTask?.value
            }
        }
        statusSubject.send(.disconnected)
    }
}
