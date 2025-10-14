// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

/// Transient settings, not serialized.
public struct TransientModule: Module, @unchecked Sendable {
    public let id: UniqueID

    public let object: Any

    public init(object: Any) {
        id = UniqueID()
        self.object = object
    }
}

extension TransientModule: SensitiveDebugStringConvertible {
    public func debugDescription(withSensitiveData: Bool) -> String {
        guard withSensitiveData,
              let descriptive = object as? CustomDebugStringConvertible else {
            return "\(type(of: object))"
        }
        return descriptive.debugDescription
    }
}
