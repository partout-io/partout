// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension CodingUserInfoKey {
    public static let redactingSensitiveData = CodingUserInfoKey(rawValue: "redactingSensitiveData")!
}

extension Encoder {
    public var shouldEncodeSensitiveData: Bool {
        userInfo[.redactingSensitiveData] as? Bool != true
    }
}

extension SensitiveDebugStringConvertible {
    public func encodeSensitiveDescription(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(debugDescription(withSensitiveData: encoder.shouldEncodeSensitiveData))
    }
}

extension PartoutLogger {
    public static let redactedValue = "<redacted>"

    public static let malformedValue = "<malformed>"
}

#if !PARTOUT_FOUNDATION_COMPAT
extension Encodable {
    public func asJSON(_ ctx: PartoutLoggerContext, withSensitiveData: Bool, sortingKeys: Bool = false) -> String? {
        do {
            let encoder = JSONEncoder()
            if !withSensitiveData {
                encoder.userInfo = [.redactingSensitiveData: true]
            }
            if sortingKeys {
                encoder.outputFormatting = [.sortedKeys]
            }
            let encoded = try encoder.encode(self)
            return String(data: encoded, encoding: .utf8)
        } catch {
            pp_log(ctx, .core, .error, "Unable to translate self to JSON: \(error)")
            return nil
        }
    }
}
#endif
