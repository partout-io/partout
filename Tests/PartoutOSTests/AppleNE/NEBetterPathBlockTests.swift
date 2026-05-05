// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutOS
import Testing

struct NEBetterPathBlockTests {
    @Test
    func givenUnsatisfiedPath_whenPathBecomesSatisfied_thenIsBetter() {
        let oldPath = NWPathBetterPathPreference(
            statusScore: 0,
            isUnconstrained: true,
            isInexpensive: true,
            interfaceScore: 5
        )
        let newPath = NWPathBetterPathPreference(
            statusScore: 2,
            isUnconstrained: false,
            isInexpensive: false,
            interfaceScore: 1
        )

        #expect(newPath.isBetter(than: oldPath))
    }

    @Test
    func givenConstrainedPath_whenPathBecomesUnconstrained_thenIsBetter() {
        let oldPath = NWPathBetterPathPreference(
            statusScore: 2,
            isUnconstrained: false,
            isInexpensive: true,
            interfaceScore: 4
        )
        let newPath = NWPathBetterPathPreference(
            statusScore: 2,
            isUnconstrained: true,
            isInexpensive: true,
            interfaceScore: 4
        )

        #expect(newPath.isBetter(than: oldPath))
    }

    @Test
    func givenExpensivePath_whenPathBecomesInexpensive_thenIsBetter() {
        let oldPath = NWPathBetterPathPreference(
            statusScore: 2,
            isUnconstrained: true,
            isInexpensive: false,
            interfaceScore: 4
        )
        let newPath = NWPathBetterPathPreference(
            statusScore: 2,
            isUnconstrained: true,
            isInexpensive: true,
            interfaceScore: 4
        )

        #expect(newPath.isBetter(than: oldPath))
    }

    @Test
    func givenEquivalentPath_whenOnlyInterfaceIsWorse_thenIsNotBetter() {
        let oldPath = NWPathBetterPathPreference(
            statusScore: 2,
            isUnconstrained: true,
            isInexpensive: true,
            interfaceScore: 4
        )
        let newPath = NWPathBetterPathPreference(
            statusScore: 2,
            isUnconstrained: true,
            isInexpensive: true,
            interfaceScore: 3
        )

        #expect(!newPath.isBetter(than: oldPath))
    }
}
