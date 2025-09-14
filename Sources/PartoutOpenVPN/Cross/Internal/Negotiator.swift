// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
#if !PARTOUT_MONOLITH
internal import PartoutOS
import PartoutCore
import PartoutOpenVPN
#endif

@OpenVPNActor
final class Negotiator {
    struct Options {
        let configuration: OpenVPN.Configuration

        let credentials: OpenVPN.Credentials?

        let withLocalOptions: Bool

        let sessionOptions: OpenVPN.ConnectionOptions

        let onConnected: (UInt8, DataChannel, PushReply) async -> Void

        let onError: (UInt8, Error) async -> Void
    }

    private let ctx: PartoutLoggerContext

    private let parser = StandardOpenVPNParser(supportsLZO: false, decrypter: nil)

    let key: UInt8 // 3-bit

    private(set) var history: NegotiationHistory?

    private let renegotiation: RenegotiationType?

    let link: LinkInterface

    private var channel: ControlChannel

    private let prng: PRNGProtocol

    private let tls: TLSProtocol

    private let dpFactory: DataPathFactory

    private let options: Options

    // MARK: State

    private let startTime: Date

    private let negotiationTimeout: TimeInterval

    private var state: State {
        didSet {
            pp_log(ctx, .openvpn, .info, "Negotiator: \(key) -> \(state)")
        }
    }

    private var expectedPacketId: UInt32

    private var pendingPackets: [UInt32: CControlPacket]

    private var authenticator: Authenticator?

    private var nextPushRequestDate: Date?

    private var continuatedPushReplyMessage: String?

    private var checkNegotiationTask: Task<Void, Never>?

    // MARK: Init

    convenience init(
        _ ctx: PartoutLoggerContext,
        link: LinkInterface,
        channel: ControlChannel,
        prng: PRNGProtocol,
        tls: TLSProtocol,
        dpFactory: @escaping DataPathFactory,
        options: Options
    ) {
        self.init(
            ctx,
            key: 0,
            history: nil,
            renegotiation: nil,
            link: link,
            channel: channel,
            prng: prng,
            tls: tls,
            dpFactory: dpFactory,
            options: options
        )
    }

    private init(
        _ ctx: PartoutLoggerContext,
        key: UInt8,
        history: NegotiationHistory?,
        renegotiation: RenegotiationType?,
        link: LinkInterface,
        channel: ControlChannel, // TODO: #29, abstract this for testing
        prng: PRNGProtocol,
        tls: TLSProtocol,
        dpFactory: @escaping DataPathFactory,
        options: Options
    ) {
        self.ctx = ctx
        self.key = key
        self.history = history
        self.renegotiation = renegotiation
        self.link = link
        self.channel = channel
        self.prng = prng
        self.tls = tls
        self.dpFactory = dpFactory
        self.options = options

        startTime = Date()
        negotiationTimeout = renegotiation != nil ? options.sessionOptions.softNegotiationTimeout : options.sessionOptions.negotiationTimeout
        state = .idle
        expectedPacketId = 0
        pendingPackets = [:]
    }

    func forRenegotiation(initiatedBy newRenegotiation: RenegotiationType) -> Negotiator {
        guard let history else {
            pp_log(ctx, .openvpn, .error, "Negotiator has no history (not connected yet?)")
            return self
        }
        let newKey = Constants.ControlChannel.nextKey(after: key)
        return Negotiator(
            ctx,
            key: newKey,
            history: history,
            renegotiation: newRenegotiation,
            link: link,
            channel: channel,
            prng: prng,
            tls: tls,
            dpFactory: dpFactory,
            options: options
        )
    }
}

// MARK: - Public API

extension Negotiator {
    var isConnected: Bool {
        state == .connected
    }

    var isRenegotiating: Bool {
        renegotiation != nil && state != .connected
    }

    func start() throws {
        channel.reset(forNewSession: renegotiation == nil)

        // schedule this repeatedly
        try checkNegotiationComplete()

        switch renegotiation {
        case .client:
            try enqueueControlPackets(code: .softResetV1, key: key, payload: Data())

        case .server:
            break

        default:
            try enqueueControlPackets(code: .hardResetClientV2, key: key, payload: hardResetPayload() ?? Data())
        }
    }

    func cancel() {
        checkNegotiationTask?.cancel()
    }

