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
        let stream = sut.statusStream

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
    func givenConnectionFailingToStart_whenStartDaemon_thenStartsAndPublishesLastErrorCode() async throws {
        var connectionModule = MockConnectionModule()
        connectionModule.options.startError = PartoutError(.dnsFailure)
        let profile = try Profile.Builder(
            modules: [connectionModule],
            activeModulesIds: [connectionModule.id]
        ).build()
        #expect(profile.activeConnectionModule != nil)

        let expLastError = Expectation()
        let sut = try await newDaemon(
            with: profile,
            onSnapshot: { snapshot in
                guard snapshot.environment?.lastErrorCode == .dnsFailure else { return }
                Task {
                    await expLastError.fulfill()
                }
            }
        )
        do {
            try await sut.start()
            try await expLastError.fulfillment(timeout: 500)
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
        let stream = sut.statusStream

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
    func givenStartedConnectionFailingAsynchronously_whenConnectionFails_thenPublishesLastErrorCode() async throws {
        var connectionModule = MockConnectionModule()
        connectionModule.options.failure = (50, PartoutError(.authentication))
        let profile = try Profile.Builder(
            modules: [connectionModule],
            activeModulesIds: [connectionModule.id]
        ).build()
        #expect(profile.activeConnectionModule != nil)

        let expLastError = Expectation()
        let expCancel = Expectation()
        let sut = try await newDaemon(
            with: profile,
            onCancel: { error in
                guard error?.partoutErrorCode == .authentication else { return }
                Task {
                    await expCancel.fulfill()
                }
            },
            reconnectionDelay: 5000,
            onSnapshot: { snapshot in
                guard snapshot.environment?.lastErrorCode == .authentication else { return }
                Task {
                    await expLastError.fulfill()
                }
            }
        )
        let stream = sut.statusStream

        try await sut.start()
        #expect(await stream.nextElement() == .disconnected)
        #expect(await stream.nextElement() == .connecting)
        #expect(await stream.nextElement() == .connected)
        try await expLastError.fulfillment(timeout: 500)
        try await expCancel.fulfillment(timeout: 500)
    }

    @Test
    func givenStartedConnectionReportingRecoverableError_whenConnectionDisconnects_thenPublishesLastErrorCode() async throws {
        var connectionModule = MockConnectionModule()
        connectionModule.options.reportedError = (50, PartoutError(.timeout))
        let profile = try Profile.Builder(
            modules: [connectionModule],
            activeModulesIds: [connectionModule.id]
        ).build()
        #expect(profile.activeConnectionModule != nil)

        let expLastError = Expectation()
        let sut = try await newDaemon(
            with: profile,
            reconnectionDelay: 5000,
            onSnapshot: { snapshot in
                guard snapshot.environment?.lastErrorCode == .timeout else { return }
                Task {
                    await expLastError.fulfill()
                }
            }
        )
        let stream = sut.statusStream

        try await sut.start()
        #expect(await stream.nextElement() == .disconnected)
        #expect(await stream.nextElement() == .connecting)
        #expect(await stream.nextElement() == .connected)
        try await expLastError.fulfillment(timeout: 500)
    }

    @Test
    func givenStartedConnectionReportingSmallDataCountChanges_whenSnapshotTimerFires_thenSkipsSnapshotsBelowMinimumDelta() async throws {
        var connectionModule = MockConnectionModule()
        connectionModule.options.reportedDataCounts = [
            (50, DataCount(40, 0)),
            (110, DataCount(80, 0)),
            (170, DataCount(140, 0))
        ]
        let profile = try Profile.Builder(
            modules: [connectionModule],
            activeModulesIds: [connectionModule.id]
        ).build()
        #expect(profile.activeConnectionModule != nil)

        let recorder = SnapshotRecorder()
        let expDataCount = Expectation()
        let sut = try await newDaemon(
            with: profile,
            reconnectionDelay: 5000,
            snapshotInterval: 30,
            minDataCountDelta: 100,
            onSnapshot: { snapshot in
                Task {
                    await recorder.append(snapshot)
                    guard snapshot.environment?.dataCount == DataCount(140, 0) else { return }
                    await expDataCount.fulfill()
                }
            }
        )
        let stream = sut.statusStream

        try await sut.start()
        #expect(await stream.nextElement() == .disconnected)
        #expect(await stream.nextElement() == .connecting)
        #expect(await stream.nextElement() == .connected)
        try await expDataCount.fulfillment(timeout: 1000)

        let dataCounts = await recorder.dataCounts.filter { $0 != DataCount() }
        #expect(!dataCounts.contains(DataCount(40, 0)))
        #expect(!dataCounts.contains(DataCount(80, 0)))
        #expect(dataCounts.contains(DataCount(140, 0)))
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
        let stream = sut.statusStream

        try await sut.start()
        #expect(await stream.nextElement() == .disconnected)
        #expect(await stream.nextElement() == .connecting)
        #expect(await stream.nextElement() == .connected)
        reachability.isReachable = false
        await sut.stop()
        #expect(await stream.nextElement() == .disconnecting)
        #expect(await stream.nextElement() == .disconnected)
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
        let stream = sut.statusStream

        try await sut.start()
        #expect(await stream.nextElement() == .disconnected)
        #expect(await stream.nextElement() == .connecting)
        #expect(await stream.nextElement() == .connected)
        reachability.isReachable = false
        await sut.stop()
        #expect(await stream.nextElement() == .disconnecting)
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
        reconnectionDelay: Int = 1000,
        snapshotInterval: Int = 1000,
        minDataCountDelta: UInt64 = 0,
        onSnapshot: OnTunnelSnapshotCallback? = nil
    ) async throws -> SimpleConnectionDaemon {
        let controller = MockTunnelController()
        controller.onCancelTunnelConnection = onCancel
        let options = ConnectionParameters.Options()
        let environment = environment ?? SharedTunnelEnvironment(profileId: profile.id)
        return try SimpleConnectionDaemon(params: .init(
            connectionFactory: MockConnectionFactory(),
            connectionParameters: .init(
                profile: profile,
                controller: controller,
                factory: MockNetworkInterfaceFactory(),
                reachability: reachability,
                environment: environment,
                options: options
            ),
            messageHandler: DefaultMessageHandler(.global, environment: environment),
            startsImmediately: false,
            stopDelay: stopDelay,
            reconnectionDelay: reconnectionDelay,
            snapshotInterval: snapshotInterval,
            minDataCountDelta: minDataCountDelta,
            onSnapshot: onSnapshot
        ))
    }
}

private actor SnapshotRecorder {
    private var snapshots: [TunnelSnapshot] = []

    func append(_ snapshot: TunnelSnapshot) {
        snapshots.append(snapshot)
    }

    var dataCounts: [DataCount] {
        snapshots.compactMap { $0.environment?.dataCount }
    }
}

private final class MockConnectionFactory: ConnectionFactory {
    func connection(for connectionModule: any ConnectionModule, parameters: ConnectionParameters) throws -> any Connection {
        try connectionModule.newConnection(with: nil, parameters: parameters)
    }
}

private final class MockReachabilityObserver: ReachabilityObserver, @unchecked Sendable {
    private nonisolated let isReachableSubject = PassthroughStream<Bool>()

    func startObserving() {
        isReachable = true
    }

    func stopObserving() {
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
        return MockConnection(options: options, reporter: parameters.reporter)
    }
}

private final class MockConnection: Connection {
    struct Options {
        var startError: Error?

        var failure: (interval: Int, error: Error)?

        var reportedError: (interval: Int, error: Error)?

        var reportedDataCounts: [(interval: Int, dataCount: DataCount)] = []

        var shouldTimeout = false
    }

    let options: Options

    let reporter: ConnectionReporter

    private let statusSubject = CurrentValueStream<ConnectionStatus>(.disconnected)

    var statusStream: AsyncThrowingStream<ConnectionStatus, Error> {
        statusSubject.subscribeThrowing()
    }

    func tunnel() -> IOInterface? {
        nil
    }

    nonisolated(unsafe)
    private var sleepTask: Task<Void, Never>?

    init(options: Options, reporter: ConnectionReporter) {
        self.options = options
        self.reporter = reporter
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
        if let reportedError = options.reportedError {
            Task {
                try? await Task.sleep(milliseconds: reportedError.interval)
                reporter.reportLastError(reportedError.error)
                statusSubject.send(.disconnected)
            }
        }
        for reportedDataCount in options.reportedDataCounts {
            Task {
                try? await Task.sleep(milliseconds: reportedDataCount.interval)
                reporter.reportDataCount(reportedDataCount.dataCount)
            }
        }
        return true
    }

    func stop(timeout: Int) async {
        if timeout == 0 {
            sleepTask?.cancel()
            return
        }
        statusSubject.send(.disconnecting)
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
