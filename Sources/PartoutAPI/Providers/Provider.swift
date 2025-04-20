//
//  Provider.swift
//  Partout
//
//  Created by Davide De Rosa on 10/5/24.
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

public struct Provider: Identifiable, Hashable, CustomStringConvertible {
    public let id: ProviderID

    public let description: String

    public let metadata: [ModuleType: Metadata]

    public init(_ id: String, description: String, moduleTypes: [Module.Type]) {
        self.init(id, description: description, metadata: moduleTypes.reduce(into: [:]) {
            $0[$1.moduleHandler.id] = Metadata()
        })
    }

    public init(_ id: String, description: String, handlers: [ModuleHandler]) {
        self.init(id, description: description, metadata: handlers.reduce(into: [:]) {
            $0[$1.id] = Metadata()
        })
    }

    public init(_ id: String, description: String, metadata: [ModuleType: Metadata] = [:]) {
        self.id = ProviderID(rawValue: id)
        self.description = description
        self.metadata = metadata
    }
}

extension Provider {
    public func supports(_ moduleType: ModuleType) -> Bool {
        metadata.keys.contains(moduleType)
    }

    public func supports<M>(_ moduleType: M.Type) -> Bool where M: Module {
        metadata.keys.contains(moduleType.moduleHandler.id)
    }

    public func customization<M>(for moduleType: M.Type) -> M.ProviderCustomization? where M: Module, M: ProviderCustomizationSupporting {
        guard let cfg = metadata[moduleType.moduleHandler.id] else {
            return nil
        }
        return M.ProviderCustomization(userInfo: cfg.userInfo)
    }
}
