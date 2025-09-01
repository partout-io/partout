// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if os(macOS) || os(Linux)

import _PartoutOSPortable_C
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

public final class VirtualTunnelController: TunnelController {
    private let ctx: PartoutLoggerContext

    private let maxReadLength: Int

    private let withPacketInformation: Bool

    public init(_ ctx: PartoutLoggerContext, maxReadLength: Int = 128 * 1024) throws {
        self.ctx = ctx
        self.maxReadLength = maxReadLength

        // FIXME: #188, make PI a postRead/preWrite block pair for VirtualTunnelInterface
#if os(macOS)
        withPacketInformation = true
#else
        withPacketInformation = false
#endif
    }

    public func setTunnelSettings(with info: TunnelRemoteInfo?) async throws -> IOInterface {
        guard let info else {
            throw PartoutError(.notFound)
        }

        // Create virtual device
        let tun = try VirtualTunnelInterface(
            ctx,
            withPacketInformation: withPacketInformation,
            maxReadLength: maxReadLength
        )

        // FIXME: #188, add better codes for PartoutError
        // FIXME: #188, apply subnets and routes (default first, drop excluded from included)

//        var subnets: [(String, String)] = []
//        var includedRoutes: [Route] = []
//        var excludedRoutes: [Route] = []
//        info.modules?.forEach {
//            switch $0 {
//            case let ip as IPModule:
//                for settings in [ip.ipv4, ip.ipv6] {
//                    guard let settings else { return }
//                    if let subnet = settings.subnet {
//                        subnets.append((subnet.rawValue, subnet.address.rawValue))
//                    }
//                    includedRoutes.append(contentsOf: settings.includedRoutes)
//                    excludedRoutes.append(contentsOf: settings.excludedRoutes)
//                }
//            default:
//                break
//            }
//        }
//
//        // Add exception for server address to escape the tunnel
//        if let serverAddress = info.address {
//            excludedRoutes.append(Route(Subnet(serverAddress), nil))
//        }

        return tun
    }

    public func clearTunnelSettings(_ tunnel: IOInterface) async {
        guard let _ = tunnel as? VirtualTunnelInterface else {
            assertionFailure("Expected type is VirtualTunnelInterface")
            return
        }
        // FIXME: #188, revert settings (record)
//        tun.deviceName
    }

    public func setReasserting(_ reasserting: Bool) {
        // Do nothing
    }

    public func cancelTunnelConnection(with error: Error?) {
        // Do nothing
    }
}

#endif
