// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Basic implementation of ``ConnectionDaemon``.
public actor SimpleConnectionDaemon: ConnectionDaemon {
    private enum State {
        case initial
        case started
        case stopped
    }

    // MARK: Initialization

    public nonisolated let profile: Profile

    public nonisolated let environment: TunnelEnvironment

    private let connectionFactory: ConnectionFactory

    private let controller: TunnelController

    private let reachability: ReachabilityObserver

    private let messageHandler: MessageHandler

    private let startsImmediately: Bool

    private let stopDelay: Int

    private let reconnectionDelay: Int

    private var onStatus: StatusCallback?

    private var connection: Connection?

    private var networkObserver: NetworkObserver?

    // MARK: State

    private var state: State

    private let statusSubject: CurrentValueStream<ConnectionStatus>

    private var isEvaluatingConnection: Bool

    private var onHold: Bool

    private var settingsOnlyTunnel: IOInterface?

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
        connectionFactory = params.connectionFactory
        controller = params.connectionParameters.controller
        reachability = params.connectionParameters.reachability
        messageHandler = params.messageHandler
        startsImmediately = params.startsImmediately
        stopDelay = params.stopDelay
        reconnectionDelay = params.reconnectionDelay
        onStatus = params.onStatus

        state = .initial
        statusSubject = CurrentValueStream(.disconnected)
        isEvaluatingConnection = false
        onHold = false

        profile.log(.core, .notice, withPreamble: "Decoded profile:")
        guard profile.isFinal else {
            throw PartoutError(.nonFinalModules)
        }

        // Stop here unless there is a connection module
        guard let connectionModule = profile.activeConnectionModule else {
            connection = nil
            networkObserver = nil
            networkSubscription = nil
            statusSubscription = nil
            return
        }

        // Create the associated connection
        let connection = try connectionFactory.connection(
            for: connectionModule,
            parameters: params.connectionParameters
        )

        // Detect network changes while the connection is in
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
        pp_log_id(profile.id, .core, .debug, "Deinit SimpleConnectionDaemon")
    }

    public func start() async throws {
        guard state == .initial else {
            assertionFailure("Daemon may only start once")
            return
        }
        state = .started
        do {
            pp_log_id(profile.id, .core, .notice, "Start daemon")
            clearEnvironment()

            // Connection-based, start first connection and monitor for reconnections
            if connection != nil {
                environment.setEnvironmentValue(.disconnected, forKey: TunnelEnvironmentKeys.connectionStatus)

                // Monitor network events
                observeEvents()

                // Start the first connection right away
                if startsImmediately {
                    await evaluateConnection()
                }
            }
            // Otherwise, configure the tunnel immediately
            else {
                settingsOnlyTunnel = try await controller.setTunnelSettings(with: nil)
            }
            pp_log_id(profile.id, .core, .notice, "Daemon started successfully")
        } catch {
            pp_log_id(profile.id, .core, .fault, "Unable to start daemon: \(error)")
            environment.setEnvironmentValue(PartoutError(error).code, forKey: TunnelEnvironmentKeys.lastErrorCode)
            controller.setReasserting(false)
            controller.cancelTunnelConnection(with: error)
        }
        if !startsImmediately {
            networkObserver?.setEnabled(true)
        }
    }

    public func hold() async {
        guard !onHold else { return }
        onHold = true
        await stop()
    }

    public func stop() async {
        guard state != .stopped else {
            assertionFailure("Daemon is stopped")
            return
        }
        state = .stopped

        pp_log_id(profile.id, .core, .notice, "Stop daemon (\(onHold ? "keep" : "clear") environment)")

        // Prevent reconnection
        networkObserver?.setEnabled(false)

        // Cancel subscriptions before stopping connection
//        statusSubscription?.cancel()
        networkSubscription?.cancel()
        networkObserverTask?.cancel()

        // If there is a connection, disconnect with a timeout
        if let connection {
            pp_log_id(profile.id, .core, .notice, "Connection profile, disconnect with a timeout of \(stopDelay) milliseconds")
            await connection.stop(timeout: stopDelay)
        } else {
            pp_log_id(profile.id, .core, .notice, "Non-connection profile, nothing to disconnect from")
        }

        // Clear tunnel settings
        if let settingsOnlyTunnel {
            await controller.clearTunnelSettings(settingsOnlyTunnel, withKillSwitch: false)
        }

        // Make sure to clear environment on stop, especially last error code
        clearEnvironment()

        // Clean up
        reachability.stopObserving()
        networkObserver?.stopObserving()
        networkObserver = nil
        // NetworkObserver won't deinit until the connected
        // connection stream finishes
        connection = nil

        pp_log_id(profile.id, .core, .notice, "Daemon stopped successfully")
        reportStatus(.disconnected)
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
        guard !onHold else { return }
        pp_log_id(profile.id, .core, .notice, "Clear connection environment")
        environment.removeEnvironmentValue(forKey: TunnelEnvironmentKeys.connectionStatus)
        environment.removeEnvironmentValue(forKey: TunnelEnvironmentKeys.dataCount)
        environment.removeEnvironmentValue(forKey: TunnelEnvironmentKeys.lastErrorCode)
    }
}

