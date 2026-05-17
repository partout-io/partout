// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

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

        let infoJSON = try {
            let wrapped = TunnelRemoteInfoWrapper(info)
            do {
                return try JSONEncoder.shared().encodeJSON(wrapped)
            } catch {
                throw PartoutError(error)
            }
        }()

        // Create tun with optional implementation from controller
        guard let tun = info.originalModuleId.uuidString.withCString({ uuid in
            infoJSON.withCString { info in
                pp_tun_ctrl_set_tunnel(ref, uuid, info)
            }
        }) else {
            throw PartoutError(.tunNotAvailable)
        }
        return VirtualTunnelInterface(ctx, tun: tun, maxReadLength: maxReadLength)
    }

    public func configureSockets(with descriptors: [UInt64]) {
        descriptors.map(Int32.init).withUnsafeBufferPointer {
            pp_tun_ctrl_configure_sockets(ref, $0.baseAddress, $0.count)
        }
    }

    public func reportSnapshots(_ snapshots: [TunnelSnapshot]) {
        pp_log(ctx, .core, .debug, "Report tunnel snapshots: \(snapshots)")
        do {
            let json = try JSONEncoder.shared().encodeJSON(snapshots)
            json.withCString {
                pp_tun_ctrl_report_snapshots(ref, $0)
            }
        } catch {
            pp_log(ctx, .core, .error, "Unable to encode snapshots: \(error)")
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
