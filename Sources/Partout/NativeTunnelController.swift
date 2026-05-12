// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !os(iOS) && !os(tvOS)

internal import _PartoutCore_C

/// A controller that operates on a virtual tun interface.
public final class NativeTunnelController: TunnelController {
    private let ctx: PartoutLoggerContext

    nonisolated(unsafe)
    private let ref: UnsafeMutableRawPointer?

    private let maxReadLength: Int

    public init(
        _ ctx: PartoutLoggerContext,
        ref: UnsafeMutableRawPointer?,
        maxReadLength: Int = 128 * 1024
    ) throws {
        self.ctx = ctx
        self.ref = ref
        self.maxReadLength = maxReadLength

        pp_tun_ctrl_test_working(ref)
    }

    deinit {
        pp_log(ctx, .core, .debug, "Deinit NativeTunnelController")
    }

    public func setTunnelSettings(with info: TunnelRemoteInfo?) async throws -> IOInterface {
        guard let info else {
            throw PartoutError(.notFound)
        }
        guard info.requiresVirtualDevice else {
            return DummyTunnelInterface()
        }

        let infoJSON: String = try {
            let wrapped = TunnelRemoteInfoWrapper(info)
            let data = try JSONEncoder().encode(wrapped)
            guard let json = String(data: data, encoding: .utf8) else {
                throw PartoutError(.notFound)
            }
            return json
        }()

        // Create tun with optional implementation from controller
        guard let tun = info.originalModuleId.uuidString.withCString({ uuid in
            infoJSON.withCString { info in
                pp_tun_ctrl_set_tunnel(ref, uuid, info)
            }
        }) else {
            throw PartoutError(.linkNotActive)
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

        return VirtualTunnelInterface(ctx, tun: tun, maxReadLength: maxReadLength)
    }

    public func configureSockets(with descriptors: [UInt64]) {
        descriptors.map(Int32.init).withUnsafeBufferPointer {
            pp_tun_ctrl_configure_sockets(ref, $0.baseAddress, $0.count)
        }
    }

    public func clearTunnelSettings(_ io: IOInterface, withKillSwitch: Bool) async {
        guard let tunnel = io as? VirtualTunnelInterface else {
            assertionFailure("Expected type is VirtualTunnelInterface")
            return
        }
        // FIXME: #188, revert settings (record)
//        tun.deviceName
        await tunnel.shutdown()

        // Release tun implementation if necessary
        pp_tun_ctrl_clear_tunnel(ref, tunnel.tun)
    }

    public func setReasserting(_ reasserting: Bool) {
        // Do nothing
    }

    public func cancelTunnelConnection(with error: Error?) {
        // Do nothing
    }
}

#endif

final class DummyTunnelInterface: IOInterface {
    var fileDescriptor: UInt64? {
        nil
    }

    func readPackets() async throws -> [Data] {
        []
    }

    func writePackets(_ packets: [Data]) async throws {
    }
}

struct TunnelRemoteInfoWrapper: Encodable, Sendable {
    let originalModuleId: UniqueID

    let address: Address?

    let fileDescriptors: [UInt64]

    let requiresVirtualDevice: Bool

    let modules: [TaggedModule]?

    init(_ info: TunnelRemoteInfo) {
        originalModuleId = info.originalModuleId
        address = info.address
        fileDescriptors = info.fileDescriptors
        requiresVirtualDevice = info.requiresVirtualDevice
        modules = info.modules?.compactMap(\.taggedModule)
    }
}
