// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import Partout

extension OpenVPN {
    static var demoModule: OpenVPNModule? {
        do {
            let parser = StandardOpenVPNParser()
            guard let url = Constants.demoURL else {
                return nil
            }
            let result = try parser.parsed(fromURL: url)
            let builder = result.configuration.builder()
            var module = OpenVPNModule.Builder(configurationBuilder: builder)
            module.credentials = Constants.demoCredentials
            return try module.tryBuild()
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
