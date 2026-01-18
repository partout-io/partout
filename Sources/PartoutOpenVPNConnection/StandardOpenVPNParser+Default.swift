// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension StandardOpenVPNParser {
    public convenience init() {
        self.init(decrypter: SimpleKeyDecrypter())
    }
}
