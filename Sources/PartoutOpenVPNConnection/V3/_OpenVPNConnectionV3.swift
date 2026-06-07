// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !USE_CMAKE
@_exported import PartoutOpenVPN
#endif

/// Swift/C implementation of an OpenVPN connection.
public actor _OpenVPNConnectionV3 {
    private let ctx: PartoutLoggerContext

    private let statusSubject: CurrentValueStream<ConnectionStatus>

    private let delegateSubject: PassthroughStream<DelegateEvent>

    private let moduleId: UniqueID

    private let controller: TunnelController

    private let reporter: ConnectionReporter

    private let factory: NetworkInterfaceFactory

    private let options: ConnectionParameters.Options

    private let endpoints: [ExtendedEndpoint]

    private let configuration: OpenVPN.Configuration

    private let sessionFactory: () throws -> OpenVPNSessionProtocolV3

    private let dns: DNSResolver

    // MARK: State

    private var delegateTask: Task<Void, Never>?

    private var currentSession: OpenVPNSessionProtocolV3?

    private var endpointResolver: EndpointResolver

    private var currentLink: LinkInterface?

    private var tunnelInterface: IOInterface?

    private var pathSubscription: Task<Void, Never>?

    init(
        _ ctx: PartoutLoggerContext,
        parameters: ConnectionParameters,
        module: OpenVPNModule,
        prng: PRNGProtocol,
        dns: DNSResolver,
        sessionFactory: @escaping () throws -> OpenVPNSessionProtocolV3
    ) throws {
        self.ctx = ctx
        statusSubject = CurrentValueStream(.disconnected)
        delegateSubject = PassthroughStream()
        moduleId = module.id
        controller = parameters.controller
        reporter = parameters.reporter
        factory = parameters.factory
        options = parameters.options

        guard let configuration = module.configuration else {
            throw PartoutError(.incompleteModule)
        }
        guard let endpoints = configuration.processedRemotes(prng: prng),
              !endpoints.isEmpty else {
            fatalError("No OpenVPN remotes defined?")
        }

        self.configuration = try configuration.withModules(from: parameters.profile)
        self.sessionFactory = sessionFactory
        self.dns = dns
        self.endpoints = endpoints
        endpointResolver = EndpointResolver(ctx, endpoints: endpoints)
    }

    deinit {
        pp_log(ctx, .openvpn, .debug, "Deinit _OpenVPNConnectionV3")
    }
}

// MARK: - Connection

extension _OpenVPNConnectionV3: Connection {
    public nonisolated var statusStream: AsyncThrowingStream<ConnectionStatus, Error> {
        statusSubject.subscribeThrowing().removeDuplicates()
    }

    @discardableResult
    public func start() async throws -> Bool {
        do {
            if currentSession == nil {
                currentSession = try sessionFactory()
            }
            guard let session = currentSession else {
                fatalError("No session from factory?")
            }
            subscribeToDelegate()
            session.setDelegate(self)
            guard status == .disconnected else {
                pp_log(ctx, .openvpn, .error, "Ignore start, connection status \(status) != .disconnected")
                return false
            }
            sendStatus(.connecting)
            do {
                let newLink = try await setupLink(upgradingCurrent: false)
                try await session.setLink(newLink)
                observeBetterPath(on: newLink)
                return true
            } catch {
                sendStatus(.disconnected)
                throw error
            }
        } catch let error as PartoutError {
            await currentSession?.shutdown(error)
            if error.code == .exhaustedEndpoints, let reason = error.reason {
                throw reason
            }
            throw error
        } catch {
            await currentSession?.shutdown(error)
            throw error
        }
    }

