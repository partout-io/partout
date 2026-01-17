// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

internal import _PartoutCore_C
internal import _PartoutWireGuardConnection_C

/// A enum describing WireGuard log levels defined in `api-apple.go`.
enum WireGuardLogLevel: Int32 {
    case verbose = 0
    case error = 1
}

final class WireGuardBackend: @unchecked Sendable {
    typealias LoggerCallback = @convention(c) (_ context: UnsafeMutableRawPointer?, _ level: Int32, _ msg: UnsafePointer<Int8>?) -> Void

    init() {
        guard pp_wg_init() == 0 else {
            fatalError("Unable to load wg-go backend")
        }
    }

    func setLogger(context: UnsafeMutableRawPointer?, logger_fn: LoggerCallback?) {
        pp_wg_set_logger(context, logger_fn)
    }

#if os(Windows)
    func turnOn(settings: String, ifname: String) -> Int32 {
        pp_wg_turn_on(settings.rawString, ifname)
    }
#else
    func turnOn(settings: String, tun_fd: Int32) -> Int32 {
        pp_wg_turn_on(settings.rawString, tun_fd)
    }
#endif

    func socketDescriptors(_ handle: Int32) -> [Int32] {
#if os(Android)
        [pp_wg_get_socket_v4(handle), pp_wg_get_socket_v6(handle)]
#else
        []
#endif
    }

    func turnOff(_ handle: Int32) {
        pp_wg_turn_off(handle)
    }

    @discardableResult
    func setConfig(_ handle: Int32, settings: String) -> Int64 {
        pp_wg_set_config(handle, settings.rawString)
    }

    func getConfig(_ handle: Int32) -> String? {
        String(unsafeCString: pp_wg_get_config(handle))
    }

    func bumpSockets(_ handle: Int32) {
        pp_wg_bump_sockets(handle)
    }

    func disableSomeRoamingForBrokenMobileSemantics(_ handle: Int32) {
        pp_wg_tweak_mobile_roaming(handle)
    }

    func version() -> String? {
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
