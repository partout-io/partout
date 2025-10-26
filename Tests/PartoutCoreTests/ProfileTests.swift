// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct ProfileTests {
    @Test
    func givenProfile_whenCopy_thenIsNotSameObject() {
        var p1 = Profile.Builder()
        p1.name = "One"

        var p2 = p1
        #expect(p1 == p2)
        p2.name = "Two"
        #expect(p1 != p2)
    }

    @Test
    func givenProfile_whenCopy_thenHasNotSameModules() throws {
        var p1 = Profile.Builder()
        let m1 = DNSModule.Builder()
        p1.name = "One"
        p1.modules = [try m1.build()]

        var p2 = p1
        #expect(p1 == p2)
        p2.name = "Two"
        #expect(p1 != p2)

        var m2 = m1
        #expect(m1 == m2)
        m2.protocolType = .tls
        m2.dotHostname = "some.com"
        #expect(m1 != m2)

        p2.modules = [try m2.build()]
        #expect(p1 != p2)
        #expect(m1 != m2)
    }

    @Test
    func givenProfile_whenRebuild_thenIsEqual() throws {
        var pb1 = Profile.Builder()
        pb1.name = "One"
        let p1 = try pb1.build()

        let pb2 = p1.builder()
        let p2 = try pb2.build()
        #expect(pb1 == pb2)
        #expect(p1 == p2)
    }

    @Test
    func givenProfile_whenRebuildWithNewId_thenIsNotEqual() throws {
        var pb1 = Profile.Builder()
        pb1.name = "One"
        let p1 = try pb1.build()

        let pb2 = p1.builder(withNewId: true)
        let p2 = try pb2.build()
        #expect(pb1 != pb2)
        #expect(p1 != p2)
    }

    @Test
    func givenProfile_whenBuild_thenDisconnectsOnSleepIsDisabled() throws {
        let pb = Profile.Builder()
        let sut = try pb.build()
        #expect(!sut.disconnectsOnSleep)
    }

    @Test
    func givenProfileWithBehavior_whenBuild_thenAppliesBehavior() throws {
        var pb = Profile.Builder()
        pb.behavior = ProfileBehavior()
        #expect(!(try pb.build().disconnectsOnSleep))
        pb.behavior?.disconnectsOnSleep = true
        #expect(try pb.build().disconnectsOnSleep)
    }
}
