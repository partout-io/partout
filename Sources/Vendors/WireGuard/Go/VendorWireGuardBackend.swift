// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

#if !PARTOUT_STATIC
import _PartoutVendorsWireGuardCore
#endif
import Foundation
import wg_go

// swiftlint:disable identifier_name
public final class VendorWireGuardBackend: WireGuardBackend {
    public init() {
    }

    public func setLogger(context: UnsafeMutableRawPointer?, logger_fn: WireGuardLoggerCallback?) {
        wgSetLogger(context, logger_fn)
    }

    public func turnOn(settings: String, tun_fd: Int32) -> Int32 {
        wgTurnOn(settings.rawString, tun_fd)
    }

    public func turnOff(_ handle: Int32) {
        wgTurnOff(handle)
    }

    public func setConfig(_ handle: Int32, settings: String) -> Int64 {
        wgSetConfig(handle, settings.rawString)
    }

    public func getConfig(_ handle: Int32) -> String? {
        String(cString: wgGetConfig(handle))
    }

    public func bumpSockets(_ handle: Int32) {
        wgBumpSockets(handle)
    }

    public func disableSomeRoamingForBrokenMobileSemantics(_ handle: Int32) {
        wgDisableSomeRoamingForBrokenMobileSemantics(handle)
    }

    public func version() -> String? {
        String(cString: wgVersion())
    }
}
// swiftlint:enable identifier_name

private extension String {
    var rawString: [CChar]? {
        cString(using: .utf8)
    }
}
