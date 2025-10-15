// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

extension CyclingConnection {

    /// Defines the behavior of a ``CyclingConnection``.
    public struct Hooks: @unchecked Sendable {

        /// The DNS resolver.
        public let dns: DNSResolver

        /// When a new link is created, returns the processed link.
        public let newLinkBlock: (LinkInterface) -> LinkInterface

        /// When a new link can be set to start the connection.
        public let startBlock: (_ newLink: LinkInterface) async throws -> Void

        /// When a better network path becomes available.
        public let upgradeBlock: () async -> Void

        /// When the connection is stopped on request.
        public let stopBlock: (_ currentLink: LinkInterface?, _ timeout: Int) async -> Void

        /// When the connection changes status.
        public let onStatusBlock: (_ connectionStatus: ConnectionStatus) -> Void

        /// When the connection fails.
        public let onErrorBlock: (_ connectionError: Error) -> Void

        public init(
            dns: DNSResolver? = nil,
            newLinkBlock: @escaping (LinkInterface) -> LinkInterface = { $0 },
            startBlock: @escaping (_ newLink: LinkInterface) async throws -> Void = { _ in },
            upgradeBlock: @escaping () async -> Void = {},
            stopBlock: @escaping (_ currentLink: LinkInterface?, _ timeout: Int) async -> Void = { _, _ in },
            onStatusBlock: @escaping (_ connectionStatus: ConnectionStatus) -> Void = { _ in },
            onErrorBlock: @escaping (_ connectionError: Error) -> Void = { _ in }
        ) {
            self.dns = dns ?? MockDNSResolver()
            self.newLinkBlock = newLinkBlock
            self.startBlock = startBlock
            self.upgradeBlock = upgradeBlock
            self.stopBlock = stopBlock
            self.onStatusBlock = onStatusBlock
            self.onErrorBlock = onErrorBlock
        }
    }
}

/// Smart ``Connection`` implementation establishing over a list of endpoints.
///
/// Automates cycling through a list of endpoints until a connection is successfully established. The connection creation implementation is provided by a ``NetworkInterfaceFactory``, while internal behavior is defined with the use of a ``CyclingConnection/Hooks`` object.
///
/// Make sure to only access this entity within the same actor.
@available(*, deprecated, message: "Merge into OpenVPNConnection")
public actor CyclingConnection {

    // MARK: Initialization

    private let ctx: PartoutLoggerContext

    private let factory: NetworkInterfaceFactory

    private let options: ConnectionParameters.Options

    private let endpoints: [ExtendedEndpoint]

    private nonisolated let statusSubject: CurrentValueStream<ConnectionStatus>

    private var hooks: Hooks

    // MARK: State

    var endpointResolver: EndpointResolver

    var currentLink: LinkInterface?

    private var pathSubscription: Task<Void, Never>?

    /// - Parameters:
    ///   - ctx: The context.
    ///   - factory: The factory implementing connection creation.
    ///   - options: The connection options.
    ///   - endpoints: The list of endpoints.
    public init(
        _ ctx: PartoutLoggerContext,
        factory: NetworkInterfaceFactory,
        options: ConnectionParameters.Options,
        endpoints: [ExtendedEndpoint]
    ) {
        self.ctx = ctx
        self.factory = factory
        self.options = options
        self.endpoints = endpoints
        statusSubject = CurrentValueStream(.disconnected)
        hooks = Hooks()
        endpointResolver = EndpointResolver(ctx, endpoints: endpoints)
    }

    /// Customizes behavior via new hooks.
    ///
    /// - Parameter hooks: The new ``CyclingConnection/Hooks`` object.
    public func setHooks(_ hooks: Hooks) {
        self.hooks = hooks
    }
}

// MARK: - Connection

extension CyclingConnection: Connection {
    public nonisolated var statusStream: AsyncThrowingStream<ConnectionStatus, Error> {
        statusSubject
            .subscribeThrowing()
            .removeDuplicates()
    }

