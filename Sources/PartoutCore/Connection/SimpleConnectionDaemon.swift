// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Basic implementation of ``ConnectionDaemon``.
public actor SimpleConnectionDaemon: ConnectionDaemon {

    // MARK: Initialization

    public nonisolated let profile: Profile

    public nonisolated let environment: TunnelEnvironment

    private let registry: Registry

    private let controller: TunnelController

    private let messageHandler: MessageHandler

    private let reachability: ReachabilityObserver

    private let stopDelay: Int

    private let reconnectionDelay: Int

    private var connection: Connection?

    private let networkObserver: NetworkObserver?

    // MARK: State

    private var isStarted: Bool

    private var isStopped: Bool

    private var isEvaluatingConnection: Bool

    private var onHold: Bool

    private var statusSubscription: Task<Void, Never>?

    private var networkSubscription: Task<Void, Never>?

    private var networkObserverTask: Task<Void, Error>?

    // MARK: Testing

    private var testEvaluateConnection: (() -> Void)?

    private var testOnExhaustedEndpoints: (() -> Void)?

    //

    public init(params: Parameters) throws {
        profile = params.connectionParameters.profile
        environment = params.connectionParameters.environment
        registry = params.registry
        controller = params.connectionParameters.controller
        messageHandler = params.messageHandler
        reachability = params.reachability
        stopDelay = params.stopDelay
        reconnectionDelay = params.reconnectionDelay

        isStarted = false
        isStopped = false
        isEvaluatingConnection = false
        onHold = false

        profile.log(.core, .notice, withPreamble: "Decoded profile:")
        guard profile.isFinal else {
            throw PartoutError(.nonFinalModules)
        }

        // stop here unless there is a connection module
        guard let connectionModule = profile.activeConnectionModule else {
            connection = nil
            networkObserver = nil
            networkSubscription = nil
            statusSubscription = nil
            return
        }

        // create the associated connection
        let connection = try registry.connection(
            for: connectionModule,
            parameters: params.connectionParameters
        )

        // detect network changes while the connection is in
        // the .disconnected status
        let networkObserver = NetworkObserver(
            PartoutLoggerContext(profile.id),
            reachabilityStream: reachability.isReachableStream,
            statusStream: connection.statusStream.replaceError(with: .disconnecting),
            isStatusReady: {
                $0 == .disconnected
            }
        )

        self.connection = connection
        self.networkObserver = networkObserver
    }

    deinit {
        pp_log_id(profile.id, .core, .info, "Deinit daemon")
    }

    public func start() async throws {
        assert(!isStarted, "Daemon already started")
        assert(!isStopped, "Daemon stopped and cannot restart")
        guard !isStarted && !isStopped else { return }
        isStarted = true
        do {
            pp_log_id(profile.id, .core, .notice, "Start daemon")
            clearEnvironment()

            // connection-based, start first connection and monitor for reconnections
            if connection != nil {
                environment.setEnvironmentValue(.disconnected, forKey: TunnelEnvironmentKeys.connectionStatus)

                // monitor network events
                observeEvents()

                // start the first connection right away
                await evaluateConnection()
            }
            // otherwise, configure the tunnel immediately
            else {
                _ = try await controller.setTunnelSettings(with: nil)
            }

            pp_log_id(profile.id, .core, .notice, "Daemon started successfully")
        } catch {
            pp_log_id(profile.id, .core, .fault, "Unable to start daemon: \(error)")
            environment.setEnvironmentValue(PartoutError(error).code, forKey: TunnelEnvironmentKeys.lastErrorCode)
            controller.setReasserting(false)
            controller.cancelTunnelConnection(with: error)
        }
    }

    public func hold() async {
        onHold = true
        await stop()
    }

    public func stop() async {
        assert(isStarted, "Daemon not started")
        guard isStarted else { return }
        pp_log_id(profile.id, .core, .notice, "Stop daemon (\(onHold ? "keep" : "clear") environment)")

        // prevent reconnection
        networkObserver?.setEnabled(false)

        // if there is a connection, disconnect with a timeout
        if let connection {
            pp_log_id(profile.id, .core, .notice, "Connection profile, disconnect with a timeout of \(stopDelay) milliseconds")
            await connection.stop(timeout: stopDelay)
        } else {
            pp_log_id(profile.id, .core, .notice, "Non-connection profile, nothing to disconnect from")
        }

        // make sure to clear environment on stop, especially last error code
        clearEnvironment()

        // cancel pending tasks to avoid leaks
        statusSubscription?.cancel()
        networkSubscription?.cancel()
        networkObserverTask?.cancel()

        pp_log_id(profile.id, .core, .notice, "Daemon stopped successfully")
        isStopped = true
    }

    public func destroy() {
        assert(isStopped, "Daemon not stopped")
        guard isStopped else { return }
        connection = nil
    }

    public func sendMessage(_ input: Message.Input) async throws -> Message.Output? {
        pp_log_id(profile.id, .core, .debug, "Handle message input: \(String(describing: input))")
        let output = try await messageHandler.handleMessage(input)
        pp_log_id(profile.id, .core, .debug, "Message successfully handled")
        return output
    }
}

private extension SimpleConnectionDaemon {
    func clearEnvironment() {
        guard !onHold else {
            return
        }
        pp_log_id(profile.id, .core, .notice, "Clear connection environment")
        environment.removeEnvironmentValue(forKey: TunnelEnvironmentKeys.connectionStatus)
        environment.removeEnvironmentValue(forKey: TunnelEnvironmentKeys.dataCount)
        environment.removeEnvironmentValue(forKey: TunnelEnvironmentKeys.lastErrorCode)
    }
}