    func readInboundPacket(withData packet: Data, offset: Int) throws -> CControlPacket {
        try channel.readInboundPacket(withData: packet, offset: 0)
    }

    func enqueueInboundPacket(packet controlPacket: CControlPacket) -> [CControlPacket] {
        channel.enqueueInboundPacket(packet: controlPacket)
    }

    func handleControlPacket(_ packet: CControlPacket) throws {
        guard packet.packetId >= expectedPacketId else {
            return
        }
        if packet.packetId > expectedPacketId {
            pendingPackets[packet.packetId] = packet
            return
        }

        try privateHandleControlPacket(packet)
        expectedPacketId += 1

        while let packet = pendingPackets[expectedPacketId] {
            try privateHandleControlPacket(packet)
            pendingPackets.removeValue(forKey: packet.packetId)
            expectedPacketId += 1
        }
    }

    func handleAcks() {
        //
    }

    func sendAck(for controlPacket: CControlPacket, to link: LinkInterface) {
        Task {
            try await privateSendAck(for: controlPacket, to: link)
        }
    }

    func shouldRenegotiate() -> Bool {
        guard state == .connected else {
            return false
        }
        guard let renegotiatesAfter = options.configuration.renegotiatesAfter, renegotiatesAfter > 0 else {
            return false
        }
        return elapsedSinceStart >= renegotiatesAfter
    }
}

// MARK: - Outbound

private extension Negotiator {
    func hardResetPayload() -> Data? {
        if options.configuration.usesPIAPatches ?? false {
            do {
                let caMD5 = try tls.caMD5()
                pp_log(ctx, .openvpn, .info, "PIA CA MD5 is: \(caMD5)")
                return try? PIAHardReset(
                    ctx,
                    caMd5Digest: caMD5,
                    cipher: options.configuration.fallbackCipher,
                    digest: options.configuration.fallbackDigest
                ).encodedData(prng: prng)
            } catch {
                pp_log(ctx, .openvpn, .error, "PIA CA MD5 could not be computed, skip custom HARD_RESET")
                return nil
            }
        }
        return nil
    }

    func checkNegotiationComplete() throws {
        guard !didHardResetTimeout else {
            throw OpenVPNSessionError.recoverable(OpenVPNSessionError.negotiationTimeout)
        }
        guard !didNegotiationTimeout else {
            throw OpenVPNSessionError.negotiationTimeout
        }

        if !isRenegotiating {
            try pushRequest()
        }
        if !link.isReliable {
            try flushControlQueue()
        }

        guard state == .connected else {
            checkNegotiationTask?.cancel()
            checkNegotiationTask = Task { [weak self] in
                guard let self else {
                    return
                }
                try? await Task.sleep(milliseconds: Int(options.sessionOptions.tickInterval * 1000))
                guard !Task.isCancelled else {
                    return
                }
                do {
                    try checkNegotiationComplete()
                } catch {
                    await options.onError(key, error)
                }
            }
            return
        }

        // let loop die when negotiation is complete
    }

    func pushRequest() throws {
        guard state == .push else {
            return
        }
        guard let nextPushRequestDate, Date() > nextPushRequestDate else {
            return
        }

        pp_log(ctx, .openvpn, .info, "TLS.ifconfig: Put plaintext (PUSH_REQUEST)")
        try? tls.putPlainText("PUSH_REQUEST\0")

        let cipherTextOut: Data
        do {
            cipherTextOut = try tls.pullCipherText()
        } catch let cError as CTLSError {
            pp_log(ctx, .openvpn, .fault, "TLS.auth: Failed pulling ciphertext: \(cError.code)")
            throw cError
        } catch {
            pp_log(ctx, .openvpn, .debug, "TLS.ifconfig: Still can't pull ciphertext")
            return
        }

        pp_log(ctx, .openvpn, .info, "TLS.ifconfig: Send pulled ciphertext \(cipherTextOut.asSensitiveBytes(ctx))")
        try enqueueControlPackets(code: .controlV1, key: key, payload: cipherTextOut)

        self.nextPushRequestDate = Date().addingTimeInterval(options.sessionOptions.pushRequestInterval)
    }

    func enqueueControlPackets(code: CPacketCode, key: UInt8, payload: Data) throws {
        try channel.enqueueOutboundPackets(
            withCode: code,
            key: key,
            payload: payload,
            maxPacketSize: Constants.ControlChannel.maxPacketSize
        )
        try flushControlQueue()
    }

