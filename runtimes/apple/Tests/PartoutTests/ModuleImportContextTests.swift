// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutCore
import Testing

struct ModuleImportContextTests {
    @Test
    func openVPNContextRoundTrip() throws {
        let sut = ModuleImportContext.OpenVPN(passphrase: "secret")

        let data = try JSONEncoder.shared().encode(sut)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json == ["type": "OpenVPN", "passphrase": "secret"])
        #expect(try JSONDecoder.shared().decode(ModuleImportContext.self, from: data) == sut)
    }

    @Test
    func wireGuardContextRoundTrip() throws {
        let sut = ModuleImportContext.WireGuard

        let data = try JSONEncoder.shared().encode(sut)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json == ["type": "WireGuard"])
        #expect(try JSONDecoder.shared().decode(ModuleImportContext.self, from: data) == sut)
    }
}
