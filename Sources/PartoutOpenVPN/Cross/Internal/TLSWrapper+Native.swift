// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutOpenVPN_C
internal import _PartoutTLS_C
#if !PARTOUT_MONOLITH
import PartoutCore
import PartoutOS
#endif

extension TLSWrapper {
    static func native(with parameters: Parameters) throws -> TLSWrapper {
        try TLSWrapper(tls: NativeTLSWrapper(parameters: parameters))
    }
}

private final class NativeTLSWrapper: TLSProtocol {
    enum Constants {
        static let caFilename = "ca.pem"

        static let defaultSecurityLevel = 0

        static let bufferLength = 16 * 1024
    }

    private let tls: pp_tls

    private let caURL: URL

    private let didFailVerification: PassthroughStream<UniqueID, Void>

    private var verificationObserver: Task<Void, Never>?

    init(parameters: TLSWrapper.Parameters) throws {
        guard let ca = parameters.cfg.ca else {
            throw PPTLSError.missingCA
        }
        caURL = parameters.cachesURL.miniAppending(component: Constants.caFilename)
        let caURLFilePath = caURL.filePath()
        try ca.pem.write(toFile: caURLFilePath, encoding: .ascii)

        let securityLevel = parameters.cfg.tlsSecurityLevel
        let checksEKU = parameters.cfg.checksEKU ?? false
        let checksSANHost = parameters.cfg.checksSANHost ?? false
        let caPath = caURLFilePath.withCString(pp_dup)
        let certPEM = parameters.cfg.clientCertificate?.pem.withCString(pp_dup)
        let keyPEM = parameters.cfg.clientKey?.pem.withCString(pp_dup)
        let hostname = parameters.cfg.sanHost?.withCString(pp_dup)
        defer {
            pp_free(caPath)
            pp_free(certPEM)
            pp_free(keyPEM)
            pp_free(hostname)
        }

        let didFailVerification = PassthroughStream<UniqueID, Void>()
        let options = pp_tls_options_create(
            Int32(securityLevel ?? Constants.defaultSecurityLevel),
            Constants.bufferLength,
            checksEKU,
            checksSANHost,
            caPath,
            certPEM,
            keyPEM,
            hostname,
            Unmanaged.passUnretained(didFailVerification).toOpaque(),
            { ctx in
                guard let ctx else { return }
                let stream = Unmanaged<PassthroughStream<UniqueID, Void>>
                    .fromOpaque(ctx)
                    .takeUnretainedValue()
                stream.send()
            }
        )
        var error = PPTLSErrorNone
        guard let tls = pp_tls_create(options, &error) else {
            pp_tls_options_free(options)
            try? FileManager.default.miniRemoveItem(at: self.caURL)

            throw CTLSError(error)
        }
        self.tls = tls

        self.didFailVerification = didFailVerification
        verificationObserver = Task { [weak didFailVerification] in
            guard let didFailVerification else { return }
            for await _ in didFailVerification.subscribe() {
                parameters.onVerificationFailure()
            }
        }
    }

    deinit {
        pp_tls_free(tls)
        try? FileManager.default.miniRemoveItem(at: caURL)
    }

    func start() throws {
        guard pp_tls_start(tls) else {
            throw PPTLSError.start
        }
    }

    func isConnected() -> Bool {
        pp_tls_is_connected(tls)
    }

    func putPlainText(_ text: String) throws {
        try text.withCString { buf in
            var error = PPTLSErrorNone
            guard pp_tls_put_plain(tls, buf, text.count, &error) else {
                throw CTLSError(error)
            }
        }
    }

    func putRawPlainText(_ text: Data) throws {
        try text.withUnsafeBytes { buf in
            var error = PPTLSErrorNone
            guard pp_tls_put_plain(tls, buf.bytePointer, text.count, &error) else {
                throw CTLSError(error)
            }
        }
    }

    func putCipherText(_ data: Data) throws {
        try data.withUnsafeBytes { buf in
            var error = PPTLSErrorNone
            guard pp_tls_put_cipher(tls, buf.bytePointer, data.count, &error) else {
                throw CTLSError(error)
            }
        }
    }

    func pullPlainText() throws -> Data {
        var error = PPTLSErrorNone
        guard let zd = pp_tls_pull_plain(tls, &error) else {
            guard error == PPTLSErrorNone else {
                throw CTLSError(error)
            }
            throw PPTLSError.noData
        }
        return Data.zeroing(zd)
    }

    func pullCipherText() throws -> Data {
        var error = PPTLSErrorNone
        guard let zd = pp_tls_pull_cipher(tls, &error) else {
            guard error == PPTLSErrorNone else {
                throw CTLSError(error)
            }
            throw PPTLSError.noData
        }
        return Data.zeroing(zd)
    }

    func caMD5() throws -> String {
        guard let buf = pp_tls_ca_md5(tls) else {
            throw PPTLSError.encryption
        }
        defer {
            pp_free(buf)
        }
        guard let md5 = String(cString: buf, encoding: .ascii) else {
            throw PPTLSError.encryption
        }
        return md5
    }
}
