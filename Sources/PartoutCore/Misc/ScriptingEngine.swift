// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

public protocol ScriptingEngine {
    func inject(_ name: String, object: Any)

    func execute<O>(_ script: String, after preScript: String?, returning: O.Type) async throws -> O where O: Decodable
}
