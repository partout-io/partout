//
//  TLSWrapper+Legacy.swift
//  Partout
//
//  Created by Davide De Rosa on 6/27/25.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//

import Foundation
internal import PartoutOpenVPNLegacy_ObjC

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
            throw TLSError.missingCA
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
