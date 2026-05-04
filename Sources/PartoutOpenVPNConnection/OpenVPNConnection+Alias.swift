// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !USE_CMAKE
public typealias OpenVPNConnection = _OpenVPNConnectionV1
#else
public typealias OpenVPNConnection = _OpenVPNConnectionV2
#endif
