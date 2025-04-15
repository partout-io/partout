//
//  ProfileType+Providers.swift
//  Partout
//
//  Created by Davide De Rosa on 4/12/25.
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

// MARK: - Providers

extension ProfileType where GenericModuleType == Module {
    public var activeProviderModule: ProviderModule? {
        assertSingleActiveProviderModule()
    }

    @discardableResult
    public func assertSingleActiveProviderModule() -> ProviderModule? {
        let activeProviderModules = activeModules.filter {
            $0 is ProviderModule
        }
        assert(activeProviderModules.count <= 1, "More than 1 active provider module?")
        return activeProviderModules.first as? ProviderModule
    }
}
