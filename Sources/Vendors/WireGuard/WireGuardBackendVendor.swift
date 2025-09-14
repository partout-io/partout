// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import _PartoutOSPortable_C
import _PartoutVendorsWireGuardImpl_C
#if !PARTOUT_MONOLITH
import PartoutWireGuard
#endif
import Foundation

public final class WireGuardBackendVendor: WireGuardBackend {
    public init() {
        guard pp_wg_init() == 0 else {
            fatalError("Unable to load wg-go backend")
        }
    }

    public func setLogger(context: UnsafeMutableRawPointer?, logger_fn: WireGuardLoggerCallback?) {
        pp_wg_set_logger(context, logger_fn)
    }

#if os(Windows)
    public func turnOn(settings: String, ifname: String) -> Int32 {
        pp_wg_turn_on(settings.rawString, ifname)
    }
#else
    public func turnOn(settings: String, tun_fd: Int32) -> Int32 {
        pp_wg_turn_on(settings.rawString, tun_fd)
    }
#endif

    public func socketDescriptors(_ handle: Int32) -> [Int32] {
#if os(Android)
        [pp_wg_get_socket_v4(handle), pp_wg_get_socket_v6(handle)]
#else
        []
#endif
    }

    public func turnOff(_ handle: Int32) {
        pp_wg_turn_off(handle)
    }

    public func setConfig(_ handle: Int32, settings: String) -> Int64 {
        pp_wg_set_config(handle, settings.rawString)
    }

    public func getConfig(_ handle: Int32) -> String? {
        String(unsafeCString: pp_wg_get_config(handle))
    }

    public func bumpSockets(_ handle: Int32) {
        pp_wg_bump_sockets(handle)
    }

    public func disableSomeRoamingForBrokenMobileSemantics(_ handle: Int32) {
        pp_wg_tweak_mobile_roaming(handle)
    }

    public func version() -> String? {
        String(unsafeCString: pp_wg_version())
    }
}

private extension String {
    init?(unsafeCString: UnsafePointer<CChar>?) {
        guard let unsafeCString else { return nil }
        self = String(cString: unsafeCString)
        pp_free(UnsafeMutablePointer(mutating: unsafeCString))
    }

    var rawString: [CChar]? {
        cString(using: .utf8)
    }
}
