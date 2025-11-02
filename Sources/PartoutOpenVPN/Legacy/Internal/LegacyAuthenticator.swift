// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import PartoutOpenVPN_ObjC
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

fileprivate extension LegacyZD {
    func appendSized(_ buf: LegacyZD) {
        append(Z(UInt16(buf.length).bigEndian))
        append(buf)
    }
}

final class LegacyAuthenticator {
    private let ctx: PartoutLoggerContext

    private var controlBuffer: LegacyZD

    private(set) var preMaster: LegacyZD

    private(set) var random1: LegacyZD

    private(set) var random2: LegacyZD

    private(set) var serverRandom1: LegacyZD?

    private(set) var serverRandom2: LegacyZD?

    private(set) var username: LegacyZD?

    private(set) var password: LegacyZD?

    var withLocalOptions: Bool

    var sslVersion: String?

    init(_ ctx: PartoutLoggerContext, prng: PRNGProtocol, _ username: String?, _ password: String?) {
        self.ctx = ctx
        preMaster = prng.safeLegacyData(length: Constants.Keys.preMasterLength)
        random1 = prng.safeLegacyData(length: Constants.Keys.randomLength)
        random2 = prng.safeLegacyData(length: Constants.Keys.randomLength)

        // XXX: not 100% secure, can't erase input username/password
        if let username = username, let password = password {
            self.username = Z(username, nullTerminated: true)
            self.password = Z(password, nullTerminated: true)
        } else {
            self.username = nil
            self.password = nil
        }

        withLocalOptions = true

        controlBuffer = Z()
    }

    func reset() {
        controlBuffer.zero()
        preMaster.zero()
        random1.zero()
        random2.zero()
        serverRandom1?.zero()
        serverRandom2?.zero()
        username = nil
        password = nil
    }

    // MARK: Authentication request

    func putAuth(into tls: OpenVPNTLSProtocol, options: OpenVPN.Configuration) throws {
        let raw = Z(Constants.ControlChannel.tlsPrefix)

        // local keys
        raw.append(preMaster)
        raw.append(random1)
        raw.append(random2)

        // options string
        let optsString: String
        if withLocalOptions {
            var opts = [
                "V4",
                "dev-type tun"
            ]
#if OPENVPN_DEPRECATED_LZO
            opts.append("comp-lzo")
#endif
            if let direction = options.tlsWrap?.key.direction?.rawValue {
                opts.append("keydir \(direction)")
            }
            opts.append("cipher \(options.fallbackCipher.rawValue)")
            opts.append("auth \(options.fallbackDigest.rawValue)")
            opts.append("keysize \(options.fallbackCipher.keySize)")
            if let strategy = options.tlsWrap?.strategy {
                opts.append("tls-\(strategy)")
            }
            opts.append("key-method 2")
            opts.append("tls-client")
            optsString = opts.joined(separator: ",")
        } else {
            optsString = "V0 UNDEF"
        }
        pp_log(ctx, .openvpn, .info, "TLS.auth: Local options: \(optsString)")
        raw.appendSized(Z(optsString, nullTerminated: true))

        // credentials
        if let username = username, let password = password {
            raw.appendSized(username)
            raw.appendSized(password)
        } else {
            raw.append(Z(UInt16(0)))
            raw.append(Z(UInt16(0)))
        }

        // peer info
        var extra: [String: String] = [:]
        if let dataCiphers = options.dataCiphers {
            extra["IV_CIPHERS"] = dataCiphers.map(\.rawValue).joined(separator: ":")
        }
        let peerInfo = Constants.ControlChannel.peerInfo(sslVersion: sslVersion, extra: extra)
        raw.appendSized(Z(peerInfo, nullTerminated: true))

        pp_log(ctx, .openvpn, .info, "TLS.auth: Put plaintext \(raw.asSensitiveBytes(ctx))")

        try tls.putRawPlainText(raw.bytes, length: raw.length)
    }

    // MARK: Server replies

    func appendControlData(_ data: LegacyZD) {
        controlBuffer.append(data)
    }

    func parseAuthReply() throws -> Bool {
        let prefixLength = Constants.ControlChannel.tlsPrefix.count

        // TLS prefix + random (x2) + opts length [+ opts]
        guard controlBuffer.length >= prefixLength + 2 * Constants.Keys.randomLength + 2 else {
            return false
        }

        let prefix = controlBuffer.withOffset(0, length: prefixLength)
        guard prefix.isEqual(to: Constants.ControlChannel.tlsPrefix) else {
            throw OpenVPNSessionError.wrongControlDataPrefix
        }

        var offset = Constants.ControlChannel.tlsPrefix.count

        let serverRandom1 = controlBuffer.withOffset(offset, length: Constants.Keys.randomLength)
        offset += Constants.Keys.randomLength

        let serverRandom2 = controlBuffer.withOffset(offset, length: Constants.Keys.randomLength)
        offset += Constants.Keys.randomLength

        let serverOptsLength = Int(controlBuffer.networkUInt16Value(fromOffset: offset))
        offset += 2

        guard controlBuffer.length >= offset + serverOptsLength else {
            return false
        }
        let serverOpts = controlBuffer.withOffset(offset, length: serverOptsLength)
        offset += serverOptsLength

        pp_log(ctx, .openvpn, .info, "TLS.auth: Parsed server random [\(serverRandom1.asSensitiveBytes(ctx)), \(serverRandom2.asSensitiveBytes(ctx))]")

        if let serverOptsString = serverOpts.nullTerminatedString(fromOffset: 0) {
            pp_log(ctx, .openvpn, .info, "TLS.auth: Parsed server options: \"\(serverOptsString)\"")
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

    var response: LegacyHandshake? {
        guard let serverRandom1, let serverRandom2 else {
            return nil
        }
        return LegacyHandshake(
            preMaster: preMaster,
            random1: random1,
            random2: random2,
            serverRandom1: serverRandom1,
            serverRandom2: serverRandom2
        )
    }
}