    func flushControlQueue() throws {
        let rawList: [Data]
        do {
            rawList = try channel.writeOutboundPackets(resendAfter: options.sessionOptions.retxInterval)
        } catch {
            pp_log(ctx, .openvpn, .error, "Failed control packet serialization: \(error)")
            throw error
        }
        guard !rawList.isEmpty else {
            return
        }
        for raw in rawList {
            pp_log(ctx, .openvpn, .info, "Send control packet \(raw.asSensitiveBytes(ctx))")
        }
        Task {
            do {
                try await link.writePackets(rawList)
            } catch {
                pp_log(ctx, .openvpn, .error, "Failed LINK write during control flush: \(error)")
                await options.onError(key, PartoutError(.linkFailure, error))
            }
        }
    }
}

// MARK: - Inbound

private extension Negotiator {
    func privateHandleControlPacket(_ packet: CControlPacket) throws {
        guard packet.key == key else {
            pp_log(ctx, .openvpn, .error, "Bad key in control packet (\(packet.key) != \(key))")
            return
        }

        switch state {
        case .idle:
            guard packet.code == .hardResetServerV2 || packet.code == .softResetV1 else {
                break
            }
            if packet.code == .hardResetServerV2 {
                if isRenegotiating {
                    pp_log(ctx, .openvpn, .error, "Sent SOFT_RESET but received HARD_RESET?")
                }
                channel.setRemoteSessionId(packet.sessionId)
            }
            guard let remoteSessionId = channel.remoteSessionId else {
                let error = OpenVPNSessionError.missingSessionId
                pp_log(ctx, .openvpn, .fault, "No remote sessionId (never set): \(error)")
                throw error
            }
            guard packet.sessionId == remoteSessionId else {
                let error = OpenVPNSessionError.sessionMismatch
                pp_log(ctx, .openvpn, .fault, "Packet session mismatch (\(packet.sessionId.toHex()) != \(remoteSessionId.toHex())): \(error)")
                throw error
            }

            pp_log(ctx, .openvpn, .info, "Start TLS handshake")
            state = .tls
            try tls.start()

            let cipherTextOut: Data
            do {
                cipherTextOut = try tls.pullCipherText()
            } catch let cError as CTLSError {
                pp_log(ctx, .openvpn, .fault, "TLS.connect: Failed pulling ciphertext: \(cError.code)")
                throw cError
            }

            pp_log(ctx, .openvpn, .info, "TLS.connect: Pulled ciphertext \(cipherTextOut.asSensitiveBytes(ctx))")
            try enqueueControlPackets(code: .controlV1, key: key, payload: cipherTextOut)

        case .tls, .auth, .push, .connected:
            guard packet.code == .controlV1 else {
                return
            }
            guard let remoteSessionId = channel.remoteSessionId else {
                let error = OpenVPNSessionError.missingSessionId
                pp_log(ctx, .openvpn, .fault, "No remote sessionId found in packet (control packets before server HARD_RESET): \(error)")
                throw error
            }
            guard packet.sessionId == remoteSessionId else {
                let error = OpenVPNSessionError.sessionMismatch
                pp_log(ctx, .openvpn, .fault, "Packet session mismatch (\(packet.sessionId.toHex()) != \(remoteSessionId.toHex())): \(error)")
                throw error
            }
            guard let cipherTextIn = packet.payload else {
                pp_log(ctx, .openvpn, .error, "TLS.connect: Control packet with empty payload?")
                return
            }

            pp_log(ctx, .openvpn, .info, "TLS.connect: Put received ciphertext [\(packet.packetId)] \(cipherTextIn.asSensitiveBytes(ctx))")
            try? tls.putCipherText(cipherTextIn)

            let cipherTextOut: Data
            do {
                cipherTextOut = try tls.pullCipherText()
                pp_log(ctx, .openvpn, .info, "TLS.connect: Send pulled ciphertext \(cipherTextOut.asSensitiveBytes(ctx))")
                try enqueueControlPackets(code: .controlV1, key: key, payload: cipherTextOut)
            } catch let cError as CTLSError {
                pp_log(ctx, .openvpn, .fault, "TLS.connect: Failed pulling ciphertext: \(cError.code)")
                throw cError
            } catch {
                pp_log(ctx, .openvpn, .debug, "TLS.connect: No available ciphertext to pull")
            }

            if state < .auth, tls.isConnected() {
                pp_log(ctx, .openvpn, .info, "TLS.connect: Handshake is complete")
                state = .auth

                try onTLSConnect()
            }
            do {
                while true {
                    let controlData = try channel.currentControlData(withTLS: tls)
                    try handleControlData(controlData)
                }
            } catch {
            }
        }
    }

