// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension TunnelRemoteInfoWrapper {
    init(_ profile: Profile, options: TunnelControllerOptions, info: TunnelRemoteInfo) {
        self.init(
            address: info.address,
            modules: info.modules?.compactMap(\.taggedModule),
            options: options,
            originalModuleId: info.originalModuleId,
            profile: profile.asTaggedProfile,
            requiresVirtualDevice: info.requiresVirtualDevice
        )
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
