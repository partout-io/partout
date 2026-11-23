// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension Endpoint {
    /// The WireGuard endpoint representation, with brackets around IPv6 addresses.
    public var wireGuardRepresentation: String {
        switch address {
        case .ip(let address, .v6):
            return "[\(address)]:\(port)"
        case .ip(let address, .v4), .hostname(let address):
            return "\(address):\(port)"
        }
    }
}
