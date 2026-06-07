// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Default implementation of `OpenVPNSessionProtocol`.
final class OpenVPNSessionV3: @unchecked Sendable {
    let ctx: PartoutLoggerContext
    private let configuration: OpenVPN.Configuration
    private let credentials: OpenVPN.Credentials?
    private let prng: PRNGProtocol
    let cachesURL: URL
    let options: OpenVPNConnectionOptions
    private let tlsFactory: TLSFactory
    private let dpFactory: DataPathFactory
    private let queue: DispatchQueue
    private let queueKey: DispatchSpecificKey<Void>
    // FIXME: ###, Workaround for self in init closures
    var looper: FdLooper!
    private weak var delegate: OpenVPNSessionDelegateV3?

    // MARK: Mutable state

    private let controlChannel: ControlChannelV3
    var sessionState: SessionState

    func preconditionOnQueue() {
        precondition(
            DispatchQueue.getSpecific(key: queueKey) != nil,
            "OpenVPNSessionV3 state accessed outside its queue"
        )
    }

    /**
     Creates a VPN session.

     - Parameters:
       - ctx: The context.
       - configuration: The `Configuration` to use for this session.
       - credentials: The optional credentials.
       - prng: The pseudo-random number generator.
       - tlsFactory: The TLS implementation.
       - cryptoFactory: The cryptographic implementation.
       - cachesURL: The URL of the folder where to store cache files.
       - options: Options for fine-tuning.
     - Precondition: `configuration.ca` must be non-nil.
     - Throws: If cryptographic or TLS initialization fails.
     */
    init(
        _ ctx: PartoutLoggerContext,
        configuration: OpenVPN.Configuration,
        credentials: OpenVPN.Credentials?,
        prng: PRNGProtocol,
        cachesURL: URL,
        options: OpenVPNConnectionOptions = .init(),
        tlsFactory: @escaping TLSFactory,
        dpFactory: @escaping DataPathFactory
    ) throws {
        self.ctx = ctx
        self.configuration = configuration
        self.credentials = try credentials?.forAuthentication()
        self.prng = prng
        self.cachesURL = cachesURL
        self.options = options
        self.tlsFactory = tlsFactory
        self.dpFactory = dpFactory

        queue = DispatchQueue(label: "OpenVPNSession[\(ctx.profileId?.description ?? "*")]")
        queueKey = DispatchSpecificKey()
        queue.setSpecific(key: queueKey, value: ())
        controlChannel = try Self.newControlChannel(
            ctx,
            with: prng,
            configuration: configuration
        )
        sessionState = .stopped(IdleContext(withLocalOptions: true))

        looper = try FdLooper(ctx, queue: queue) { [weak self] error in
            pp_log(self?.ctx ?? .global, .openvpn, .error, "Session looper finished with error: \(error?.localizedDescription ?? "none")")
            self?.looperDidFinish(error)
        }
        looper.start()
    }

    deinit {
        pp_log(ctx, .openvpn, .debug, "Deinit OpenVPNSession")
    }
}

// MARK: - Public API

extension OpenVPNSessionV3: OpenVPNSessionProtocolV3 {
    func setDelegate(_ delegate: OpenVPNSessionDelegateV3) {
        looper.schedule { [weak self] in
            self?.delegate = delegate
        }
    }

    func setLink(_ link: LinkInterface) async throws {
        guard !looper.isLinkAttached else {
            pp_log(ctx, .openvpn, .error, "Link interface already set")
            return
        }
        let proc = PacketProcessor(method: configuration.xorMethod)
        let rw = LinkProcessor(proc: proc, isTCP: link.isReliable)
        try await looper.attach(.init(
            side: .link,
            original: link,
            beforeRead: rw.beforeRead,
            onRead: { [weak self] packets in
                try self?.receiveLink(packets)
                return .keep
            },
            transformWrite: rw.beforeWrite
        ))
        try looper.schedule { [weak self] in
            try self?.setLinkOnQueue(link)
        }
    }

    func setTunnel(_ tunnel: IOInterface) async throws {
        guard looper.isLinkAttached else {
            pp_log(ctx, .openvpn, .error, "Set link interface first")
            return
        }
        guard !looper.isTunAttached else {
            pp_log(ctx, .openvpn, .error, "Tunnel interface already set")
            return
        }
        pp_log(ctx, .openvpn, .info, "Start TUN loop")
        try await looper.attach(.init(
            side: .tun,
            original: tunnel,
            beforeRead: nil,
            onRead: { [weak self] packets in
                try self?.receiveTunnel(packets)
                return .keep
            },
            transformWrite: nil
        ))
    }

