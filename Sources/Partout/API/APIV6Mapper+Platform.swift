//
//  APIV6Mapper+Platform.swift
//  Partout
//
//  Created by Davide De Rosa on 4/20/25.
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

#if canImport(PartoutAPI)

import Foundation

extension API.V6.Mapper {
    public convenience init(baseURL: URL, infrastructureURL: ((ProviderID) -> URL)? = nil) {
        self.init(baseURL: baseURL, infrastructureURL: infrastructureURL) {
            API.V6.DefaultScriptExecutor(
                resultURL: $0,
                cache: $1,
                timeout: $2,
                engine: PartoutConfiguration.platform.newScriptingEngine()
            )
        }
    }
}

#endif
