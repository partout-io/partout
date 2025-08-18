// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

extension OpenVPNModule {
    public final class Implementation: ModuleImplementation, Sendable {
        public let moduleHandlerId: ModuleType = .openVPN

        public let importer: ModuleImporter

        public let connectionBlock: @Sendable (ConnectionParameters, OpenVPNModule) throws -> Connection

        public init(
            importer: ModuleImporter,
            connectionBlock: @escaping @Sendable (ConnectionParameters, OpenVPNModule) throws -> Connection
        ) {
            self.importer = importer
            self.connectionBlock = connectionBlock
        }
    }
}

extension OpenVPNModule.Implementation: ModuleImporter {
    public func module(fromContents contents: String, object: Any?) throws -> Module {
        try importer.module(fromContents: contents, object: object)
    }
}