    func hasLink() -> Bool {
        looper.isLinkAttached
    }

    func shutdown(_ error: Error?, timeout: TimeInterval?) async {
        do {
            let shouldDetach = try await looper.perform { [weak self] in
                self?.prepareShutdownOnQueue(error, timeout: timeout) ?? false
            }
            guard shouldDetach else {
                return
            }
            await looper.detach(.tun)
            await looper.detach(.link)
            try await looper.perform { [weak self] in
                self?.finishShutdownOnQueue(error)
            }
        } catch {
            pp_log(ctx, .openvpn, .error, "Unable to shut down session on looper queue: \(error)")
        }
    }
}

private extension OpenVPNSessionV3 {
    func setLinkOnQueue(_ link: LinkInterface) throws {
        preconditionOnQueue()
        guard let idleContext else {
            pp_log(ctx, .openvpn, .error, "Session is not stopped")
            throw PartoutError(.operationCancelled)
        }
        pp_log(ctx, .openvpn, .info, "Start VPN session")
        let dataLink = DataLink(
            ctx: ctx,
            looper: looper,
            dataChannel: { [weak self] in
                self?.activeContext?.dataChannels[$0]
            },
            reportInboundDataCount: { [weak self] in
                self?.reportInboundDataCount($0)
            },
            reportOutboundDataCount: { [weak self] in
                self?.reportOutboundDataCount($0)
            }
        )
        sessionState = .active(.starting, ActiveContext(
            ctx: ctx,
            dataLink: dataLink,
            withLocalOptions: idleContext.withLocalOptions,
            linkMetadata: link.metadata
        ))
        do {
            try startNegotiation(on: looper, linkMetadata: link.metadata)
        } catch {
            withActiveContext { context in
                context.reset()
            }
            sessionState = .stopped(idleContext)
            throw error
        }
    }

    func prepareShutdownOnQueue(_ error: Error?, timeout: TimeInterval?) -> Bool {
        preconditionOnQueue()
        guard activePhase != .stopping, activePhase != nil else {
            pp_log(ctx, .openvpn, .debug, "Ignore stop request, stopped or already stopping")
            return false
        }
        // Report .stopping phase
        if let error {
            pp_log(ctx, .openvpn, .error, "Shut down with failure: \(error)")
        } else {
            pp_log(ctx, .openvpn, .info, "Shut down on request")
        }
        withActiveContext { phase, _ in
            phase = .stopping
        }

        // Shut down after sending exit notification if link is unreliable (normally UDP)
        if error == nil || error?.partoutErrorCode == .networkChanged {
            do {
                try sendExitPacketOnQueue()
            } catch {
                pp_log(ctx, .openvpn, .error, "Unable to send exit packet: \(error)")
            }
        }
        return true
    }

    func finishShutdownOnQueue(_ error: Error?) {
        preconditionOnQueue()
        guard activePhase != nil else {
            return
        }
        withActiveContext { context in
            context.reset()
        }

        // Migrate context to go back to .stopped state
        let nextWithLocalOptions: Bool
        switch sessionState {
        case .stopped(let context):
            nextWithLocalOptions = context.withLocalOptions
        case .active(_, let context):
            if case .badCredentialsWithLocalOptions = error as? OpenVPNSessionError {
                nextWithLocalOptions = false
            } else {
                nextWithLocalOptions = context.withLocalOptions
            }
        }
        sessionState = .stopped(IdleContext(withLocalOptions: nextWithLocalOptions))

        delegate?.sessionDidStop(
            self,
            withError: error.map(OpenVPNSessionError.init) ?? error
        )
    }

    func looperDidFinish(_ error: Error?) {
        preconditionOnQueue()
        finishShutdownOnQueue(error)
    }
}

private extension OpenVPNSessionV3 {
    func sendExitPacketOnQueue() throws {
        preconditionOnQueue()
        try withActiveContext { context in
            guard !context.linkMetadata.isReliable, let dataPair = context.currentDataPair else {
                return
            }
            pp_log(ctx, .openvpn, .info, "Send OCCPacket exit")
            try dataPair.send([OCCPacket.exit.serialized()])
            pp_log(ctx, .openvpn, .info, "Sent OCCPacket correctly")
        }
    }
}

