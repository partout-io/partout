//
//  AppleRandom.swift
//  Partout
//
//  Created by Davide De Rosa on 3/23/24.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//

import Foundation
import PartoutCore
import Security.SecRandom

/// Implementation of ``PRNGProtocol`` based on the `Security` framework.
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
