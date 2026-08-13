// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutNative

public final class PartoutImporter: Sendable {
    public init() {}

    public func importModule<M>(_ type: M.Type, url: URL) throws -> M? where M: Decodable {
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let cJSON = partout_import_module(text) else { return nil }
        let json = String(cString: cJSON)
        guard let jsonData = json.data(using: .utf8) else { return nil }
        let tagged = try JSONDecoder.shared().decode(TaggedModule.self, from: jsonData)
        return tagged.containedModule as? M
    }
}
