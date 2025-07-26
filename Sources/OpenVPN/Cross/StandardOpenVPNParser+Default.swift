// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutOpenVPN_C
import PartoutOpenVPN

extension StandardOpenVPNParser {
    public convenience init() {
        self.init(supportsLZO: false, decrypter: OSSLKeyDecrypter())
    }
}
