// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Highly scalable representation of a network configuration.
///
/// Modules are the building blocks of a ``Profile``. Must be actor-safe, and possibly `struct`.
public protocol Module: UniquelyIdentifiable, Sendable {
    /// Unique ``ModuleType`` for this module.
    static var moduleType: ModuleType { get }

    /// A deterministic fingerprint.
    var fingerprint: Int { get }

    /// True if builds a ``Connection``.
    var buildsConnection: Bool { get }

    /// True if module is final, i.e. does not require conversion to another module to be used.
    var isFinal: Bool { get }

    /// True if requires user input before connecting.
    var isInteractive: Bool { get }

    /// True if only one module of this type can be active in a ``Profile``.
    var isMutuallyExclusive: Bool { get }

    func checkCompatible(with otherModule: Module, activeIds: Set<UniqueID>) throws

    /// True if the module can be serialized as a textual configuration.
    var supportsSerialization: Bool { get }

    func serialized() throws -> String?
}

extension Module {
    public var moduleType: ModuleType {
        Self.moduleType
    }

    /// Returns a textual representation of this module, if supported.
    public func serialized() throws -> String? {
        nil
    }

    public var supportsSerialization: Bool {
        false
    }
}
