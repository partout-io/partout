//
//  TLSWrapper.swift
//  Partout
//
//  Created by Davide De Rosa on 6/26/25.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//

import _PartoutOpenVPNCore
import Foundation

// FIXME: ###, port OSSLTLSBox (legacy) and tls.h (native)

final class TLSWrapper {
    struct Parameters {
        let cachesURL: URL

        let cfg: OpenVPN.Configuration
    }

    let tls: TLSProtocol

    init(tls: TLSProtocol) {
        self.tls = tls

//        static let defaultBufferLength = 16384
//
//        static let defaultSecurityLevel = 0
//
//        var bufferLength = Self.defaultBufferLength
//
//        guard let ca = configuration.ca else {
//            fatalError("Configuration has no CA")
//        }
//        caURL = cachesURL.appendingPathComponent(Caches.ca)
//        try ca.write(to: caURL)
//
//        tlsOptions = OpenVPNTLSOptions(
//            bufferLength: OpenVPNTLSOptionsDefaultBufferLength,
//            caURL: caURL,
//            clientCertificatePEM: configuration.clientCertificate?.pem,
//            clientKeyPEM: configuration.clientKey?.pem,
//            checksEKU: configuration.checksEKU ?? false,
//            checksSANHost: configuration.checksSANHost ?? false,
//            hostname: configuration.sanHost,
//            securityLevel: configuration.tlsSecurityLevel ?? 0
//        )
//            guard let caURL = tls.options()?.caURL() else {
//                return nil
//            }
//            let caMD5 = try tls.md5(forCertificatePath: caURL.path)
    }

//    deinit {
//        try? FileManager.default.removeItem(at: caURL)
//    }
}
