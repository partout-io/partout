// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutOpenVPNLegacy_ObjC
import Foundation

extension TLSWrapper {
    static func legacy(with parameters: Parameters) throws -> TLSWrapper {
        try TLSWrapper(tls: LegacyTLSWrapper(parameters: parameters))
    }
}

private final class LegacyTLSWrapper: TLSProtocol {
    private let tlsBox: OSSLTLSBox

    private let caURL: URL

    init(parameters: TLSWrapper.Parameters) throws {
        guard let ca = parameters.cfg.ca else {
            throw PPTLSError.missingCA
        }
        caURL = parameters.cachesURL.appendingPathComponent("ca.pem")
        try ca.pem.write(to: caURL, atomically: true, encoding: .ascii)

        let options = OpenVPNTLSOptions(
            bufferLength: 16 * 1024,
            caURL: caURL,
            clientCertificatePEM: parameters.cfg.clientCertificate?.pem,
            clientKeyPEM: parameters.cfg.clientKey?.pem,
            checksEKU: parameters.cfg.checksEKU ?? false,
            checksSANHost: parameters.cfg.checksSANHost ?? false,
            hostname: parameters.cfg.sanHost,
            securityLevel: parameters.cfg.tlsSecurityLevel ?? 0
        )
        tlsBox = OSSLTLSBox()
        do {
            try tlsBox.configure(with: options) { _ in
                parameters.onVerificationFailure()
            }
        } catch {
            try? FileManager.default.removeItem(at: caURL)
            throw error
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: caURL)
    }

    func start() throws {
        try tlsBox.start()
    }

    func isConnected() -> Bool {
        tlsBox.isConnected()
    }

    func putPlainText(_ text: String) throws {
        try tlsBox.putPlainText(text)
    }

    func putRawPlainText(_ text: Data) throws {
        try text.withUnsafeBytes { cText in
            try tlsBox.putRawPlainText(cText.bytePointer, length: text.count)
        }
    }

    func putCipherText(_ data: Data) throws {
        try tlsBox.putCipherText(data)
    }

    // XXX: unsafe
    func pullPlainText() throws -> Data {
        var dst = Data(count: 16 * 1024)
        var length = 0
        try dst.withUnsafeMutableBytes { cDst in
            try tlsBox.pullRawPlainText(cDst.bytePointer, length: &length)
        }
        return dst.subdata(offset: 0, count: length)
    }

    func pullCipherText() throws -> Data {
        try tlsBox.pullCipherText()
    }

    func caMD5() throws -> String {
        try tlsBox.md5(forCertificatePath: caURL.path)
    }
}