// MARK: - Observation

extension SimpleConnectionDaemon {
    nonisolated var statusStream: AsyncStream<ConnectionStatus> {
        statusSubject.subscribe()
    }

    func observeEvents() {
        guard let connection, let networkObserver else {
            return
        }
        assert(statusSubscription == nil)
        assert(networkSubscription == nil)

        // IMPORTANT: Create streams BEFORE Task blocks. If we create
        // onNetworkReadyStream inside a Task, we might miss early
        // onReady events because Task objects might be executed after
        // the events are delivered.
        let connectionStatusStream = connection.statusStream.dropFirst()
        let onNetworkReadyStream = networkObserver.onReady.subscribe()

        // Observe the connection status (except the initial .disconnected)
        statusSubscription?.cancel()
        statusSubscription = Task { [weak self] in
            guard let self else { return }
            do {
                for try await status in connectionStatusStream {
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

        // Observe the network for starting the connection
        networkSubscription?.cancel()
        networkSubscription = Task { [weak self] in
            guard let self else { return }
            pp_log_id(profile.id, .core, .debug, "Network subscription started")
            for await isReady in onNetworkReadyStream {
                guard isReady else { continue }
                guard !Task.isCancelled else {
                    pp_log_id(profile.id, .core, .debug, "Cancelled NetworkObserver.onReady")
                    break
                }
                pp_log_id(profile.id, .core, .notice, "Network is ready, start connection")
                await evaluateConnection()
            }
            pp_log_id(profile.id, .core, .debug, "Network subscription terminated")
        }

        // Start monitoring
        networkObserver.startObserving()
        reachability.startObserving()
    }

    func evaluateConnection() async {
        guard state == .started else {
            pp_log_id(profile.id, .core, .info, "Ignore evaluation, daemon not started")
            return
        }
        guard let connection, let networkObserver else {
            assertionFailure("Calling evaluateConnection() without a connection?")
            return
        }

        // Do not perform more than once
        guard !isEvaluatingConnection else {
            pp_log_id(profile.id, .core, .debug, "Ignore evaluation, another one pending")
            return
        }
        isEvaluatingConnection = true
        defer {
            isEvaluatingConnection = false
        }

        testEvaluateConnection?()

        // Do not connect if on hold
        guard !onHold else {
            pp_log_id(profile.id, .core, .info, "Ignore evaluation, daemon on hold")
            return
        }
        // Do not connect if unreachable
        guard reachability.isReachable else {
            pp_log_id(profile.id, .core, .info, "Ignore evaluation, wait for reachable network")
            networkObserver.setEnabled(true)
            return
        }

        pp_log_id(profile.id, .core, .info, "Pause network observer during reconnection")
        networkObserver.setEnabled(false)

        // Try to connect if conditions are met
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
        guard state == .started else {
            pp_log_id(profile.id, .core, .info, "Ignore resume network observer, daemon not started")
            return
        }
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
            await networkObserver?.setEnabled(true)
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
        reportStatus(connectionStatus)
    }

    func onConnectionError(_ error: Error) {
        environment.setEnvironmentValue(PartoutError(error).code, forKey: TunnelEnvironmentKeys.lastErrorCode)
        controller.setReasserting(false)
    }

    func reportStatus(_ status: ConnectionStatus) {
        statusSubject.send(status)
        onStatus?(profile.id, status)
    }
}

// MARK: - Parameters

extension SimpleConnectionDaemon {
    public typealias StatusCallback = @Sendable (Profile.ID, ConnectionStatus) -> Void

    public final class Parameters: Sendable {
        let connectionFactory: ConnectionFactory

        let connectionParameters: ConnectionParameters

        let messageHandler: MessageHandler

        let startsImmediately: Bool

        let stopDelay: Int

        let reconnectionDelay: Int

        let onStatus: StatusCallback?

        public init(
            connectionFactory: ConnectionFactory,
            connectionParameters: ConnectionParameters,
            messageHandler: MessageHandler,
            startsImmediately: Bool,
            stopDelay: Int? = nil,
            reconnectionDelay: Int? = nil,
            onStatus: StatusCallback? = nil
        ) {
            self.connectionFactory = connectionFactory
            self.connectionParameters = connectionParameters
            self.messageHandler = messageHandler
            self.startsImmediately = startsImmediately
            self.stopDelay = stopDelay ?? 2000
            self.reconnectionDelay = reconnectionDelay ?? 2000
            self.onStatus = onStatus
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
