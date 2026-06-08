// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if os(Windows)
public typealias FileDescriptor = UInt64
#else
public typealias FileDescriptor = Int32
#endif
