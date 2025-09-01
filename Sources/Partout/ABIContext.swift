// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_MONOLITH
import PartoutCore
#endif

// FIXME: #188, @MainActor maybe
final class ABIContext {
    let registry: Registry

    var daemon: SimpleConnectionDaemon?

    init(registry: Registry) {
        self.registry = registry
    }
}

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
