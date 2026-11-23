// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore
import Testing

struct PartoutCoreTests {

    @Test
    func givenCore_whenCreateProfileBuilder_thenWorks() {
        var profile = Profile.Builder(activatingModules: true)
        profile.name = "foobar"
        #expect(profile.name == "foobar")
    }
}
