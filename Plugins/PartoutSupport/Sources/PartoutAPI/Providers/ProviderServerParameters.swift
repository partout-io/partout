//
//  ProviderServerParameters.swift
//  Partout
//
//  Created by Davide De Rosa on 10/12/24.
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

public struct ProviderServerParameters {
    public var filters: ProviderFilters

    public var sorting: [ProviderSortField]

    public init(filters: ProviderFilters = ProviderFilters(), sorting: [ProviderSortField] = []) {
        self.filters = filters
        self.sorting = sorting
    }
}

public struct ProviderFilters: Equatable {
    public var moduleType: ModuleType?

    public var categoryName: String?

    public var countryCode: String?

    public var area: String?

    public var presetId: String?

    public var serverIds: Set<String>?

    public init() {
    }
}

public enum ProviderSortField {
    case localizedCountry

    case area

    case serverId
}

public struct ProviderFilterOptions {
    public let countriesByCategoryName: [String: Set<String>]

    public let countryCodes: Set<String>

    public let presets: Set<ProviderPreset>

    public init(countriesByCategoryName: [String: Set<String>] = [:], countryCodes: Set<String> = [], presets: Set<ProviderPreset> = []) {
        self.countriesByCategoryName = countriesByCategoryName
        self.countryCodes = countryCodes
        self.presets = presets
    }
}
