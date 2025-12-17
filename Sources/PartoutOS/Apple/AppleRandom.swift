// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Security.SecRandom

/// A PRNG based on the Security framework.
public final class AppleRandom: PRNGProtocol {
    public init() {
    }

    public func data(length: Int) -> Data {
        precondition(length > 0)
        var randomData = Data(count: length)

        randomData.withUnsafeMutableBytes {
            let randomBytes = $0.bytePointer
            guard SecRandomCopyBytes(kSecRandomDefault, length, randomBytes) == errSecSuccess else {
                fatalError("SecRandomCopyBytes failed")
            }
        }

        return randomData
    }
}
