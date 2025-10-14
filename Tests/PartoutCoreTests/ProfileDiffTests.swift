// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct ProfileDiffTests {
    @Test
    func givenProfile_whenChangeBaseFields_thenDiffIsExpected() throws {
        var sut = Profile.Builder()
        sut.name = "original"
        let original = try sut.tryBuild()
        #expect(original.name == "original")

        sut.name = "newname"
        #expect(try sut.tryBuild().differences(from: original) == [
            .changedName
        ])

        var behavior = ProfileBehavior()
        behavior.disconnectsOnSleep = true
        sut.behavior = behavior
        #expect(try sut.tryBuild().differences(from: original) == [
            .changedName,
            .changedBehavior
        ])
        sut.name = "original"
        #expect(try sut.tryBuild().differences(from: original) == [
            .changedBehavior
        ])
    }

    @Test
    func givenProfile_whenChangeModules_thenDiffIsExpected() throws {
        var sut = Profile.Builder()
        let original = try sut.tryBuild()
        #expect(original.modules.isEmpty)

        var diff: Set<Profile.DiffResult>

        let dnsModule = try DNSModule.Builder().tryBuild()
        sut.modules = [dnsModule]
        let profileWithDNS = try sut.tryBuild()
        diff = profileWithDNS.differences(from: original)
        print(diff)
        #expect(diff == [
            .addedModules([dnsModule.id])
        ])

        sut.modules = []
        let profileWithoutDNS = try sut.tryBuild()
        diff = profileWithoutDNS.differences(from: original)
        print(diff)
        #expect(diff.isEmpty)
        diff = profileWithoutDNS.differences(from: profileWithDNS)
        print(diff)
        #expect(diff == [
            .removedModules([dnsModule.id])
        ])

        sut.activeModulesIds = [dnsModule.id]
        diff = try sut.tryBuild().differences(from: original)
        print(diff)
        #expect(diff.isEmpty)

        sut.modules = [dnsModule]
        diff = try sut.tryBuild().differences(from: original)
        print(diff)
        #expect(diff == [
            .addedModules([dnsModule.id]),
            .changedActiveModules
        ])

        sut.modules = [] // also clears stale ID in activeModulesIds
        diff = try sut.tryBuild().differences(from: original)
        print(diff)
        #expect(diff.isEmpty)
    }
}
