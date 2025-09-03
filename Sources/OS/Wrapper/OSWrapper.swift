// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_MONOLITH

@_exported import _PartoutOSPortable

#if canImport(_PartoutOSAndroid)
@_exported import _PartoutOSAndroid
#endif

#if canImport(_PartoutOSApple)
@_exported import _PartoutOSApple
@_exported import _PartoutOSAppleNE
#endif

#if canImport(_PartoutOSLinux)
@_exported import _PartoutOSLinux
#endif

#if canImport(_PartoutOSWindows)
@_exported import _PartoutOSWindows
#endif

#endif
