// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

struct Handshake {
    let preMaster: CrossZD

    let random1: CrossZD

    let random2: CrossZD

    let serverRandom1: CrossZD

    let serverRandom2: CrossZD
}