    @discardableResult
    public func start() async throws -> Bool {
        guard status == .disconnected else {
            pp_log(ctx, .core, .error, "Ignore start, connection status \(status) != .disconnected")
            return false
        }
        sendStatus(.connecting)
        do {
            let newLink = try await setupLink(upgradingCurrent: false)
            try await hooks.startBlock(newLink)
            observeBetterPath(on: newLink)
            return true
        } catch {
            sendStatus(.disconnected)
            throw error
        }
    }

    public func stop(timeout: Int) async {
        guard status != .disconnected else {
            pp_log(ctx, .core, .error, "Ignore stop, connection not started")
            return
        }
        sendStatus(.disconnecting)
        await hooks.stopBlock(currentLink, timeout)
        sendStatus(.disconnected)
    }
}

// MARK: - Public API

extension CyclingConnection {
    public var status: ConnectionStatus {
        statusSubject.value
    }

    @discardableResult
    public func sendStatus(_ connectionStatus: ConnectionStatus) -> Bool {
        guard status.canChange(to: connectionStatus) else {
            pp_log(ctx, .core, .error, "Ignore unexpected status change: \(status) -> \(connectionStatus)")
            return false
        }
        pp_log(ctx, .core, .info, "Report link status: \(connectionStatus.debugDescription)")
        statusSubject.send(connectionStatus)
        hooks.onStatusBlock(connectionStatus)
        return true
    }

    public func sendError(_ connectionError: Error) {
        pp_log(ctx, .core, .info, "Report link failure: \(connectionError)")
        statusSubject.send(completion: .failure(connectionError))
        hooks.onErrorBlock(connectionError)
    }
}

// MARK: - Helpers

private extension CyclingConnection {
    func setupLink(upgradingCurrent: Bool) async throws -> LinkInterface {
        do {
            pp_log(ctx, .core, .notice, "Create new link")
            var newLink: LinkInterface

            // upgrade current link if possible
            if upgradingCurrent, let upgradedLink = try await currentLink?.upgraded() {
                pp_log(ctx, .core, .notice, "Will reconnect to current link")
                newLink = upgradedLink
            }
            // create new link
            else {
                pp_log(ctx, .core, .notice, "Cycle to next endpoint")
                let result = try await endpointResolver.withNextEndpoint(
                    dns: hooks.dns,
                    timeout: options.dnsTimeout
                )
                endpointResolver = result.nextResolver

                let linkObserver = try factory.linkObserver(to: result.endpoint)
                pp_log(ctx, .core, .notice, "Connect to \(result.endpoint.asSensitiveAddress(ctx))")
                newLink = try await linkObserver.waitForActivity(timeout: options.linkActivityTimeout)

                pp_log(ctx, .core, .notice, "Link is active")
                pp_log(ctx, .core, .info, "Link type is \(newLink.linkDescription)")
                newLink = hooks.newLinkBlock(newLink)
            }

            pp_log(ctx, .core, .info, "Processed link type is \(newLink.linkDescription)")

            currentLink = newLink
            return newLink
        } catch {
            pp_log(ctx, .core, .fault, "Unable to create link: \(error)")

            // reset endpoints on exhaustion
            if (error as? PartoutError)?.code == .exhaustedEndpoints {
                endpointResolver = EndpointResolver(ctx, endpoints: endpoints)
            }

            // stop here
            throw error
        }
    }

    func observeBetterPath(on link: LinkInterface) {
        pathSubscription?.cancel()
        pathSubscription = Task { [weak self] in
            guard let self else {
                return
            }
            for await _ in link.hasBetterPath {
                guard !Task.isCancelled else {
                    pp_log(ctx, .core, .debug, "Cancelled CyclingConnection.pathSubscription")
                    return
                }
                await hooks.upgradeBlock()
            }
        }
    }
}
