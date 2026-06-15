// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Partout_C

@PartoutABI
public final class DaemonABI {
    public struct Options: Sendable {
        let profile: Profile
        let cachesURL: URL
        let isDaemon: Bool
        let minDataCountDelta: UInt64

        init(_ args: partout_daemon_start_args) throws {
            guard let cProfileJSON = args.profile,
                  let profileData = String(cString: cProfileJSON).data(using: .utf8),
                  let cCacheDir = args.cache_dir else {
                throw PartoutError(.decoding)
            }
            let decoder = JSONDecoder.shared()
            profile = try decoder.decode(TaggedProfile.self, from: profileData).asProfile()
            cachesURL = URL(filePath: String(cString: cCacheDir))
            isDaemon = args.is_daemon
            minDataCountDelta = args.min_data_count_delta
        }
    }

    private let daemon: SimpleConnectionDaemon
    private nonisolated(unsafe) let bindings: partout_daemon_bindings?

    // TODO: #218, cachesURL must be per-profile
    public init(
        options: Options,
        bindings: partout_daemon_bindings?
    ) throws {
        let profile = options.profile
        let ctx = PartoutLoggerContext(profile.id)
        let environment = SharedTunnelEnvironment(profileId: profile.id)

        // Compute known implementations
        let registry = Registry(
            withKnown: true,
            allImplementations: Self.moduleImplementations(ctx, options: options)
        )

        // Create platform-specific objects
        let betterPathFactory: BetterPathStreamFactory?
#if os(Darwin)
        betterPathFactory = NEBetterPathStreamFactory(ctx)
#else
        betterPathFactory = nil // Delegated from C
#endif
        let controller = try NativeTunnelController(
            ctx,
            ref: bindings?.controller,
            environment: environment,
            betterPathFactory: betterPathFactory
        )
        let factory = controller.newSocketFactory()

        let connectionOptions = ConnectionParameters.Options()
        let connectionParameters = ConnectionParameters(
            profile: profile,
            controller: controller,
            factory: factory,
            reachability: controller,
            environment: environment,
            options: connectionOptions
        )
        let daemonParameters = SimpleConnectionDaemon.Parameters(
            connectionFactory: registry,
            connectionParameters: connectionParameters,
            messageHandler: DefaultMessageHandler(ctx, environment: environment),
            startsImmediately: false,
            cancelsUnrecoverable: true,
            minDataCountDelta: options.minDataCountDelta
        )

        daemon = try SimpleConnectionDaemon(params: daemonParameters)
        self.bindings = bindings
    }

    deinit {
        if var bindings {
            bindings.free(&bindings)
        }
    }

    func start() async throws {
        try await daemon.start()
    }

    func stop() async {
        await daemon.stop()
    }
}

private extension DaemonABI {
    typealias OpenVPNConnection = _OpenVPNConnectionV3
    typealias WireGuardConnection = _WireGuardConnectionV2

    static func moduleImplementations(
        _ ctx: PartoutLoggerContext,
        options: Options
    ) -> [ModuleImplementation] {
        var list: [ModuleImplementation] = []
#if PARTOUT_OPENVPN
        list.append(OpenVPNModule.Implementation(
            importerBlock: {
                StandardOpenVPNParser()
            },
            connectionBlock: { parameters, module in
                try OpenVPNConnection(
                    ctx,
                    parameters: parameters,
                    module: module,
                    cachesURL: options.cachesURL
                )
            }
        ))
#endif
#if PARTOUT_WIREGUARD
        list.append(WireGuardModule.Implementation(
            keyGenerator: StandardWireGuardKeyGenerator(),
            importerBlock: {
                StandardWireGuardParser()
            },
            validatorBlock: {
                StandardWireGuardParser()
            },
            connectionBlock: { parameters, module in
                try WireGuardConnection(
                    ctx,
                    parameters: parameters,
                    module: module
                )
            }
        ))
#endif
        return list
    }
}
