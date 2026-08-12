// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension TunnelRemoteInfoWrapper {
    init(_ profile: Profile, info: TunnelRemoteInfo) {
        self.init(
            profile: profile.asTaggedProfile,
            originalModuleId: info.originalModuleId,
            address: info.address,
            requiresVirtualDevice: info.requiresVirtualDevice,
            modules: info.modules?.compactMap(\.taggedModule)
        )
    }
}

extension TunnelRemoteInfo {
    func encodedAsJSON(_ profile: Profile) throws -> String {
        let wrapped = TunnelRemoteInfoWrapper(profile, info: self)
        do {
            return try JSONEncoder.shared().encodeJSON(wrapped)
        } catch {
            throw PartoutError(error)
        }
    }
}
