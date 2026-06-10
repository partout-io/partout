// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct ProfileDiffTests {
    @Test
    func givenProfile_whenChangeBaseFields_thenDiffIsExpected() throws {
        var sut = Profile.Builder()
        sut.name = "original"
        let original = try sut.build()
        #expect(original.name == "original")

        sut.name = "newname"
        #expect(try sut.build().differences(from: original) == [
            .changedName
        ])

        var behavior = ProfileBehavior()
        behavior.disconnectsOnSleep = true
        sut.behavior = behavior
        #expect(try sut.build().differences(from: original) == [
            .changedName,
            .changedBehavior([.disconnectsOnSleep])
        ])
        sut.name = "original"
        #expect(try sut.build().differences(from: original) == [
            .changedBehavior([.disconnectsOnSleep])
        ])
    }

    @Test
    func givenProfile_whenChangeModules_thenDiffIsExpected() throws {
        var sut = Profile.Builder()
        let original = try sut.build()
        #expect(original.modules.isEmpty)

        var diff: Set<Profile.DiffResult>

        let dnsModule = try DNSModule.Builder(servers: ["6.6.6.6"]).build()
        sut.modules = [dnsModule]
        let profileWithDNS = try sut.build()
        diff = profileWithDNS.differences(from: original)
        #expect(diff == [
            .addedModules([dnsModule.id])
        ])

        sut.modules = []
        let profileWithoutDNS = try sut.build()
        diff = profileWithoutDNS.differences(from: original)
        #expect(diff.isEmpty)
        diff = profileWithoutDNS.differences(from: profileWithDNS)
        #expect(diff == [
            .removedModules([dnsModule.id])
        ])

        sut.activeModulesIds = [dnsModule.id]
        diff = try sut.build().differences(from: original)
        #expect(diff.isEmpty)

        sut.modules = [dnsModule]
        diff = try sut.build().differences(from: original)
        #expect(diff == [
            .addedModules([dnsModule.id]),
            .changedActiveModules,
            .enabledModules([dnsModule.id])
        ])

        sut.modules = [] // also clears stale ID in activeModulesIds
        diff = try sut.build().differences(from: original)
        #expect(diff.isEmpty)
    }

    @Test
    func givenInactiveModule_whenEnableModule_thenDiffIsExpected() throws {
        let dnsModule = try DNSModule.Builder(servers: ["6.6.6.6"]).build()
        let original = try Profile.Builder(
            modules: [dnsModule],
            activatingModules: false
        ).build()

        var sut = original.builder()
        sut.activeModulesIds = [dnsModule.id]

        #expect(try sut.build().differences(from: original) == [
            .changedActiveModules,
            .enabledModules([dnsModule.id])
        ])
    }

    @Test
    func givenActiveModule_whenDisableModule_thenDiffIsExpected() throws {
        let dnsModule = try DNSModule.Builder(servers: ["6.6.6.6"]).build()
        let original = try Profile.Builder(
            modules: [dnsModule],
            activatingModules: true
        ).build()

        var sut = original.builder()
        sut.activeModulesIds = []

        #expect(try sut.build().differences(from: original) == [
            .changedActiveModules,
            .disabledModules([dnsModule.id])
        ])
    }

    @Test
    func givenActiveModule_whenRemoveModule_thenDiffIsExpected() throws {
        let dnsModule = try DNSModule.Builder(servers: ["6.6.6.6"]).build()
        let original = try Profile.Builder(
            modules: [dnsModule],
            activatingModules: true
        ).build()

        var sut = original.builder()
        sut.modules = []

        #expect(try sut.build().differences(from: original) == [
            .changedActiveModules,
            .removedModules([dnsModule.id]),
            .disabledModules([dnsModule.id])
        ])
    }

    @Test
    func givenActiveModules_whenSwapEnabledModule_thenDiffIsExpected() throws {
        let dnsModule = try DNSModule.Builder(servers: ["6.6.6.6"]).build()
        let proxyModule = try HTTPProxyModule.Builder(address: "1.1.1.1", port: 1080).build()
        let original = try Profile.Builder(
            modules: [dnsModule, proxyModule],
            activeModulesIds: [dnsModule.id]
        ).build()

        var sut = original.builder()
        sut.activeModulesIds = [proxyModule.id]

        #expect(try sut.build().differences(from: original) == [
            .changedActiveModules,
            .enabledModules([proxyModule.id]),
            .disabledModules([dnsModule.id])
        ])
    }
}
