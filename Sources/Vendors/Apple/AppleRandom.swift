// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
#if !PARTOUT_STATIC
import PartoutCore
#endif
import Security.SecRandom

/// Implementation of ``/PartoutCore/PRNGProtocol`` based on the `Security` framework.
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

// MARK: - Less performant versions

extension AppleRandom {

    @available(*, deprecated)
    func uint32FromBuffer() throws -> UInt32 {
        var randomBuffer = [UInt8](repeating: 0, count: 4)

        guard SecRandomCopyBytes(kSecRandomDefault, 4, &randomBuffer) == 0 else {
            fatalError("SecRandomCopyBytes failed")
        }

        var randomNumber: UInt32 = 0
        for i in 0..<4 {
            let byte = randomBuffer[i]
            randomNumber |= (UInt32(byte) << UInt32(8 * i))
        }
        return randomNumber
    }
}