    func privateSendAck(for controlPacket: CControlPacket, to link: LinkInterface) async throws {
        do {
            pp_log(ctx, .openvpn, .info, "Send ack for received packetId \(controlPacket.packetId)")
            let raw = try channel.writeAcks(
                withKey: controlPacket.key,
                ackPacketIds: [controlPacket.packetId],
                ackRemoteSessionId: controlPacket.sessionId
            )
            try await link.writePackets([raw])
            pp_log(ctx, .openvpn, .info, "Ack successfully written to LINK for packetId \(controlPacket.packetId)")
        } catch {
            pp_log(ctx, .openvpn, .error, "Failed LINK write during send ack for packetId \(controlPacket.packetId): \(error)")
            await options.onError(key, PartoutError(.linkFailure, error))
        }
    }

    func onTLSConnect() throws {
        authenticator = Authenticator(
            ctx,
            prng: prng,
            options.credentials?.username,
            history?.pushReply.options.authToken ?? options.credentials?.password
        )
        authenticator?.withLocalOptions = options.withLocalOptions
        try authenticator?.putAuth(into: tls, options: options.configuration)

        let cipherTextOut: Data
        do {
            cipherTextOut = try tls.pullCipherText()
        } catch let cError as CTLSError {
            pp_log(ctx, .openvpn, .fault, "TLS.auth: Failed pulling ciphertext: \(cError.code)")
            throw cError
        } catch {
            pp_log(ctx, .openvpn, .debug, "TLS.auth: Still can't pull ciphertext")
            return
        }

        pp_log(ctx, .openvpn, .info, "TLS.auth: Pulled ciphertext \(cipherTextOut.asSensitiveBytes(ctx))")
        try enqueueControlPackets(code: .controlV1, key: key, payload: cipherTextOut)
    }

    func handleControlData(_ data: CZeroingData) throws {
        guard let authenticator else {
            return
        }

        pp_log(ctx, .openvpn, .info, "Pulled plain control data \(data.asSensitiveBytes(ctx))")
        authenticator.appendControlData(data)

        if state == .auth {
            guard try authenticator.parseAuthReply() else {
                return
            }

            // renegotiation goes straight to .connected
            guard !isRenegotiating else {
                state = .connected
                guard let pushReply = history?.pushReply else {
                    pp_log(ctx, .openvpn, .fault, "Renegotiating connection without former history")
                    throw OpenVPNSessionError.assertion
                }
                try completeConnection(pushReply: pushReply)
                return
            }

            state = .push
            nextPushRequestDate = Date().addingTimeInterval(options.sessionOptions.retxInterval)
        }

        for message in authenticator.parseMessages() {
            pp_log(ctx, .openvpn, .info, "Parsed control message \(message.asSensitiveBytes(ctx))")
            do {
                try handleControlMessage(message)
            } catch {
                Task {
                    await options.onError(key, error)
                }
                throw error
            }
        }
    }

