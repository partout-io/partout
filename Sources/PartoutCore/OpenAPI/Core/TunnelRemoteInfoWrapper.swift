// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// An encodable wrapper of ``TunnelRemoteInfo``.
public struct TunnelRemoteInfoWrapper: Encodable, Sendable {
    public let originalModuleId: UniqueID
    public let address: Address?
    public let requiresVirtualDevice: Bool
    public let modules: [TaggedModule]?

    public init(_ info: TunnelRemoteInfo) {
        originalModuleId = info.originalModuleId
        address = info.address
        requiresVirtualDevice = info.requiresVirtualDevice
        modules = info.modules?.compactMap(\.taggedModule)
    }
}
