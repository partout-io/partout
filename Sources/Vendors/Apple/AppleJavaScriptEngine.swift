//
//  AppleJavaScriptEngine.swift
//  Partout
//
//  Created by Davide De Rosa on 3/25/25.
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
import JavaScriptCore
import PartoutCore

public final class AppleJavaScriptEngine: ScriptingEngine {
    private let engine: JSContext

    public init(_ ctx: PartoutLoggerContext) {
        engine = JSContext()
        engine.exceptionHandler = { _, exception in
            pp_log(ctx, .core, .error, "AppleJavaScriptEngine: \(exception?.toString() ?? "unknown error")")
        }
    }

    public func inject(_ name: String, object: Any) {
        engine.setObject(object, forKeyedSubscript: name as NSString)
    }

    public func execute<O>(_ script: String, after preScript: String?, returning: O.Type) async throws -> O where O: Decodable {
        try await Task.detached {
            if let preScript {
                _ = self.engine.evaluateScript(preScript)
            }
            guard let value = self.engine.evaluateScript(script) else {
                throw PartoutError(.parsing)
            }
            guard !value.isUndefined else {
                throw PartoutError(.scriptException)
            }
            guard let data = value.toString().data(using: .utf8) else {
                throw PartoutError(.parsing, value)
            }
            return try JSONDecoder().decode(O.self, from: data)
        }.value
    }
}
