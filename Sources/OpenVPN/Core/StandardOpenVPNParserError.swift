// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutCore

/// Thrown by ``StandardOpenVPNParser``, with details about the line that triggered it.
public enum StandardOpenVPNParserError: Error {

    /// The PUSH_REPLY is multipart.
    case continuationPushReply

    /// A decrypter is required to proceed.
    case decrypterRequired

    /// Passphrase required to decrypt private keys.
    case encryptionPassphrase

    /// File format is invalid.
    case invalidFormat

    /// Option syntax is incorrect.
    case malformed(option: String)

    /// Encryption passphrase is incorrect or key is corrupt.
    case unableToDecrypt(error: Error?)

    /// An option is unsupported.
    case unsupportedConfiguration(option: String)
}

// MARK: - Mapping

extension StandardOpenVPNParserError: PartoutErrorMappable {
    public var asPartoutError: PartoutError {
        switch self {
        case .malformed(let option):
            return PartoutError(.parsing, option, self)

        case .unsupportedConfiguration(let option):
            return PartoutError(.parsing, option, self)

        case .encryptionPassphrase, .unableToDecrypt:
            return PartoutError(.crypto, self)

        default:
            return PartoutError(.parsing, self)
        }
    }
}