// MARK: - Observation

extension SimpleConnectionDaemon {
    var statusStream: AsyncStream<ConnectionStatus>? {
        connection?.statusStream.ignoreErrors()
    }

    func observeEvents() {
        guard let connection, let networkObserver else {
            return
        }
        assert(statusSubscription == nil)
        assert(networkSubscription == nil)

        // observe the connection status (except the initial .disconnected)
        statusSubscription = Task { [weak self] in
            guard let self else { return }
            do {
                for try await status in connection.statusStream.dropFirst() {
                    guard !Task.isCancelled else {
                        pp_log_id(profile.id, .core, .debug, "Cancelled SimpleConnectionDaemon.statusStream")
                        return
                    }
                    await onConnectionStatus(status)
                }
            } catch {
                await onConnectionError(error)
            }
        }

        // observe the network for starting the connection
        networkSubscription = Task { [weak self] in
            guard let self else { return }
            for await _ in networkObserver.onReady.subscribe() {
                guard !Task.isCancelled else {
                    pp_log_id(profile.id, .core, .debug, "Cancelled NetworkObserver.onReady")
                    return
                }
                pp_log_id(profile.id, .core, .notice, "Network is ready, start connection")
                await evaluateConnection()
            }
        }

        // start monitoring
        reachability.startObserving()
    }

    func evaluateConnection() async {
        guard let connection, let networkObserver else {
            assertionFailure("Calling evaluateConnection() without a connection?")
            return
        }

        // do not perform more than once
        guard !isEvaluatingConnection else {
            pp_log_id(profile.id, .core, .debug, "Ignore evaluation, another one pending")
            return
        }
        isEvaluatingConnection = true
        defer {
            isEvaluatingConnection = false
        }

        testEvaluateConnection?()

        // do not connect if on hold
        guard !onHold else {
            pp_log_id(profile.id, .core, .info, "Ignore evaluation, daemon on hold")
            return
        }
        // do not connect if unreachable
        guard reachability.isReachable else {
            pp_log_id(profile.id, .core, .info, "Ignore evaluation, wait for reachable network")
            networkObserver.setEnabled(true)
            return
        }

        pp_log_id(profile.id, .core, .info, "Pause network observer during reconnection")
        networkObserver.setEnabled(false)

        // try to connect if conditions are met
        let didStart: Bool
        do {
            pp_log_id(profile.id, .core, .notice, "Start connection")
            didStart = try await connection.start()
        } catch {
            pp_log_id(profile.id, .core, .error, "Unable to start connection: \(error)")
            environment.setEnvironmentValue(PartoutError(error).code, forKey: TunnelEnvironmentKeys.lastErrorCode)
            return
        }

        // start() returns false if the connection is still active
        if !didStart {
            pp_log_id(profile.id, .core, .error, "Connection still active")
            resumeNetworkObserver(after: reconnectionDelay)
        }
    }

    func resumeNetworkObserver(after delay: Int) {
        guard !onHold else {
            pp_log_id(profile.id, .core, .info, "Ignore resume network observer, daemon on hold")
            return
        }
        networkObserverTask?.cancel()
        networkObserverTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }

            pp_log_id(profile.id, .core, .info, "Resume network observer in \(delay) milliseconds")
            try await Task.sleep(milliseconds: delay)

            guard !Task.isCancelled else { return }
            pp_log_id(profile.id, .core, .info, "Resume network observer now")
            networkObserver?.setEnabled(true)
        }
    }

    func onConnectionStatus(_ connectionStatus: ConnectionStatus) {
        environment.setEnvironmentValue(connectionStatus, forKey: TunnelEnvironmentKeys.connectionStatus)
        switch connectionStatus {
        case .connected:
            controller.setReasserting(false)
        case .connecting:
            environment.removeEnvironmentValue(forKey: TunnelEnvironmentKeys.lastErrorCode)
            controller.setReasserting(true)
        case .disconnecting:
            break
        case .disconnected:
            controller.setReasserting(false)
            resumeNetworkObserver(after: reconnectionDelay)
        }
    }

    func onConnectionError(_ error: Error) {
        environment.setEnvironmentValue(PartoutError(error).code, forKey: TunnelEnvironmentKeys.lastErrorCode)
        controller.setReasserting(false)
    }
}

// MARK: - Parameters

extension SimpleConnectionDaemon {
    public final class Parameters: Sendable {
        let registry: Registry

        let connectionParameters: ConnectionParameters

        let reachability: ReachabilityObserver

        let messageHandler: MessageHandler

        let stopDelay: Int

        let reconnectionDelay: Int

        public init(
            registry: Registry,
            connectionParameters: ConnectionParameters,
            reachability: ReachabilityObserver,
            messageHandler: MessageHandler,
            stopDelay: Int? = nil,
            reconnectionDelay: Int? = nil
        ) {
            self.registry = registry
            self.connectionParameters = connectionParameters
            self.reachability = reachability
            self.messageHandler = messageHandler
            self.stopDelay = stopDelay ?? 2000
            self.reconnectionDelay = reconnectionDelay ?? 2000
        }
    }
}

// MARK: Testing

extension SimpleConnectionDaemon {
    func setTestEvaluateConnection(_ testEvaluateConnection: @escaping () -> Void) {
        self.testEvaluateConnection = testEvaluateConnection
    }

    func setTestOnExhaustedEndpoints(_ testOnExhaustedEndpoints: @escaping () -> Void) {
        self.testOnExhaustedEndpoints = testOnExhaustedEndpoints
    }
}
