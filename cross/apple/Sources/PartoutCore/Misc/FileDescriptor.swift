// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// A native handle for a file descriptor.
public typealias FileDescriptor = Int32
/// A native handle for a socket descriptor.
public typealias SocketDescriptor = FileDescriptor
