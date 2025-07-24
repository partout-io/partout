//
//  TLSWrapper+Native.swift
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

internal import _PartoutCryptoCore
internal import _PartoutCryptoCore_C
internal import _PartoutOpenVPN_C
import Foundation

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

    private let tls: tls_channel_ctx

    private let caURL: URL

    private let verificationObserver: NSObjectProtocol

    init(parameters: TLSWrapper.Parameters) throws {
        guard let ca = parameters.cfg.ca else {
            throw TLSError.missingCA
        }
        caURL = parameters.cachesURL.appendingPathComponent(Constants.caFilename)
        try ca.pem.write(to: caURL, atomically: true, encoding: .ascii)

        let securityLevel = parameters.cfg.tlsSecurityLevel
        let checksEKU = parameters.cfg.checksEKU ?? false
        let checksSANHost = parameters.cfg.checksSANHost ?? false
        let caPath = caURL.path.withCString(pp_dup)
        let certPEM = parameters.cfg.clientCertificate?.pem.withCString(pp_dup)
        let keyPEM = parameters.cfg.clientKey?.pem.withCString(pp_dup)
        let hostname = parameters.cfg.sanHost?.withCString(pp_dup)
        defer {
            free(caPath)
            free(certPEM)
            free(keyPEM)
            free(hostname)
        }
        let options = tls_channel_options_create(
            Int32(securityLevel ?? Constants.defaultSecurityLevel),
            Constants.bufferLength,
            checksEKU,
            checksSANHost,
            caPath,
            certPEM,
            keyPEM,
            hostname,
            {
                NotificationCenter.default.post(name: .tlsDidFailVerificationNotification, object: nil)
            }
        )
        var error = TLSErrorNone
        guard let tls = tls_channel_create(options, &error) else {
            tls_channel_options_free(options)
            try? FileManager.default.removeItem(at: caURL)

            throw CTLSError(error)
        }
        self.tls = tls

        verificationObserver = NotificationCenter.default.addObserver(
            forName: .tlsDidFailVerificationNotification,
            object: nil,
            queue: nil,
            using: { _ in
                parameters.onVerificationFailure()
            }
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(verificationObserver)
        tls_channel_free(tls)
        try? FileManager.default.removeItem(at: caURL)
    }

    func start() throws {
        guard tls_channel_start(tls) else {
            throw TLSError.start
        }
    }

    func isConnected() -> Bool {
        tls_channel_is_connected(tls)
    }

    func putPlainText(_ text: String) throws {
        try text.withCString { buf in
            var error = TLSErrorNone
            guard tls_channel_put_plain(tls, buf, text.count, &error) else {
                throw CTLSError(error)
            }
        }
    }

    func putRawPlainText(_ text: Data) throws {
        try text.withUnsafeBytes { buf in
            var error = TLSErrorNone
            guard tls_channel_put_plain(tls, buf.bytePointer, text.count, &error) else {
                throw CTLSError(error)
            }
        }
    }

    func putCipherText(_ data: Data) throws {
        try data.withUnsafeBytes { buf in
            var error = TLSErrorNone
            guard tls_channel_put_cipher(tls, buf.bytePointer, data.count, &error) else {
                throw CTLSError(error)
            }
        }
    }

    func pullPlainText() throws -> Data {
        var error = TLSErrorNone
        guard let zd = tls_channel_pull_plain(tls, &error) else {
            guard error == TLSErrorNone else {
                throw CTLSError(error)
            }
            throw TLSError.noData
        }
        return Data(zeroing: zd)
    }

    func pullCipherText() throws -> Data {
        var error = TLSErrorNone
        guard let zd = tls_channel_pull_cipher(tls, &error) else {
            guard error == TLSErrorNone else {
                throw CTLSError(error)
            }
            throw TLSError.noData
        }
        return Data(zeroing: zd)
    }

    func caMD5() throws -> String {
        guard let buf = tls_channel_ca_md5(tls) else {
            throw TLSError.encryption
        }
        defer {
            free(buf)
        }
        guard let md5 = String(cString: buf, encoding: .ascii) else {
            throw TLSError.encryption
        }
        return md5
    }
}
