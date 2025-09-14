// SPDX-License-Identifier: MIT
// Copyright © 2018-2024 WireGuard LLC. All Rights Reserved.

public typealias WireGuardLoggerCallback = @convention(c) (_ context: UnsafeMutableRawPointer?, _ level: Int32, _ msg: UnsafePointer<Int8>?) -> Void

public protocol WireGuardBackend: AnyObject, Sendable {
    func setLogger(context: UnsafeMutableRawPointer?, logger_fn: WireGuardLoggerCallback?)

#if os(Windows)
    func turnOn(settings: String, ifname: String) -> Int32
#else
    func turnOn(settings: String, tun_fd: Int32) -> Int32
#endif

    func socketDescriptors(_ handle: Int32) -> [Int32]

    func turnOff(_ handle: Int32)

    @discardableResult
    func setConfig(_ handle: Int32, settings: String) -> Int64

    func getConfig(_ handle: Int32) -> String?

    func bumpSockets(_ handle: Int32)

    func disableSomeRoamingForBrokenMobileSemantics(_ handle: Int32)

    func version() -> String?
}
