// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import _PartoutCrypto_C
@testable import PartoutOpenVPN

extension CryptoBackend {
    static var forTesting: CryptoBackend {
        .default
    }
}

extension pp_crypto_enc_fnt {
    static var forTesting: Self {
        CryptoBackend.forTesting.functionTable.enc
    }
}

extension pp_crypto_tls_fnt {
    static var forTesting: Self {
        CryptoBackend.forTesting.functionTable.tls
    }
}
