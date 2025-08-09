// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutOpenVPNLegacy_ObjC
import Foundation
import PartoutCore

struct Constants {

    // MARK: Session

    static let usesReplayProtection = true

    static let maxPacketSize = 1000

    // MARK: Authentication

    static func peerInfo(sslVersion: String? = nil, withPlatform: Bool = true, extra: [String: String]? = nil) -> String {
        let uiVersion = Partout.versionIdentifier
        var info = [
            "IV_VER=2.4",
            "IV_UI_VER=\(uiVersion)",
            "IV_PROTO=2",
            "IV_NCP=2",
            "IV_LZO_STUB=1"
        ]
        if LZOFactory.canCreate() {
            info.append("IV_LZO=1")
        }
        // XXX: always do --push-peer-info
        // however, MAC is inaccessible and IFAD is deprecated, skip IV_HWADDR
//            if pushPeerInfo {
        if let sslVersion {
            info.append("IV_SSL=\(sslVersion)")
        }
        if withPlatform {
            let platform: String
            let platformVersion = ProcessInfo.processInfo.operatingSystemVersion
#if os(iOS)
            platform = "ios"
#elseif os(tvOS)
            platform = "tvos"
#else
            platform = "mac"
#endif
            info.append("IV_PLAT=\(platform)")
            info.append("IV_PLAT_VER=\(platformVersion.majorVersion).\(platformVersion.minorVersion)")
        }
        if let extra {
            info.append(contentsOf: extra.map {
                "\($0)=\($1)"
            })
        }
        info.append("")
        return info.joined(separator: "\n")
    }

    static let randomLength = 32

    // MARK: Keys

    static let label1 = "OpenVPN master secret"

    static let label2 = "OpenVPN key expansion"

    static let preMasterLength = 48

    static let keyLength = 64

    static let keysCount = 4
}
