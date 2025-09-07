// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

#if !PARTOUT_MONOLITH
import PartoutWireGuard
#endif
import Foundation
import wg_go

// swiftlint:disable identifier_name
public final class WireGuardBackendVendor: WireGuardBackend {
    public init() {
    }

    public func setLogger(context: UnsafeMutableRawPointer?, logger_fn: WireGuardLoggerCallback?) {
        wgSetLogger(context, logger_fn)
    }

    public func turnOn(settings: String, tun_fd: Int32) -> Int32 {
        wgTurnOn(settings.rawString, tun_fd)
    }

    public func socketDescriptors(_ handle: Int32) -> [Int32] {
#if os(Android)
        [wgGetSocketV4(handle), wgGetSocketV6(handle)]
#else
        []
#endif
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
