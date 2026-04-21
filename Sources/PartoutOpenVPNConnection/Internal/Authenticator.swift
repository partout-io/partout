// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

fileprivate extension CrossZD {
    func appendSized(_ buf: CrossZD) {
        append(CZ(UInt16(buf.count).bigEndian))
        append(buf)
    }
}

final class Authenticator {
    private let ctx: PartoutLoggerContext

    private var controlBuffer: CrossZD

    private(set) var preMaster: CrossZD

    private(set) var random1: CrossZD

    private(set) var random2: CrossZD

    private(set) var serverRandom1: CrossZD?

    private(set) var serverRandom2: CrossZD?

    private(set) var serverOptions: ServerOCC?

    private(set) var username: CrossZD?

    private(set) var password: CrossZD?

    var withLocalOptions: Bool

    var sslVersion: String?

    init(_ ctx: PartoutLoggerContext, prng: PRNGProtocol, _ username: String?, _ password: String?) {
        self.ctx = ctx
        preMaster = prng.safeCrossData(length: Constants.Keys.preMasterLength)
        random1 = prng.safeCrossData(length: Constants.Keys.randomLength)
        random2 = prng.safeCrossData(length: Constants.Keys.randomLength)

        // XXX: Not 100% secure, can't erase input username/password
        if let username = username, let password = password {
            self.username = CZ(username, nullTerminated: true)
            self.password = CZ(password, nullTerminated: true)
        } else {
            self.username = nil
            self.password = nil
        }

        withLocalOptions = true

        controlBuffer = CZ()
    }

    func reset() {
        controlBuffer.zero()
        preMaster.zero()
        random1.zero()
        random2.zero()
        serverRandom1?.zero()
        serverRandom2?.zero()
        serverOptions = nil
        username = nil
        password = nil
    }

    // MARK: Authentication request

    func putAuth(into tls: TLSProtocol, options: OpenVPN.Configuration) throws {
        let raw = CZ(Constants.ControlChannel.tlsPrefix)

        // Local keys
        raw.append(preMaster)
        raw.append(random1)
        raw.append(random2)

        // Local options string
        let optsString = options.asLocalOptionsString(withLocalOptions: withLocalOptions)
        pp_log(ctx, .openvpn, .info, "TLS.auth: Local options: \(optsString)")
        raw.appendSized(CZ(optsString, nullTerminated: true))

        // Credentials
        if let username = username, let password = password {
            raw.appendSized(username)
            raw.appendSized(password)
        } else {
            raw.append(CZ(UInt16(0)))
            raw.append(CZ(UInt16(0)))
        }

        // Peer info
        var extra: [String: String] = [:]
        if let dataCiphers = options.negotiableDataCiphers {
            extra["IV_CIPHERS"] = dataCiphers.map(\.rawValue).joined(separator: ":")
        }
        let peerInfo = Constants.ControlChannel.peerInfo(sslVersion: sslVersion, extra: extra)
        raw.appendSized(CZ(peerInfo, nullTerminated: true))

        pp_log(ctx, .openvpn, .info, "TLS.auth: Put plaintext \(raw.asSensitiveBytes(ctx))")

        try tls.putRawPlainText(raw.toData())
    }

    // MARK: Server replies

    func appendControlData(_ data: CrossZD) {
        controlBuffer.append(data)
    }

    func parseAuthReply() throws -> Bool {
        let prefixLength = Constants.ControlChannel.tlsPrefix.count

        // TLS prefix + random (x2) + opts length [+ opts]
        guard controlBuffer.count >= prefixLength + 2 * Constants.Keys.randomLength + 2 else {
            return false
        }

        let prefix = controlBuffer.withOffset(0, count: prefixLength)
        guard prefix.isEqual(to: Constants.ControlChannel.tlsPrefix) else {
            throw OpenVPNSessionError.wrongControlDataPrefix
        }

        var offset = Constants.ControlChannel.tlsPrefix.count

        let serverRandom1 = controlBuffer.withOffset(offset, count: Constants.Keys.randomLength)
        offset += Constants.Keys.randomLength

        let serverRandom2 = controlBuffer.withOffset(offset, count: Constants.Keys.randomLength)
        offset += Constants.Keys.randomLength

        let serverOptsLength = Int(controlBuffer.networkUInt16Value(fromOffset: offset))
        offset += 2

        guard controlBuffer.count >= offset + serverOptsLength else {
            return false
        }
        let serverOpts = controlBuffer.withOffset(offset, count: serverOptsLength)
        offset += serverOptsLength

        pp_log(ctx, .openvpn, .info, "TLS.auth: Parsed server random [\(serverRandom1.asSensitiveBytes(ctx)), \(serverRandom2.asSensitiveBytes(ctx))]")

        if let serverOptsString = serverOpts.nullTerminatedString(fromOffset: 0) {
            pp_log(ctx, .openvpn, .info, "TLS.auth: Parsed server options (string): \"\(serverOptsString)\"")
            let serverOptions = ServerOCC.parsed(from: serverOptsString)
            pp_log(ctx, .openvpn, .info, "TLS.auth: Server options: \(serverOptions)")
            self.serverOptions = serverOptions
        }

        self.serverRandom1 = serverRandom1
        self.serverRandom2 = serverRandom2
        controlBuffer.remove(untilOffset: offset)

        return true
    }

    func parseMessages() -> [String] {
        var messages = [String]()
        var offset = 0

        while true {
            guard let msg = controlBuffer.nullTerminatedString(fromOffset: offset) else {
                break
            }
            messages.append(msg)
            offset += msg.count + 1
        }

        controlBuffer.remove(untilOffset: offset)

        return messages
    }

    // MARK: Response

    var response: Handshake? {
        guard let serverRandom1, let serverRandom2 else {
            return nil
        }
        return Handshake(
            preMaster: preMaster,
            random1: random1,
            random2: random2,
            serverRandom1: serverRandom1,
            serverRandom2: serverRandom2
        )
    }
}

extension OpenVPN.Configuration {
    /// Builds the legacy OCC/auth-options string sent during TLS auth.
    ///
    /// Keep `cipher` in this string only when the configuration explicitly
    /// carries a legacy/fallback cipher. Negotiated `data-ciphers` are
    /// advertised separately via `IV_CIPHERS`.
    func asLocalOptionsString(
        withLocalOptions: Bool
    ) -> String {
        guard withLocalOptions else {
            return "V0 UNDEF"
        }
        var opts = [
            "V4",
            "dev-type tun"
        ]
        if let direction = tlsWrap?.key.direction?.rawValue {
            opts.append("keydir \(direction)")
        }
        if let cipher {
            opts.append("cipher \(cipher.rawValue)")
            opts.append("keysize \(cipher.keySize)")
        }
        opts.append("auth \(fallbackDigest.rawValue)")
        if let strategy = tlsWrap?.strategy {
            opts.append("tls-\(strategy.rawValue)")
        }
        opts.append("key-method 2")
        opts.append("tls-client")
        return opts.joined(separator: ",")
    }
}
