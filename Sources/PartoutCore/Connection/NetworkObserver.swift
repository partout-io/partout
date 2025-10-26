// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

/// Observes changes in the network.
public final class NetworkObserver: @unchecked Sendable {
    private let ctx: PartoutLoggerContext

    private let state: AtomicState

    private let signalSubject: CurrentValueStream<Bool>

    private let isStatusReady: (ConnectionStatus) -> Bool

    /// Publishes when the network state is ready for reconnection.
    public let onReady: PassthroughStream<Void>

    private var subscriptions: [Task<Void, Never>]

    /// Creates an observer tied to the availability of the network and the status of a ``Connection``.
    ///
    /// - Parameters:
    ///   - ctx: The context.
    ///   - reachabilityStream: Publishes the network reachability status.
    ///   - statusStream: Publishes the current ``ConnectionStatus``.
    ///   - isStatusReady: The condition to satisfy for the ``ConnectionStatus``.
    public init(
        _ ctx: PartoutLoggerContext,
        reachabilityStream: AsyncStream<Bool>,
        statusStream: AsyncStream<ConnectionStatus>,
        isStatusReady: @escaping (ConnectionStatus) -> Bool
    ) {
        self.ctx = ctx
        state = AtomicState()
        signalSubject = CurrentValueStream(false)
        self.isStatusReady = isStatusReady
        onReady = PassthroughStream()
        subscriptions = []

        observeObjects(reachabilityStream, statusStream)
    }

    public func setEnabled(_ isEnabled: Bool) {
        signalSubject.send(isEnabled)
    }
}

private extension NetworkObserver {
    func satisfied(by tuple: AtomicState.Tuple) -> Bool {
        tuple.signal && tuple.isNetworkAvailable && isStatusReady(tuple.connectionStatus)
    }

    func tryReady(_ value: AtomicState.Tuple) {
        let isSatisfied = satisfied(by: value)
        pp_log(ctx, .core, .info, "NetworkObserver.onReady(\(value.debugDescription)) -> \(isSatisfied)")
        guard isSatisfied else {
            return
        }
        onReady.send()
    }
}

private extension NetworkObserver {
    func observeObjects(_ reachabilityStream: AsyncStream<Bool>, _ statusStream: AsyncStream<ConnectionStatus>) {
        let signalSubscription = Task { [weak self] in
            guard let self else {
                return
            }
            for await signal in signalSubject.subscribe() {
                guard !Task.isCancelled else {
                    pp_log(ctx, .core, .debug, "Cancelled NetworkObserver.signalSubject")
                    return
                }
                guard let newState = await state.setSignal(signal) else {
                    continue
                }
                tryReady(newState)
            }
        }
        let reachabilitySubscription = Task { [weak self] in
            guard let self else {
                return
            }
            for await isNetworkAvailable in reachabilityStream {
                guard !Task.isCancelled else {
                    pp_log(ctx, .core, .debug, "Cancelled NetworkObserver.reachabilityStream")
                    return
                }
                guard let newState = await state.setIsNetworkAvailable(isNetworkAvailable) else {
                    continue
                }
                tryReady(newState)
            }
        }
        let statusSubscription = Task { [weak self] in
            guard let self else {
                return
            }
            for await connectionStatus in statusStream {
                guard !Task.isCancelled else {
                    pp_log(ctx, .core, .debug, "Cancelled NetworkObserver.statusStream")
                    return
                }
                guard let newState = await state.setConnectionStatus(connectionStatus) else {
                    continue
                }
                tryReady(newState)
            }
        }
        subscriptions = [signalSubscription, reachabilitySubscription, statusSubscription]
    }
}

// MARK: - AtomicState

private actor AtomicState {
    struct Tuple: Equatable, CustomDebugStringConvertible {
        var signal = false

        var isNetworkAvailable = false

        var connectionStatus: ConnectionStatus = .disconnected

        var debugDescription: String {
            "{signal=\(signal), network=\(isNetworkAvailable), status=\(connectionStatus)}"
        }
    }

    private var value: Tuple

    init() {
        value = Tuple()
    }

    func setSignal(_ signal: Bool) -> Tuple? {
        var copy = value
        copy.signal = signal
        return submit(copy)
    }

    func setIsNetworkAvailable(_ isNetworkAvailable: Bool) -> Tuple? {
        var copy = value
        copy.isNetworkAvailable = isNetworkAvailable
        return submit(copy)
    }

    func setConnectionStatus(_ connectionStatus: ConnectionStatus) -> Tuple? {
        var copy = value
        copy.connectionStatus = connectionStatus
        return submit(copy)
    }

    private func submit(_ newValue: Tuple) -> Tuple? {
        guard newValue != value else {
            return nil // .removeDuplicates()
        }
        value = newValue
        return value
    }
}
