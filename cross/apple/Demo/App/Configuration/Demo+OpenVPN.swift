// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutRuntime

extension OpenVPN {
    static var demoModule: OpenVPNModule? {
        do {
            guard let url = Constants.demoURL else { return nil }
            guard let module = try PartoutImporter().importModule(
                OpenVPNModule.self,
                url: url
            ) else { return nil }
            var builder = module.builder()
            builder.credentials = Constants.demoCredentials
            return try builder.build()
        } catch {
            fatalError("Unable to build: \(error)")
        }
    }
}

private enum Constants {
    static let demoURL = Bundle.main.url(forResource: "Files/test-sample", withExtension: "ovpn")

    static let demoCredentials: OpenVPN.Credentials = {
        var builder = OpenVPN.Credentials.Builder()
        if let url = Bundle.main.url(forResource: "Files/test-sample", withExtension: "txt"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            let lines = content.split(separator: "\n")
            if lines.count == 2 {
                builder.username = String(lines[0])
                builder.password = String(lines[1])
            }
        }
        return builder.build()
    }()
}
