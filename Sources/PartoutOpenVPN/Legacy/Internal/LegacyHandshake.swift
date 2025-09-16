// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

struct LegacyHandshake {
    let preMaster: LegacyZD

    let random1: LegacyZD

    let random2: LegacyZD

    let serverRandom1: LegacyZD

    let serverRandom2: LegacyZD
}
