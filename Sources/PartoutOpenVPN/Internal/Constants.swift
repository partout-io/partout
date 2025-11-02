// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_MONOLITH
import PartoutCore
import PartoutOS
#endif

// Avoid duplicates
#if !OPENVPN_LEGACY
internal import PartoutOpenVPN_C
#else
internal import PartoutOpenVPN_ObjC
#endif

struct Constants {
    enum Keys {
        static let label1 = "OpenVPN master secret"

        static let label2 = "OpenVPN key expansion"

        static let randomLength = 32

        static let preMasterLength = 48

        static let keyLength = 64

        static let keysCount = 4
    }

    enum ControlChannel {
        static let maxPacketSize = 1000

        // UInt32(0) + UInt8(KeyMethod = 2)
        static let tlsPrefix = Data(hex: "0000000002")

        private static let numberOfKeys = UInt8(8) // 3-bit

        static func nextKey(after currentKey: UInt8) -> UInt8 {
            max(1, (currentKey + 1) % numberOfKeys)
        }

        static let ctrTagLength = 32

        static let ctrPayloadLength = OpenVPNPacketOpcodeLength + OpenVPNPacketSessionIdLength + OpenVPNPacketReplayIdLength + OpenVPNPacketReplayTimestampLength
    }

    enum DataChannel {
        static let prngSeedLength = 64

        static let aeadTagLength = 16

        static let aeadIdLength = OpenVPNPacketIdLength

        static let pingString = Data(hex: "2a187bf3641eb4cb07ed2d0a981fc748")

        static let usesReplayProtection = true
    }
}

extension Constants.ControlChannel {
    static func peerInfo(sslVersion: String? = nil, withPlatform: Bool = true, extra: [String: String]? = nil) -> String {
        let uiVersion = Partout.versionIdentifier
        var info = [
            "IV_VER=2.4",
            "IV_UI_VER=\(uiVersion)",
            "IV_PROTO=2",
            "IV_NCP=2",
            "IV_LZO_STUB=1"
        ]
#if OPENVPN_DEPRECATED_LZO
        info.append("IV_LZO=1")
#else
        info.append("IV_LZO=0")
#endif
        // XXX: always do --push-peer-info
        // however, MAC is inaccessible and IFAD is deprecated, skip IV_HWADDR
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
#elseif os(macOS)
            platform = "mac"
#elseif os(Android)
            platform = "android"
#elseif os(Linux)
            platform = "linux"
#elseif os(Windows)
            platform = "windows"
#else
            platform = "unknown"
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
}
