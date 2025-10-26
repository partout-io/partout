// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

/// The central store of tunnel environment values.
public typealias TunnelEnvironment = AnyObject & TunnelEnvironmentReader & TunnelEnvironmentWriter

/// Able to read an environment.
public protocol TunnelEnvironmentReader: Sendable {
    var onUpdate: AsyncStream<Void> { get }

    func environmentValue<T>(forKey key: TunnelEnvironmentKey<T>) -> T? where T: Decodable

    func snapshot(excludingKeys excluded: Set<String>?) -> [String: Data]
}

/// Able to edit an environment.
public protocol TunnelEnvironmentWriter: Sendable {
    func setEnvironmentValue<T>(_ value: T, forKey key: TunnelEnvironmentKey<T>) where T: Encodable

    func removeEnvironmentValue(forKey key: String)

    func reset()
}

/// The key to a ``TunnelEnvironment``.
public struct TunnelEnvironmentKey<T>: TunnelEnvironmentKeyProtocol, Sendable {
    public let keyString: String

    public init(_ keyString: String) {
        self.keyString = keyString
    }
}

/// The common interface of tunnel environment keys.
public protocol TunnelEnvironmentKeyProtocol {
    var keyString: String { get }
}

extension TunnelEnvironmentReader {
    public var onUpdate: AsyncStream<Void> {
        AsyncStream {}
    }
}

extension TunnelEnvironmentWriter {
    public func removeEnvironmentValue<T>(forKey key: TunnelEnvironmentKey<T>) {
        removeEnvironmentValue(forKey: key.keyString)
    }
}
