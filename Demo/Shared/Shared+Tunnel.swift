// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import Partout

extension Registry {
    static let shared = Registry(
        withKnown: true,
        allImplementations: [
            OpenVPNModule.Implementation(
                importer: StandardOpenVPNParser(),
                connectionBlock: {
                    let ctx = PartoutLoggerContext($0.controller.profile.id)
                    return try OpenVPNConnection(
                        ctx,
                        parameters: $0,
                        module: $1,
                        cachesURL: Demo.moduleURL(for: "OpenVPN")
                    )
                }
            ),
            WireGuardModule.Implementation(
                keyGenerator: StandardWireGuardKeyGenerator(),
                importer: StandardWireGuardParser(),
                validator: StandardWireGuardParser(),
                connectionBlock: {
                    let ctx = PartoutLoggerContext($0.controller.profile.id)
                    return try WireGuardConnection(
                        ctx,
                        parameters: $0,
                        module: $1
                    )
                }
            )
        ]
    )
}

extension NEProtocolDecoder where Self == KeychainNEProtocolCoder {
    static var shared: Self {
        Demo.neProtocolCoder
    }
}
