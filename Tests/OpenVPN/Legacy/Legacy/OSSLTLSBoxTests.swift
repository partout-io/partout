// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutOpenVPNLegacy_ObjC
import XCTest

final class OSSLTLSBoxTests: XCTestCase {
    func test_givenCertificate_whenComputeMD5_thenChecksumIsCorrect() throws {
        let sut = OSSLTLSBox()
        let path = try XCTUnwrap(Bundle.module.path(forResource: "pia-2048", ofType: "pem"))
        let checksum = try sut.md5(forCertificatePath: path)
        let expected = "e2fccccaba712ccc68449b1c56427ac1"
        XCTAssertEqual(checksum, expected)
    }
}
