// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_MONOLITH
import PartoutCore
#endif

@MainActor
final class ABIContext {
    let registry: Registry

    private var daemon: SimpleConnectionDaemon?

    init(registry: Registry) {
        self.registry = registry
    }

    func startDaemon(_ daemon: SimpleConnectionDaemon) async throws {
        self.daemon = daemon
        try await daemon.start()
    }

    func stopDaemon() async {
        await daemon?.stop()
        daemon = nil
    }
}

@MainActor
extension ABIContext {
    func push() -> UnsafeMutableRawPointer {
        Unmanaged.passRetained(self).toOpaque()
    }

    static func pop(_ raw: UnsafeMutableRawPointer) {
        Unmanaged<ABIContext>.fromOpaque(raw).release()
    }

    static func peek(_ raw: UnsafeMutableRawPointer) -> ABIContext {
        Unmanaged.fromOpaque(raw).takeUnretainedValue()
    }
}