// MARK: - Private API

extension OpenVPNSessionV3 {
    var isStopped: Bool {
        activePhase == nil
    }

    var currentNegotiator: NegotiatorV3? {
        activeContext?.currentNegotiator
    }

    var currentDataPair: DataLinkPair? {
        activeContext?.currentDataPair
    }

    func newNegotiator(on looper: FdLooper, linkMetadata: LinkMetadata) throws -> NegotiatorV3 {
        guard let activeContext else {
            throw OpenVPNSessionError.assertion
        }
        let negOptions = NegotiatorV3.Options(
            configuration: configuration,
            credentials: credentials,
            withLocalOptions: activeContext.withLocalOptions,
            sessionOptions: options,
            onConnected: { [weak self] key, dataChannel, pushReply in
                self?.didNegotiate(
                    key: key,
                    dataChannel: dataChannel,
                    pushReply: pushReply
                )
            },
            onError: { [weak self] _, error in
                Task {
                    await self?.shutdown(error)
                }
            }
        )
        let tlsParameters = TLSWrapper.Parameters(
            cachesURL: cachesURL,
            cfg: configuration,
            onVerificationFailure: { [weak self] in
                Task {
                    await self?.shutdown(PPTLSError.peerVerification)
                }
            }
        )
        let tls = try tlsFactory(tlsParameters)
        return NegotiatorV3(
            ctx,
            looper: looper,
            linkMetadata: linkMetadata,
            channel: controlChannel,
            prng: prng,
            tls: tls,
            dpFactory: dpFactory,
            options: negOptions
        )
    }

    func addNegotiator(_ negotiator: NegotiatorV3) {
        withActiveContext { context in
            pp_log(ctx, .openvpn, .info, "Replace negotiator with key \(negotiator.key)")
            context.negotiators[negotiator.key] = negotiator
            pp_log(ctx, .openvpn, .info, "Negotiators: \(context.negotiators.keys)")
            context.currentNegotiatorKey = negotiator.key
        }
    }

    func didNegotiate(
        key: UInt8,
        dataChannel: DataChannel,
        pushReply: PushReply
    ) {
        let didStart = withActiveContext { phase, context -> (LinkMetadata, OpenVPN.Configuration)? in
            pp_log(ctx, .openvpn, .info, "Negotiation succeeded, set key \(key) as current")

            context.pushReply = pushReply

            // Replace current channel with new
            pp_log(ctx, .openvpn, .info, "Replace key \(dataChannel.key) with new data channel")
            context.setDataChannel(dataChannel, forKey: key)

            // Clean up old keys
            while context.oldKeys.count > 1 {
                let keyToRemove = context.oldKeys.removeFirst()
                pp_log(ctx, .openvpn, .info, "Remove key \(keyToRemove) from negotiators and data channels")
                context.negotiators.removeValue(forKey: keyToRemove)
                context.dataChannels.removeValue(forKey: keyToRemove)
            }
            pp_log(ctx, .openvpn, .info, "Negotiators: \(context.negotiators.keys)")
            pp_log(ctx, .openvpn, .info, "Data channels: \(context.dataChannels.keys)")

            // Renegotiation stops here
            guard phase != .started else {
                return nil
            }

            phase = .started
            scheduleNextPing(in: &context)
            return (context.linkMetadata, pushReply.options)
        } ?? nil
        guard let (linkMetadata, pushReplyOptions) = didStart else {
            return
        }
        delegate?.sessionDidStart(
            self,
            remoteAddress: linkMetadata.remoteAddress,
            remoteProtocol: linkMetadata.remoteProtocol,
            remoteOptions: pushReplyOptions,
            remoteFd: linkMetadata.fileDescriptor
        )
    }

    func hasDataChannel(for key: UInt8) -> Bool {
        activeContext?.dataChannels[key] != nil
    }

    func dataChannel(for key: UInt8) -> DataChannel? {
        activeContext?.dataChannels[key]
    }

    func reportLastReceivedDate() {
        withActiveContext { context in
            context.lastReceivedDate = Date()
        }
    }

    func reportInboundDataCount(_ count: Int) {
        withActiveContext { context in
            context.dataCount.inbound += count
            delegateCurrentDataCount(in: &context)
        }
    }

    func reportOutboundDataCount(_ count: Int) {
        withActiveContext { context in
            context.dataCount.outbound += count
            delegateCurrentDataCount(in: &context)
        }
    }

