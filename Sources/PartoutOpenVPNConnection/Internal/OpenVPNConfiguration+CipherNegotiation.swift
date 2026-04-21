// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension OpenVPN.Configuration {
    /// Returns the ciphers this client can advertise for OpenVPN data-channel
    /// negotiation.
    ///
    /// The explicit `dataCiphers` list is preferred for negotiation, while the
    /// legacy/fallback `cipher` is appended only for compatibility with peers
    /// that still rely on the older single-cipher model.
    var negotiableDataCiphers: [OpenVPN.Cipher]? {
        guard var ciphers = dataCiphers, !ciphers.isEmpty else {
            return nil
        }
        if let cipher, !ciphers.contains(cipher) {
            ciphers.append(cipher)
        }
        return ciphers
    }

    /// Resolves the data-channel cipher to actually use for this session.
    ///
    /// OpenVPN expects the server to select the negotiated cipher and communicate
    /// it back to the client as a single `cipher` value, either via pushed
    /// options or via the TLS auth-options/OCC exchange. If neither path yields
    /// a server-selected cipher, fall back to the locally configured legacy
    /// cipher or, when only `dataCiphers` is set, to its first entry.
    func negotiatedDataChannelCipher(
        with pushedOptions: OpenVPN.Configuration,
        serverOptions: ServerOCC?
    ) -> OpenVPN.Cipher {
        if let pushedCipher = pushedOptions.cipher {
            return pushedCipher
        }
        if let serverCipher = serverOptions?.cipher,
           negotiableDataCiphers?.contains(serverCipher) ?? false {
            return serverCipher
        }
        return fallbackCipher
    }
}
