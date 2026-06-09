// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if os(Windows)
/// A native handle for a file descriptor.
public typealias FileDescriptor = HANDLE
public typealias SocketDescriptor = SOCKET
#else
/// A native handle for a file descriptor.
public typealias FileDescriptor = Int32
public typealias SocketDescriptor = FileDescriptor
#endif
