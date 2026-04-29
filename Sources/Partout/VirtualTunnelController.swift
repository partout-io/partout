// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !os(iOS) && !os(tvOS)

internal import _PartoutCore_C

/// A controller that operates on a virtual tun interface.
public final class VirtualTunnelController: TunnelController {
    private let ctx: PartoutLoggerContext

    nonisolated(unsafe)
    private let impl: UnsafeMutableRawPointer?

    private let maxReadLength: Int

    public init(
        _ ctx: PartoutLoggerContext,
        impl: UnsafeMutableRawPointer?,
        maxReadLength: Int = 128 * 1024
    ) throws {
        self.ctx = ctx
        self.impl = impl
        self.maxReadLength = maxReadLength

        if let thiz = impl {
            pp_tun_ctrl_test_working_wrapper(thiz)
        }
    }

    deinit {
        if let impl {
            pp_tun_ctrl_free(impl)
        }
        pp_log(ctx, .core, .debug, "Deinit VirtualTunnelController")
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
        let tunImpl: UnsafeMutableRawPointer?
        if let impl {
            tunImpl = infoJSON.withCString {
                pp_tun_ctrl_set_tunnel(impl, $0)
            }
            guard let tunImpl else {
                throw PartoutError(.linkNotActive)
            }
        } else {
            tunImpl = nil
        }
        let uuid = info.originalModuleId
        guard let tun = uuid.uuidString.withCString({
            pp_tun_create($0, tunImpl)
        }) else {
            if let impl {
                pp_tun_ctrl_clear_tunnel(impl, tunImpl)
            }
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

        return VirtualTunnelInterface(ctx, tun: tun, tunImpl: tunImpl, maxReadLength: maxReadLength)
    }

    public func configureSockets(with descriptors: [UInt64]) {
        if let thiz = impl {
            descriptors.map(Int32.init).withUnsafeBufferPointer {
                pp_tun_ctrl_configure_sockets(thiz, $0.baseAddress, $0.count)
            }
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
        if let thiz = impl {
            pp_tun_ctrl_clear_tunnel(thiz, tunnel.tunImpl)
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