    public func stop(timeout: Int) async {
        guard let currentSession else { return }
        guard status != .disconnected else {
            pp_log(ctx, .openvpn, .error, "Ignore stop, connection not started")
            return
        }
        sendStatus(.disconnecting)

        // Stop the OpenVPN connection on user request
        await currentSession.shutdown(nil, timeout: TimeInterval(timeout) / 1000.0)

        // XXX: Poll session status until link clean-up
        // In the future, make OpenVPNSession.shutdown() wait for stop async-ly
        let delta = 500
        var remaining = timeout
        while remaining > 0, currentSession.hasLink() {
            pp_log(ctx, .openvpn, .notice, "Link active, wait \(delta) milliseconds more")
            try? await Task.sleep(milliseconds: delta)
            remaining = max(0, remaining - delta)
        }
        if remaining > 0 {
            pp_log(ctx, .openvpn, .notice, "Link shut down gracefully")
        } else {
            pp_log(ctx, .openvpn, .error, "Link shut down due to timeout")
        }

        sendStatus(.disconnected)
    }
}

// MARK: - OpenVPNSessionDelegate

extension _OpenVPNConnectionV3: OpenVPNSessionDelegateV3 {
    nonisolated func sessionDidStart(
        _ session: OpenVPNSessionProtocolV3,
        remoteAddress: String,
        remoteProtocol: EndpointProtocol,
        remoteOptions: OpenVPN.Configuration,
        remoteFd: UInt64?
    ) {
        delegateSubject.send(.didStart(
            session,
            remoteAddress: remoteAddress,
            remoteProtocol: remoteProtocol,
            remoteOptions: remoteOptions,
            remoteFd: remoteFd
        ))
    }

    nonisolated func sessionDidStop(_ session: OpenVPNSessionProtocolV3, withError error: Error?) {
        delegateSubject.send(.didStop(
            session,
            error: error
        ))
    }

    nonisolated func session(_ session: OpenVPNSessionProtocolV3, didUpdateDataCount dataCount: DataCount) {
        delegateSubject.send(.didUpdateDataCount(
            session,
            dataCount: dataCount
        ))
    }
}

private extension _OpenVPNConnectionV3 {
    enum DelegateEvent: Sendable {
        case didStart(
            _ session: OpenVPNSessionProtocolV3,
            remoteAddress: String,
            remoteProtocol: EndpointProtocol,
            remoteOptions: OpenVPN.Configuration,
            remoteFd: UInt64?
        )
        case didStop(
            _ session: OpenVPNSessionProtocolV3,
            error: Error?
        )
        case didUpdateDataCount(
            _ session: OpenVPNSessionProtocolV3,
            dataCount: DataCount
        )
    }

    func subscribeToDelegate() {
        guard delegateTask == nil else { return }
        let stream = delegateSubject.subscribe()
        delegateTask = Task { [weak self] in
            for await event in stream {
                await self?.handleDelegate(event)
            }
        }
    }

