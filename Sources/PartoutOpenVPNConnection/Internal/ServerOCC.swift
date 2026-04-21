// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension OpenVPN {
    /// The subset of server-side OCC/auth-options values that can affect client
    /// runtime behavior.
    struct ServerOCC: Hashable, Sendable {
        /// The server-selected data-channel cipher, when provided explicitly.
        let cipher: OpenVPN.Cipher?

        /// The server-advertised negotiated cipher list, if present.
        let dataCiphers: [OpenVPN.Cipher]?

        /// The legacy fallback cipher, if advertised separately.
        let dataCiphersFallback: OpenVPN.Cipher?

        /// The server-selected HMAC digest, when provided explicitly.
        let digest: OpenVPN.Digest?
    }
}

extension OpenVPN.ServerOCC {
    /// Returns the effective single-cipher value carried by the OCC string.
    ///
    /// Standard OpenVPN normally communicates the server-selected cipher as
    /// `cipher`, but `data-ciphers-fallback` is treated as the legacy
    /// single-cipher equivalent when present.
    var effectiveCipher: OpenVPN.Cipher? {
        cipher ?? dataCiphersFallback
    }

    /// Parses the OCC/auth-options string exchanged during TLS auth.
    ///
    /// This string is not a full `.ovpn` representation, so parsing is kept
    /// intentionally narrow and tolerant: unknown tokens are ignored and only
    /// the subset relevant to negotiation is extracted.
    static func parsed(from string: String) -> Self {
        var cipher: OpenVPN.Cipher?
        var dataCiphers: [OpenVPN.Cipher]?
        var dataCiphersFallback: OpenVPN.Cipher?
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

            case "data-ciphers", "ncp-ciphers":
                let parsedCiphers = components[1]
                    .split(separator: ":")
                    .compactMap {
                        OpenVPN.Cipher(rawValue: $0.uppercased())
                    }
                if !parsedCiphers.isEmpty {
                    dataCiphers = parsedCiphers
                }

            case "data-ciphers-fallback":
                dataCiphersFallback = OpenVPN.Cipher(rawValue: components[1].uppercased())

            case "auth":
                digest = OpenVPN.Digest(rawValue: components[1].uppercased())

            default:
                break
            }
        }

        return Self(
            cipher: cipher,
            dataCiphers: dataCiphers,
            dataCiphersFallback: dataCiphersFallback,
            digest: digest
        )
    }
}
