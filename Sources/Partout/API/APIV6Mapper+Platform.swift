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
import PartoutAPI

extension API.V6.Mapper {
    public convenience init(
        _ ctx: PartoutLoggerContext,
        baseURL: URL,
        infrastructureURL: ((ProviderID) -> URL)? = nil
    ) {
        self.init(ctx, baseURL: baseURL, infrastructureURL: infrastructureURL) {
            API.V6.DefaultScriptExecutor(
                ctx,
                resultURL: $0,
                cache: $1,
                timeout: $2,
                engine: newAPIScriptingEngine(ctx)
            )
        }
    }
}

#if canImport(_PartoutVendorsApple)

import _PartoutVendorsApple

private func newAPIScriptingEngine(_ ctx: PartoutLoggerContext) -> APIScriptingEngine {
    AppleJavaScriptEngine(ctx)
}

extension AppleJavaScriptEngine: APIScriptingEngine {
    public func inject(from vm: APIEngine.VirtualMachine) {
        inject("getText", object: vm.getText as @convention(block) (String) -> Any?)
        inject("getJSON", object: vm.getJSON as @convention(block) (String) -> Any?)
        inject("jsonToBase64", object: vm.jsonToBase64 as @convention(block) (Any) -> String?)
        inject("ipV4ToBase64", object: vm.ipV4ToBase64 as @convention(block) (String) -> String?)
        inject("openVPNTLSWrap", object: vm.openVPNTLSWrap as @convention(block) (String, String) -> [String: Any]?)
        inject("debug", object: vm.debug as @convention(block) (String) -> Void)
    }
}

#else

private func newAPIScriptingEngine(_ ctx: PartoutLoggerContext) -> APIScriptingEngine {
    // TODO: ###, APIScriptingEngine on non-Apple
    fatalError("Unsupported platform")
}

#endif

#endif
