//
//  Demo+WireGuard.swift
//  Partout
//
//  Created by Davide De Rosa on 3/26/24.
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
import PartoutWireGuardGo

extension WireGuard {
    static var demoModule: WireGuardModule {
        do {
            let wg = try String(contentsOf: Constants.demoURL)
            let builder = try StandardWireGuardParser().configuration(from: wg).builder()
            let module = WireGuardModule.Builder(configurationBuilder: builder)
            return try module.tryBuild()
        } catch {
            fatalError("Unable to build: \(error)")
        }
    }
}

private enum Constants {
    static let demoURL = Bundle.main.url(forResource: "Files/test-sample", withExtension: "wg")!
}
