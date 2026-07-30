// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// The subset of server-side OCC/auth-options values that can affect client
/// runtime behavior.
struct ServerOCC: Hashable, Sendable {
    /// The server-selected data-channel cipher, when provided explicitly.
    let cipher: OpenVPN.Cipher?

    /// The server-selected HMAC digest, when provided explicitly.
    let digest: OpenVPN.Digest?
}

extension ServerOCC {
    /// Parses the OCC/auth-options string exchanged during TLS auth.
    ///
    /// This string is not a full `.ovpn` representation, so parsing is kept
    /// intentionally narrow and tolerant: unknown tokens are ignored and only
    /// the subset relevant to negotiation is extracted. Standard OpenVPN sends
    /// a single `cipher` value here; `data-ciphers-fallback` is accepted as a
    /// tolerant alias for peers that expose the same information under that
    /// name.
    static func parsed(from string: String) -> Self {
        var cipher: OpenVPN.Cipher?
        var digest: OpenVPN.Digest?

        for line in string.components(separatedBy: ",") {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else {
                continue
            }

            let components = trimmedLine.split(whereSeparator: \.isWhitespace)
            guard let option = components.first?.lowercased() else {
                continue
            }
            guard components.count > 1 else {
                continue
            }

            switch option {
            case "cipher":
                cipher = OpenVPN.Cipher(rawValue: components[1].uppercased())

            case "data-ciphers-fallback":
                // Treat the fallback directive as a tolerant alias, but keep an
                // explicit OCC `cipher` if the peer sent both.
                if cipher == nil {
                    cipher = OpenVPN.Cipher(rawValue: components[1].uppercased())
                }

            case "auth":
                digest = OpenVPN.Digest(rawValue: components[1].uppercased())

            default:
                break
            }
        }

        return Self(cipher: cipher, digest: digest)
    }
}