    func handleDelegate(_ event: DelegateEvent) async {
        switch event {
        case .didStart(
            let session,
            let remoteAddress,
            let remoteProtocol,
            let remoteOptions,
            _ // remoteFd
        ):
            let addressObject = Address(rawValue: remoteAddress)
            if addressObject == nil {
                pp_log(ctx, .openvpn, .error, "Unable to parse remote tunnel address")
            }

            pp_log(ctx, .openvpn, .notice, "Session did start")
            pp_log(ctx, .openvpn, .info, "\tAddress: \(remoteAddress.asSensitiveAddress(ctx))")
            pp_log(ctx, .openvpn, .info, "\tProtocol: \(remoteProtocol)")

            pp_log(ctx, .openvpn, .notice, "Local options:")
            configuration.print(ctx, isLocal: true)
            pp_log(ctx, .openvpn, .notice, "Remote options:")
            remoteOptions.print(ctx, isLocal: false)

            reporter.reportEnvironmentValue(remoteOptions, forKey: TunnelEnvironmentKeys.OpenVPN.serverConfiguration)

            let builder = NetworkSettingsBuilder(
                ctx,
                localOptions: configuration,
                remoteOptions: remoteOptions
            )
            builder.print()
            do {
                let tunnelInterface = try await controller.setTunnelSettings(
                    with: TunnelRemoteInfo(
                        originalModuleId: moduleId,
                        address: addressObject,
                        modules: builder.modules(),
                        requiresVirtualDevice: true
                    )
                )
                self.tunnelInterface = tunnelInterface
                try await session.setTunnel(tunnelInterface)

                // In this suspended interval, sessionDidStop may have been called and
                // the status may have changed to .disconnected in the meantime
                //
                // sendStatus() should prevent .connected from happening when in the
                // .disconnected state, because it must go through .connecting first

                // Signal success and show the "VPN" icon
                if sendStatus(.connected) {
                    pp_log(ctx, .openvpn, .notice, "Tunnel interface is now UP")
                }
            } catch {
                pp_log(ctx, .openvpn, .error, "Unable to start tunnel: \(error)")
                await session.shutdown(error)
            }
        case .didStop(_, let error):
            if let error {
                pp_log(ctx, .openvpn, .error, "Session did stop: \(error)")
            } else {
                pp_log(ctx, .openvpn, .notice, "Session did stop")
            }

            // Clean up tunnel
            if let tunnelInterface {
                await controller.clearTunnelSettings(tunnelInterface)
                self.tunnelInterface = nil
            }

            // If user stopped the tunnel, let it go
            guard status != .disconnecting else {
                pp_log(ctx, .openvpn, .info, "User requested disconnection")
                return
            }

            // Store last error
            if let error {
                reporter.reportLastError(error)

                // If error is not recoverable, just fail
                guard error.isOpenVPNRecoverable else {
                    pp_log(ctx, .openvpn, .error, "Disconnection is not recoverable")
                    sendError(error)
                    return
                }
            }

            // Go back to the disconnected state (e.g. daemon will reconnect)
            sendStatus(.disconnected)
        case .didUpdateDataCount(_, let dataCount):
            guard status == .connected else {
                return
            }
            pp_log(ctx, .openvpn, .debug, "Updated data count: \(dataCount.debugDescription)")
            reporter.reportDataCount(dataCount)
        }
    }
}

// MARK: - Helpers

private extension OpenVPN.Configuration {
    func withModules(from profile: Profile) throws -> Self {
        var newBuilder = builder()
        let ipModules = profile.activeModules
            .compactMap {
                $0 as? IPModule
            }

        ipModules.forEach { ipModule in
            var policies = newBuilder.routingPolicies ?? []
            if !policies.contains(.IPv4), ipModule.shouldAddIPv4Policy {
                policies.append(.IPv4)
            }
            if !policies.contains(.IPv6), ipModule.shouldAddIPv6Policy {
                policies.append(.IPv6)
            }
            newBuilder.routingPolicies = policies
        }
        return try newBuilder.build(isClient: true)
    }
}

private extension IPModule {
    var shouldAddIPv4Policy: Bool {
        guard let ipv4 else {
            return false
        }
        let defaultRoute = Route(defaultWithGateway: nil)
        return ipv4.includedRoutes.contains(defaultRoute) && !ipv4.excludedRoutes.contains(defaultRoute)
    }

    var shouldAddIPv6Policy: Bool {
        guard let ipv6 else {
            return false
        }
        let defaultRoute = Route(defaultWithGateway: nil)
        return ipv6.includedRoutes.contains(defaultRoute) && !ipv6.excludedRoutes.contains(defaultRoute)
    }
}

extension _OpenVPNConnectionV3 {
    var status: ConnectionStatus {
        statusSubject.value
    }
}

private extension _OpenVPNConnectionV3 {
    @discardableResult
    func sendStatus(_ connectionStatus: ConnectionStatus) -> Bool {
        guard status.canChange(to: connectionStatus) else {
            pp_log(ctx, .openvpn, .error, "Ignore unexpected status change: \(status) -> \(connectionStatus)")
            return false
        }
        pp_log(ctx, .openvpn, .info, "Report link status: \(connectionStatus.debugDescription)")
        statusSubject.send(connectionStatus)
        onStatus(connectionStatus)
        return true
    }

