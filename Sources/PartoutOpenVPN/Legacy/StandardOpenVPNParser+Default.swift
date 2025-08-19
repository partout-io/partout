// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_MONOLITH
internal import _PartoutOpenVPNLegacy_ObjC
import PartoutOpenVPN
#endif

extension StandardOpenVPNParser {
    public convenience init() {
        self.init(supportsLZO: true, decrypter: OSSLTLSBox())
    }
}

// XXX: unsafe but legacy
extension OSSLTLSBox: @retroactive @unchecked Sendable {}
