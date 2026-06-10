// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Represents a specific I/O interface meant to work at a L3 virtual tun layer.
public protocol TunInterface: IOInterface {
    var ioDescriptor: Any? { get }
}
