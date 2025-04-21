//
//  StaticKeyTests.swift
//  Partout
//
//  Created by Davide De Rosa on 9/11/18.
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

@testable import _PartoutOpenVPN
import PartoutCore
import XCTest

final class StaticKeyTests: XCTestCase {
    func test_givenHex_whenBidirectional_thenSameSendReceiveKey() {
        let expected = Data(hex: "cf55d863fcbe314df5f0b45dbe974d9bde33ef5b4803c3985531c6c23ca6906d6cd028efc8585d1b9e71003566bd7891b9cc9212bcba510109922eed87f5c8e6")
        let key = OpenVPN.StaticKey(file: content, direction: nil)
        XCTAssertNotNil(key)

        XCTAssertEqual(key?.hmacSendKey, SecureData(expected))
        XCTAssertEqual(key?.hmacReceiveKey, SecureData(expected))
    }

    func test_givenHex_whenClient_thenKeysAreExpected() {
        let send = Data(hex: "778a6b35a124e700920879f1d003ba93dccdb953cdf32bea03f365760b0ed8002098d4ce20d045b45a83a8432cc737677aed27125592a7148d25c87fdbe0a3f6")
        let receive = Data(hex: "cf55d863fcbe314df5f0b45dbe974d9bde33ef5b4803c3985531c6c23ca6906d6cd028efc8585d1b9e71003566bd7891b9cc9212bcba510109922eed87f5c8e6")
        let key = OpenVPN.StaticKey(file: content, direction: .client)
        XCTAssertNotNil(key)

        XCTAssertEqual(key?.hmacSendKey, SecureData(send))
        XCTAssertEqual(key?.hmacReceiveKey, SecureData(receive))
    }
}

// MARK: - Helpers

private extension StaticKeyTests {
    var content: String {
"""
#
# 2048 bit OpenVPN static key
#
-----BEGIN OpenVPN Static key V1-----
48d9999bd71095b10649c7cb471c1051
b1afdece597cea06909b99303a18c674
01597b12c04a787e98cdb619ee960d90
a0165529dc650f3a5c6fbe77c91c137d
cf55d863fcbe314df5f0b45dbe974d9b
de33ef5b4803c3985531c6c23ca6906d
6cd028efc8585d1b9e71003566bd7891
b9cc9212bcba510109922eed87f5c8e6
6d8e59cbd82575261f02777372b2cd4c
a5214c4a6513ff26dd568f574fd40d6c
d450fc788160ff68434ce2bf6afb00e7
10a3198538f14c4d45d84ab42637872e
778a6b35a124e700920879f1d003ba93
dccdb953cdf32bea03f365760b0ed800
2098d4ce20d045b45a83a8432cc73767
7aed27125592a7148d25c87fdbe0a3f6
-----END OpenVPN Static key V1-----
"""
    }
}
