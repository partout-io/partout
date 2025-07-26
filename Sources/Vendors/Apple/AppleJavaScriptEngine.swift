// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import JavaScriptCore
import PartoutCore

/// Implementation of ``/PartoutCore/ScriptingEngine`` based on the `JavaScriptCore` framework.
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
