// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_MONOLITH
internal import PartoutPortable
#endif

struct Handshake {
    let preMaster: CZeroingData

    let random1: CZeroingData

    let random2: CZeroingData

    let serverRandom1: CZeroingData

    let serverRandom2: CZeroingData
}
