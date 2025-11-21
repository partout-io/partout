// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import PartoutCore_C

extension Data {
    public var asIPAddress: String? {
        let maxLength = Int(Swift.max(INET_ADDRSTRLEN, INET6_ADDRSTRLEN))
        var dstCString = [CChar](repeating: .zero, count: maxLength)
        let result = withUnsafeBytes { src in
            dstCString.withUnsafeMutableBytes { dst in
                pp_addr_string(dst.baseAddress, maxLength, src.baseAddress, count, nil)
            }
        }
        guard result != 0 else {
            return nil
        }
        return dstCString.string
    }
}
