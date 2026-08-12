// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// The most basic Swift PRNG.
public final class SimplePRNG: PRNGProtocol {
    public init() {
    }

    public func data(length: Int) -> Data {
        var data = Data(count: length)
        for i in 0..<length {
            data[i] = .random(in: 0...0xff)
        }
        return data
    }
}
