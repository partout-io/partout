//
//  ProviderPreset.swift
//  Partout
//
//  Created by Davide De Rosa on 10/8/24.
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

public struct ProviderPreset: Hashable, Codable, Sendable {
    public let providerId: ProviderID

    public let presetId: String

    public let description: String

    public let moduleType: ModuleType

    public let templateData: Data

    public init(
        providerId: ProviderID,
        presetId: String,
        description: String,
        moduleType: ModuleType,
        templateData: Data
    ) {
        self.providerId = providerId
        self.presetId = presetId
        self.description = description
        self.moduleType = moduleType
        self.templateData = templateData
    }
}

extension ProviderPreset {
    public var id: String {
        [providerId.rawValue, presetId].joined(separator: ".")
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.providerId == rhs.providerId && lhs.presetId == rhs.presetId
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(providerId)
        hasher.combine(presetId)
    }
}

extension ProviderPreset {
    public func template<Template>(ofType type: Template.Type) throws -> Template where Template: Decodable {
        try JSONDecoder().decode(type, from: templateData)
    }
}
