// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_MONOLITH
import PartoutCore
#endif
import Security.SecRandom

/// A PRNG based on the Security framework.
public final class AppleRandom: PRNGProtocol {
    public init() {
    }

    public func uint32() -> UInt32 {
        var randomNumber: UInt32 = 0

        withUnsafeMutablePointer(to: &randomNumber) {
            $0.withMemoryRebound(to: UInt8.self, capacity: 4) { (randomBytes: UnsafeMutablePointer<UInt8>) in
                guard SecRandomCopyBytes(kSecRandomDefault, 4, randomBytes) == errSecSuccess else {
                    fatalError("SecRandomCopyBytes failed")
                }
            }
        }

        return randomNumber
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
