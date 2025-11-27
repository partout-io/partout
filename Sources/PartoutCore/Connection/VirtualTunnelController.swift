// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !os(iOS) && !os(tvOS)

@_implementationOnly import _PartoutCore_C

/// A ``TunnelController`` that operates on a virtual tun interface like ``VirtualTunnelInterface``.
public final class VirtualTunnelController: TunnelController {
    private let ctx: PartoutLoggerContext

    nonisolated(unsafe)
    private let ctrl: VirtualTunnelControllerImpl?

    private let maxReadLength: Int

    public init(
        _ ctx: PartoutLoggerContext,
        ctrl: VirtualTunnelControllerImpl?,
        maxReadLength: Int = 128 * 1024
    ) throws {
        self.ctx = ctx
        self.ctrl = ctrl
        self.maxReadLength = maxReadLength
    }

    public func setTunnelSettings(with info: TunnelRemoteInfo?) async throws -> IOInterface {
        guard let info else {
            throw PartoutError(.notFound)
        }

        // Fetch tun implementation if necessary
        let tunImpl = ctrl.map {
            $0.setTunnel($0.thiz, info)
        } ?? nil

        // Create virtual device with an optional implementation
        let uuid = info.originalModuleId
        let tun: IOInterface
        if info.requiresVirtualDevice {
            tun = try VirtualTunnelInterface(ctx, uuid: uuid, tunImpl: tunImpl, maxReadLength: maxReadLength)
        } else {
            tun = DummyTunnelInterface()
        }

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

    public func configureSockets(with descriptors: [UInt64]) {
        if let ctrl {
            ctrl.configureSockets(ctrl.thiz, descriptors)
        }
    }

    public func clearTunnelSettings(_ io: IOInterface) async {
        guard let tunnel = io as? VirtualTunnelInterface else {
            assertionFailure("Expected type is VirtualTunnelInterface")
            return
        }
        // FIXME: #188, revert settings (record)
//        tun.deviceName

        // Release tun implementation if necessary
        if let ctrl {
            ctrl.clearTunnel(ctrl.thiz, tunnel.tunImpl)
        }
    }

    public func setReasserting(_ reasserting: Bool) {
        // Do nothing
    }

    public func cancelTunnelConnection(with error: Error?) {
        // Do nothing
    }
}

#endif