    func handleControlMessage(_ message: String) throws {
        pp_log(ctx, .openvpn, .info, "Received control message \(message.asSensitiveBytes(ctx))")

        // disconnect on authentication failure
        guard !message.hasPrefix("AUTH_FAILED") else {

            // XXX: retry without client options
            if authenticator?.withLocalOptions ?? false {
                pp_log(ctx, .openvpn, .error, "Authentication failure, retry without local options")
                throw OpenVPNSessionError.badCredentialsWithLocalOptions
            }

            throw OpenVPNSessionError.badCredentials
        }

        // disconnect on remote server restart (--explicit-exit-notify)
        guard !message.hasPrefix("RESTART") else {
            pp_log(ctx, .openvpn, .info, "Disconnect due to server shutdown")
            throw OpenVPNSessionError.serverShutdown
        }

        // handle authentication from now on
        guard state == .push else {
            return
        }

        let completeMessage: String
        if let continuatedPushReplyMessage {
            completeMessage = "\(continuatedPushReplyMessage),\(message)"
        } else {
            completeMessage = message
        }
        let reply: PushReply
        do {
            guard let optionalReply = try parser.pushReply(with: completeMessage) else {
                return
            }
            reply = optionalReply
            pp_log(ctx, .openvpn, .info, "Received PUSH_REPLY: \"\(reply)\"")

            if let framing = reply.options.compressionFraming, let compression = reply.options.compressionAlgorithm {
                switch compression {
                case .disabled:
                    break
                default:
                    let error = OpenVPNSessionError.serverCompression
                    pp_log(ctx, .openvpn, .fault, "Server has compression enabled (\(compression)) and this is not supported (framing=\(framing)): \(error)")
                    throw error
                }
            }
        } catch StandardOpenVPNParserError.continuationPushReply {
            continuatedPushReplyMessage = completeMessage.replacingOccurrences(of: "push-continuation", with: "")
            // XXX: strip "PUSH_REPLY" and "push-continuation 2"
            return
        }

        guard reply.options.ipv4 != nil || reply.options.ipv6 != nil else {
            throw OpenVPNSessionError.noRouting
        }
        guard state != .connected else {
            pp_log(ctx, .openvpn, .error, "Ignore multiple calls to complete connection")
            return
        }
        state = .connected
        try completeConnection(pushReply: reply)
    }
}

private extension Negotiator {
    func completeConnection(pushReply: PushReply) throws {
        pp_log(ctx, .openvpn, .info, "Complete connection of key \(key)")
        let history = NegotiationHistory(pushReply: pushReply)
        let dataChannel = try newDataChannel(with: history)
        self.history = history
        authenticator?.reset()
        Task {
            await options.onConnected(key, dataChannel, pushReply)
        }
    }

    func newDataChannel(with history: NegotiationHistory) throws -> DataChannel {
        guard let sessionId = channel.sessionId else {
            pp_log(ctx, .openvpn, .fault, "Setting up connection without a local sessionId")
            throw OpenVPNSessionError.assertion
        }
        guard let remoteSessionId = channel.remoteSessionId else {
            pp_log(ctx, .openvpn, .fault, "Setting up connection without a remote sessionId")
            throw OpenVPNSessionError.assertion
        }
        guard let handshake = authenticator?.response else {
            pp_log(ctx, .openvpn, .fault, "Setting up connection without auth response")
            throw OpenVPNSessionError.assertion
        }

        pp_log(ctx, .openvpn, .notice, "Set up encryption")
//        pp_log(ctx, .openvpn, .info, "\tpreMaster: \(authenticator.preMaster.toHex(), privacy: .private)")
//        pp_log(ctx, .openvpn, .info, "\trandom1: \(authenticator.random1.toHex(), privacy: .private)")
//        pp_log(ctx, .openvpn, .info, "\trandom2: \(authenticator.random2.toHex(), privacy: .private)")
//        pp_log(ctx, .openvpn, .info, "\tserverRandom1: \(serverRandom1.toHex(), privacy: .private)")
//        pp_log(ctx, .openvpn, .info, "\tserverRandom2: \(serverRandom2.toHex(), privacy: .private)")
//        pp_log(ctx, .openvpn, .info, "\tsessionId: \(sessionId.toHex())")
//        pp_log(ctx, .openvpn, .info, "\tremoteSessionId: \(remoteSessionId.toHex())")

        let parameters = DataPathWrapper.Parameters(
            cipher: history.pushReply.options.cipher ?? options.configuration.fallbackCipher,
            digest: options.configuration.fallbackDigest,
            compressionFraming: history.pushReply.options.compressionFraming ?? options.configuration.fallbackCompressionFraming,
            peerId: history.pushReply.options.peerId,
        )
        let prf = CryptoKeys.PRF(
            handshake: handshake,
            sessionId: sessionId,
            remoteSessionId: remoteSessionId
        )
        let dataPath = try dpFactory(parameters, prf, prng)
        return DataChannel(ctx, key: key, dataPath: dataPath)
    }
}

// MARK: - Helpers

private extension Negotiator {
    enum State: Int, Comparable {
        case idle

        case tls

        case auth

        case push

        case connected

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    var elapsedSinceStart: TimeInterval {
        -startTime.timeIntervalSinceNow
    }

    var didHardResetTimeout: Bool {
        state == .idle && elapsedSinceStart > options.sessionOptions.hardResetTimeout
    }

    var didNegotiationTimeout: Bool {
        state != .connected && elapsedSinceStart > negotiationTimeout
    }
}
