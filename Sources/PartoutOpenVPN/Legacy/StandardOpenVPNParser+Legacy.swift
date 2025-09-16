// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import PartoutOpenVPN_ObjC

extension StandardOpenVPNParser {
    public convenience init() {
        self.init(supportsLZO: true, decrypter: OSSLTLSBox())
    }
}

// XXX: unsafe but legacy
extension OSSLTLSBox: @retroactive @unchecked Sendable {}
