// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0
extension Route {
    public var isDefault: Bool {
        destination == nil
    }

    public init(_ destination: Subnet?, _ gateway: Address?) {
        self.init(destination: destination, gateway: gateway)
    }

    public init(defaultWithGateway gateway: Address?) {
        self.init(destination: nil, gateway: gateway)
    }
}

extension Route: CustomDebugStringConvertible {
    public var debugDescription: String {
        "{\(destination?.description ?? "default") \(gateway?.description ?? "*")}"
    }
}
