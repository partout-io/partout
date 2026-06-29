// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCrypto_C

extension StandardOpenVPNParser {
    public convenience init() {
        self.init(decrypter: SimpleKeyDecrypter(backend: .default))
    }
}