    func sendError(_ connectionError: Error) {
        pp_log(ctx, .openvpn, .info, "Report link failure: \(connectionError)")
        statusSubject.send(completion: .failure(connectionError))
        onError(connectionError)
    }

    nonisolated func onStatus(_ connectionStatus: ConnectionStatus) {
        switch connectionStatus {
        case .connected:
            break
        case .disconnected:
            reporter.clearDataCount()
            reporter.clearEnvironmentValue(forKey: TunnelEnvironmentKeys.OpenVPN.serverConfiguration)
        default:
            break
        }
    }

    nonisolated func onError(_ connectionError: Error) {
        reporter.clearDataCount()
        reporter.clearEnvironmentValue(forKey: TunnelEnvironmentKeys.OpenVPN.serverConfiguration)
    }
}

private extension LinkInterface {
    func openVPNLink(method: OpenVPN.ObfuscationMethod?) -> LinkInterface {
        switch linkType.plainType {
        case .udp:
            return OpenVPNUDPLink(link: self, method: method)
        case .tcp:
            return OpenVPNTCPLink(link: self, method: method)
        }
    }
}

// MARK: - Helpers

private extension _OpenVPNConnectionV3 {
    func setupLink(upgradingCurrent: Bool) async throws -> LinkInterface {
        do {
            pp_log(ctx, .openvpn, .notice, "Create new link")
            var newLink: LinkInterface

            // upgrade current link if possible
            if upgradingCurrent, let upgradedLink = try await currentLink?.upgraded() {
                pp_log(ctx, .openvpn, .notice, "Will reconnect to current link")
                newLink = upgradedLink
            }
            // create new link
            else {
                pp_log(ctx, .openvpn, .notice, "Cycle to next endpoint")
                let result = try await endpointResolver.withNextEndpoint(
                    dns: dns,
                    timeout: options.dnsTimeout
                )
                endpointResolver = result.nextResolver

                let linkObserver = try factory.linkObserver(to: result.endpoint)
                pp_log(ctx, .openvpn, .notice, "Connect to \(result.endpoint.asSensitiveAddress(ctx))")
                newLink = try await linkObserver.waitForActivity(timeout: options.linkActivityTimeout)

                pp_log(ctx, .openvpn, .notice, "Link is active")
                pp_log(ctx, .openvpn, .info, "Link type is \(newLink.linkDescription)")
                // Wrap new link into a specific OpenVPN link
                newLink = newLink.openVPNLink(method: configuration.xorMethod)
            }

            pp_log(ctx, .openvpn, .info, "Processed link type is \(newLink.linkDescription)")

            currentLink = newLink
            return newLink
        } catch {
            pp_log(ctx, .openvpn, .fault, "Unable to create link: \(error)")

            // reset endpoints on exhaustion
            if error.partoutErrorCode == .exhaustedEndpoints {
                endpointResolver = EndpointResolver(ctx, endpoints: endpoints)
            }

            // stop here
            throw error
        }
    }

    func observeBetterPath(on link: LinkInterface) {
        pathSubscription?.cancel()
        pathSubscription = Task { [weak self, weak link] in
            guard let link else { return }
            for await _ in link.hasBetterPath {
                guard let self else { return }
                guard !Task.isCancelled else {
                    pp_log(ctx, .openvpn, .debug, "Cancelled CyclingConnection.pathSubscription")
                    return
                }
                // TODO: #143/notes, may improve this with floating (establish the new socket FIRST, then shut down the old one, and FINALLY move work to the new one. this should be seamless with UDP)
                pp_log(ctx, .openvpn, .notice, "Link has a better path, shut down session to reconnect")
                await currentSession?.shutdown(PartoutError(.networkChanged))
            }
        }
    }
}
