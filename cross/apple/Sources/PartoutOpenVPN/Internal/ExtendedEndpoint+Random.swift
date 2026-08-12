// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension ExtendedEndpoint {
    func withRandomPrefixLength(_ length: Int, prng: PRNGProtocol) -> ExtendedEndpoint {
        guard isHostname else {
            return self
        }
        let prefix = prng.data(length: length)
        let prefixedAddress = "\(prefix.toHex()).\(address)"
        do {
            return try ExtendedEndpoint(prefixedAddress, proto)
        } catch {
            return self
        }
    }
}

extension OpenVPN.Configuration {
    private static let randomHostnamePrefixLength = 6

    func processedRemotes(prng: PRNGProtocol) -> [ExtendedEndpoint]? {
        guard var processedRemotes = remotes else {
            return nil
        }
        if randomizeEndpoint ?? false {
            processedRemotes.shuffle()
        }
        if let randomPrefixLength = (randomizeHostnames ?? false) ? Self.randomHostnamePrefixLength : nil {
            processedRemotes = processedRemotes.map {
                $0.withRandomPrefixLength(randomPrefixLength, prng: prng)
            }
        }
        return processedRemotes
    }
}
