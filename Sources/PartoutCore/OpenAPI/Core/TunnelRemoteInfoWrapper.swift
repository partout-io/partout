// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

struct TunnelRemoteInfoWrapper: Encodable, Sendable {
    let profile: TaggedProfile
    let options: TunnelControllerOptions
    let originalModuleId: UniqueID
    let address: Address?
    let requiresVirtualDevice: Bool
    let modules: [TaggedModule]?

    init(_ profile: Profile, options: TunnelControllerOptions, info: TunnelRemoteInfo) {
        self.profile = profile.asTaggedProfile
        self.options = options
        originalModuleId = info.originalModuleId
        address = info.address
        requiresVirtualDevice = info.requiresVirtualDevice
        modules = info.modules?.compactMap(\.taggedModule)
    }
}

extension TunnelRemoteInfo {
    func encodedAsJSON(_ profile: Profile, options: TunnelControllerOptions) throws -> String {
        let wrapped = TunnelRemoteInfoWrapper(profile, options: options, info: self)
        do {
            return try JSONEncoder.shared().encodeJSON(wrapped)
        } catch {
            throw PartoutError(error)
        }
    }
}
