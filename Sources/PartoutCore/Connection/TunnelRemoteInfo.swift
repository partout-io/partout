// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// A set of extra info that a ``Connection`` may signal to the tunnel to complete the configuration stage.
public struct TunnelRemoteInfo: Sendable {

    /// The originating module identifier.
    public let originalModuleId: UniqueID

    /// The remote tunnel address.
    public let address: Address?

    /// The extra modules returned by the connection.
    public let modules: [Module]?

    /// The file descriptors of the underlying connections.
    public let fileDescriptors: [UInt64]

    /// True if the controller should create a virtual I/O device.
    public let requiresVirtualDevice: Bool

    public init(originalModuleId: UniqueID, address: Address?, modules: [Module]?, fileDescriptors: [UInt64], requiresVirtualDevice: Bool = true) {
        self.originalModuleId = originalModuleId
        self.address = address
        self.modules = modules
        self.fileDescriptors = fileDescriptors
        self.requiresVirtualDevice = requiresVirtualDevice
    }
}