    func checkPingTimeout() throws {
        if let lastReceivedDate = activeContext?.lastReceivedDate {
            guard -lastReceivedDate.timeIntervalSinceNow <= keepAliveTimeout else {
                throw OpenVPNSessionError.pingTimeout
            }
        }
    }
}

// MARK: - Helpers

private extension OpenVPNSessionV3 {
    func scheduleNextPing() {
        withActiveContext { context in
            scheduleNextPing(in: &context)
        }
    }

    func scheduleNextPing(in context: inout ActiveContext) {
        let interval = keepAliveInterval(in: context) ?? options.pingTimeoutCheckInterval
        pp_log(ctx, .openvpn, .debug, "Schedule ping check after \(interval.asTimeString)")

        context.pendingPingTask?.cancel()
        context.pendingPingTask = Task { [weak self] in
            do {
                try await Task.sleep(interval: interval)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                try await looper.perform {
                    try self.ping()
                }
            } catch {
                await self?.shutdown(error)
            }
        }
    }

    func ping() throws {
        guard !isStopped else {
            pp_log(ctx, .openvpn, .debug, "Ping cancelled, session stopped")
            return
        }
        guard let currentDataPair else {
            pp_log(ctx, .openvpn, .debug, "Ping cancelled, no data link")
            return
        }
        pp_log(ctx, .openvpn, .debug, "Run ping check")
        try checkPingTimeout()

        // Is keep-alive enabled?
        if keepAliveInterval != nil {
            pp_log(ctx, .openvpn, .debug, "Send ping")
            try currentDataPair.send([Constants.DataChannel.pingString])
        }

        // Schedule even just to check for ping timeout
        scheduleNextPing()
    }

    var keepAliveInterval: TimeInterval? {
        keepAliveInterval(in: activeContext)
    }

    func keepAliveInterval(in context: ActiveContext?) -> TimeInterval? {
        let interval: TimeInterval?
        if let negInterval = context?.pushReply?.options.keepAliveInterval, negInterval > 0.0 {
            interval = negInterval
        } else if let cfgInterval = configuration.keepAliveInterval, cfgInterval > 0.0 {
            interval = cfgInterval
        } else {
            return nil
        }
        return interval
    }

    var keepAliveTimeout: TimeInterval {
        if let negTimeout = activeContext?.pushReply?.options.keepAliveTimeout, negTimeout > 0.0 {
            return negTimeout
        } else if let cfgTimeout = configuration.keepAliveTimeout, cfgTimeout > 0.0 {
            return cfgTimeout
        } else {
            return options.pingTimeout
        }
    }

    func delegateCurrentDataCount(in context: inout ActiveContext) {
        if let lastDataCountDate = context.lastDataCountDate {
            guard -lastDataCountDate.timeIntervalSinceNow >= options.minDataCountInterval else {
                return
            }
        }
        context.lastDataCountDate = Date()
        let currentDataCount = DataCount(UInt64(context.dataCount.inbound), UInt64(context.dataCount.outbound))
        delegate?.session(self, didUpdateDataCount: currentDataCount)
    }
}

private extension OpenVPNSessionV3 {
    static func newControlChannel(
        _ ctx: PartoutLoggerContext,
        with prng: PRNGProtocol,
        configuration: OpenVPN.Configuration
    ) throws -> ControlChannelV3 {
        let channel: ControlChannelV3
        if let tlsWrap = configuration.tlsWrap {
            switch tlsWrap.strategy {
            case .auth:
                channel = try ControlChannelV3(
                    ctx,
                    prng: prng,
                    authKey: tlsWrap.key,
                    digest: configuration.fallbackDigest
                )

            case .crypt:
                channel = try ControlChannelV3(
                    ctx,
                    prng: prng,
                    cryptKey: tlsWrap.key
                )

            case .cryptV2:
                guard let wrappedKey = tlsWrap.wrappedKey else {
                    throw OpenVPNSessionError.assertion
                }
                channel = try ControlChannelV3(
                    ctx,
                    prng: prng,
                    cryptV2Key: tlsWrap.key,
                    wrappedKey: wrappedKey
                )

            @unknown default:
                channel = ControlChannelV3(ctx, prng: prng)
            }
        } else {
            channel = ControlChannelV3(ctx, prng: prng)
        }
        return channel
    }
}
