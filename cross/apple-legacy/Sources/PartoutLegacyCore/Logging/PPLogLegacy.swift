// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@c(partout_log)
public func partout_log(cLevel: Int, cMessage: UnsafePointer<CChar>?) {
    guard let cMessage else { return }
#if !os(Windows)
    let savedErrno = errno
#endif
    let level = DebugLog.Level(rawValue: cLevel) ?? .info
    let message = String(cString: cMessage)
    pp_log_g(.abi, level, message)
#if !os(Windows)
    errno = savedErrno
#endif
}
