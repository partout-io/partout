// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct ProfileModulesTests {
    @Test
    func givenModules_whenBuildProfile_thenSucceeds() {
        let sut = Profile.Builder(modules: [
            OneModule(),
            UniqueModule()
        ], activatingModules: true)
        expectNoThrow(try sut.build())
    }

    @Test
    func givenMultipleUniqueModules_whenBuildProfile_thenFails() {
        let sut = Profile.Builder(modules: [
            OneModule(),
            UniqueModule(),
            UniqueModule()
        ], activatingModules: true)
        #expect(throws: Error.self) {
            try sut.build()
        }
    }

    @Test
    func givenIntolerantModule_whenBuildProfile_thenSucceeds() {
        let sut = Profile.Builder(modules: [
            OneModule(),
            IntolerantModule()
        ], activatingModules: true)
        expectNoThrow(try sut.build())
    }

    @Test
    func givenIntolerantModule_whenBuildProfileWithIncompatibleModule_thenFails() {
        let sut = Profile.Builder(modules: [
            OneModule(),
            IntolerantModule(),
            IncompatibleModule()
        ], activatingModules: true)
        #expect(throws: Error.self) {
            try sut.build()
        }
    }

    @Test
    func givenConnectionModule_whenBuildProfileWithMultipleActiveConnectionModules_thenFails() {
        var sut = Profile.Builder(modules: [
            SomeConnectionModule(),
            SomeConnectionModule()
        ], activatingModules: false)
        expectNoThrow(try sut.build())
        sut.activeModulesIds = Set(sut.modules.map(\.id))
        #expect(throws: Error.self) {
            try sut.build()
        }
    }

    @Test
    func givenIPModule_whenBuildProfileWithActiveConnection_thenSucceeds() {
        let ipModule = IPModule.Builder().build()
        let sut = Profile.Builder(
            modules: [SomeConnectionModule(), ipModule],
            activatingModules: true
        )
        expectNoThrow(try sut.build())
    }

    @Test
    func givenIPModule_whenBuildProfileWithoutActiveConnection_thenSucceeds() {
        let ipModule = IPModule.Builder().build()
        let sut = Profile.Builder(
            modules: [ipModule],
            activatingModules: true
        )
        expectNoThrow(try sut.build())
    }

    @Test
    func givenModules_whenToggle_thenToggles() {
        let oneModule = OneModule()
        var sut = Profile.Builder(modules: [
            oneModule,
            IntolerantModule(),
            SomeConnectionModule()
        ], activatingModules: false)
        #expect(sut.activeModulesIds.isEmpty)
        sut.toggleModule(withId: oneModule.id)
        #expect(sut.activeModulesIds == [oneModule.id])
        sut.toggleModule(withId: oneModule.id)
        #expect(sut.activeModulesIds.isEmpty)
    }

    @Test
    func givenModules_whenToggleExclusive_thenTogglesExcludingOthers() {
        let oneModule = OneModule()
        let connectionModule = SomeConnectionModule()
        var sut = Profile.Builder(modules: [
            oneModule,
            IntolerantModule(),
            connectionModule
        ], activatingModules: false)
        #expect(sut.activeModulesIds.isEmpty)
        sut.toggleModule(withId: oneModule.id)
        sut.toggleModule(withId: connectionModule.id)
        #expect(sut.activeModulesIds == [oneModule.id, connectionModule.id])
        sut.toggleModule(withId: oneModule.id)
        #expect(sut.activeModulesIds == [connectionModule.id])
        sut.toggleExclusiveModule(withId: oneModule.id, excluding: \.buildsConnection)
        #expect(sut.activeModulesIds == [oneModule.id])
    }
}

private struct OneModule: Module {
    let id = UniqueID()
}

private struct UniqueModule: Module {
    let id = UniqueID()

    var isMutuallyExclusive: Bool {
        true
    }
}

private struct IntolerantModule: Module {
    let id = UniqueID()

    func checkCompatible(with otherModule: Module, activeIds: Set<UniqueID>) throws {
        guard !(otherModule is IncompatibleModule) else {
            throw PartoutError(.incompatibleModules)
        }
    }
}

private struct IncompatibleModule: Module {
    let id = UniqueID()
}

private struct SomeConnectionModule: ConnectionModule {
    let id = UniqueID()

    func newConnection(with impl: (any ModuleImplementation)?, parameters: ConnectionParameters) throws -> any Connection {
        fatalError()
    }
}
