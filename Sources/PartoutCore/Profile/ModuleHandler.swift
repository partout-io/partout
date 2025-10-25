// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

/// Contains the necessary info for module handling and serialization.
public struct ModuleHandler: Identifiable, Sendable {
    public typealias DecodingBlock = @Sendable (Decoder) throws -> Module

    public typealias LegacyDecodingBlock = @Sendable (JSONDecoder, Data) throws -> Module

    public typealias FactoryBlock = @Sendable () -> any ModuleBuilder

    public let id: ModuleType

    public let decoder: DecodingBlock?

    public let legacyDecoder: LegacyDecodingBlock?

    public let factory: FactoryBlock?

    public init<M>(_ id: ModuleType, _ moduleType: M.Type) where M: Module & BuildableType & Decodable, M.B: ModuleBuilder {
        self.init(
            id,
            decoder: {
                try M(from: $0)
            },
            legacyDecoder: {
                try $0.decode(moduleType, from: $1)
            },
            factory: {
                M.B.empty()
            }
        )
    }

    public init(
        _ id: ModuleType,
        decoder: DecodingBlock? = nil,
        legacyDecoder: LegacyDecodingBlock? = nil,
        factory: FactoryBlock? = nil
    ) {
        self.id = id
        self.decoder = decoder
        self.legacyDecoder = legacyDecoder
        self.factory = factory
    }
}

extension ModuleHandler: Hashable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
