// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_MONOLITH
import PartoutCore
#endif

/// Legacy ObjC version of ``OpenVPNConnection``. Apple-only.
@available(*, deprecated, message: "Use OpenVPNConnection")
public actor LegacyOpenVPNConnection {

    // MARK: Initialization

    private let ctx: PartoutLoggerContext

    private let moduleId: UniqueID

    private let controller: TunnelController

    private let environment: TunnelEnvironment

    private let options: ConnectionParameters.Options

    private let configuration: OpenVPN.Configuration

    private let sessionFactory: () async throws -> OpenVPNSessionProtocol

    let backend: CyclingConnection

    private let dns: DNSResolver

    // MARK: State

    private var hooks: CyclingConnection.Hooks?

    init(
        _ ctx: PartoutLoggerContext,
        parameters: ConnectionParameters,
        module: OpenVPNModule,
        prng: PRNGProtocol,
        dns: DNSResolver,
        sessionFactory: @escaping () async throws -> OpenVPNSessionProtocol
    ) throws {
        self.ctx = ctx
        moduleId = module.id
        controller = parameters.controller
        environment = parameters.environment
        options = parameters.options

        guard let configuration = module.configuration else {
            throw PartoutError(.incompleteModule)
        }
        guard let endpoints = configuration.processedRemotes(prng: prng),
              !endpoints.isEmpty else {
            fatalError("No OpenVPN remotes defined?")
        }
        pp_log(ctx, .openvpn, .notice, "OpenVPN: Using legacy connection")

        self.configuration = try configuration.withModules(from: parameters.profile)
        self.sessionFactory = sessionFactory
        self.dns = dns

        backend = CyclingConnection(
            ctx,
            factory: parameters.factory,
            options: options,
            endpoints: endpoints
        )
    }
}

// MARK: - Connection

extension LegacyOpenVPNConnection: Connection {
    public nonisolated var statusStream: AsyncThrowingStream<ConnectionStatus, Error> {
        backend.statusStream
    }

    @discardableResult
    public func start() async throws -> Bool {
        do {
            try await bindIfNeeded()
            return try await backend.start()
        } catch let error as PartoutError {
            if error.code == .exhaustedEndpoints, let reason = error.reason {
                throw reason
            }
            throw error
        }
    }

    public func stop(timeout: Int) async {
        await backend.stop(timeout: timeout)
    }
}

private extension LegacyOpenVPNConnection {
    func bindIfNeeded() async throws {
        guard hooks == nil else {
            return
        }

        let ctx = self.ctx
        let configuration = self.configuration
        let session = try await sessionFactory()

        let hooks = CyclingConnection.Hooks(dns: dns) { newLink in

            // wrap new link into a specific OpenVPN link
            newLink.openVPNLink(xorMethod: configuration.xorMethod)

        } startBlock: { newLink in

            try await session.setLink(newLink)

        } upgradeBlock: {

            // TODO: #143/notes, may improve this with floating
            pp_log(ctx, .openvpn, .notice, "Link has a better path, shut down session to reconnect")
            await session.shutdown(PartoutError(.networkChanged))

        } stopBlock: { _, timeout in

            // stop the OpenVPN connection on user request
            await session.shutdown(nil, timeout: TimeInterval(timeout) / 1000.0)

            // XXX: poll session status until link clean-up
            // in the future, make LegacyOpenVPNSession.shutdown() wait for stop async-ly
            let delta = 500
            var remaining = timeout
            while remaining > 0, await session.hasLink() {
                pp_log(ctx, .openvpn, .notice, "Link active, wait \(delta) milliseconds more")
                try? await Task.sleep(milliseconds: delta)
                remaining = max(0, remaining - delta)
            }
            if remaining > 0 {
                pp_log(ctx, .openvpn, .notice, "Link shut down gracefully")
            } else {
                pp_log(ctx, .openvpn, .error, "Link shut down due to timeout")
            }
        } onStatusBlock: { [weak self] status in

            self?.onStatus(status)

        } onErrorBlock: { [weak self] error in

            self?.onError(error)
        }

        self.hooks = hooks
        await backend.setHooks(hooks)
        await session.setDelegate(self)
    }
}

// MARK: - OpenVPNSessionDelegate

extension LegacyOpenVPNConnection: OpenVPNSessionDelegate {
    func sessionDidStart(
        _ session: OpenVPNSessionProtocol,
        remoteAddress: String,
        remoteProtocol: EndpointProtocol,
        remoteOptions: OpenVPN.Configuration,
        remoteFd: UInt64?
    ) async {
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

        environment.setEnvironmentValue(remoteOptions, forKey: TunnelEnvironmentKeys.OpenVPN.serverConfiguration)

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
                    fileDescriptors: []
                )
            )
            await session.setTunnel(tunnelInterface)

            // in this suspended interval, sessionDidStop may have been called and
            // the status may have changed to .disconnected in the meantime
            //
            // sendStatus() should prevent .connected from happening when in the
            // .disconnected state, because it must go through .connecting first

            // signal success and show the "VPN" icon
            if await backend.sendStatus(.connected) {
                pp_log(ctx, .openvpn, .notice, "Tunnel interface is now UP")
            }
        } catch {
            pp_log(ctx, .openvpn, .error, "Unable to start tunnel: \(error)")
            await session.shutdown(error)
        }
    }

    func sessionDidStop(_ session: OpenVPNSessionProtocol, withError error: Error?) async {
        if let error {
            pp_log(ctx, .openvpn, .error, "Session did stop: \(error)")
        } else {
            pp_log(ctx, .openvpn, .notice, "Session did stop")
        }

        // if user stopped the tunnel, let it go
        if await backend.status == .disconnecting {
            pp_log(ctx, .openvpn, .info, "User requested disconnection")
            return
        }

        // if error is not recoverable, just fail
        if let error, !error.isOpenVPNRecoverable {
            pp_log(ctx, .openvpn, .error, "Disconnection is not recoverable")
            await backend.sendError(error)
            return
        }

        // go back to the disconnected state (e.g. daemon will reconnect)
        await backend.sendStatus(.disconnected)
    }

    nonisolated func session(_ session: OpenVPNSessionProtocol, didUpdateDataCount dataCount: DataCount) async {
        guard await backend.status == .connected else {
            return
        }
        pp_log(ctx, .openvpn, .debug, "Updated data count: \(dataCount.debugDescription)")
        environment.setEnvironmentValue(dataCount, forKey: TunnelEnvironmentKeys.dataCount)
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

private extension LegacyOpenVPNConnection {
    nonisolated func onStatus(_ connectionStatus: ConnectionStatus) {
        switch connectionStatus {
        case .connected:
            break

        case .disconnected:
            environment.removeEnvironmentValue(forKey: TunnelEnvironmentKeys.dataCount)
            environment.removeEnvironmentValue(forKey: TunnelEnvironmentKeys.OpenVPN.serverConfiguration)

        default:
            break
        }
    }

    nonisolated func onError(_ connectionError: Error) {
        environment.removeEnvironmentValue(forKey: TunnelEnvironmentKeys.dataCount)
        environment.removeEnvironmentValue(forKey: TunnelEnvironmentKeys.OpenVPN.serverConfiguration)
    }
}

private extension LinkInterface {
    func openVPNLink(xorMethod: OpenVPN.ObfuscationMethod?) -> LinkInterface {
        switch linkType.plainType {
        case .udp:
            return LegacyOpenVPNUDPLink(link: self, xorMethod: xorMethod)

        case .tcp:
            return LegacyOpenVPNTCPLink(link: self, xorMethod: xorMethod)
        }
    }
}
