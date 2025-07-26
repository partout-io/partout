// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutOpenVPNLegacy_ObjC
import Foundation

final class MockOpenVPNTLS: OpenVPNTLSProtocol {
    func configure(with options: OpenVPNTLSOptions, onFailure: (Error) -> Void) throws {
    }

    func options() -> OpenVPNTLSOptions? {
        nil
    }

    func start() throws {
    }

    func pullCipherText() throws -> Data {
        Data()
    }

    func pullRawPlainText(_ text: UnsafeMutablePointer<UInt8>, length: UnsafeMutablePointer<Int>) throws {
    }

    func putCipherText(_ text: Data) throws {
    }

    func putRawCipherText(_ text: UnsafePointer<UInt8>, length: Int) throws {
    }

    func putPlainText(_ text: String) throws {
    }

    func putRawPlainText(_ text: UnsafePointer<UInt8>, length: Int) throws {
    }

    func isConnected() -> Bool {
        true
    }

    func md5(forCertificatePath path: String) throws -> String {
        ""
    }

    func decryptedPrivateKey(fromPath path: String, passphrase: String) throws -> String {
        ""
    }

    func decryptedPrivateKey(fromPEM pem: String, passphrase: String) throws -> String {
        ""
    }
}
