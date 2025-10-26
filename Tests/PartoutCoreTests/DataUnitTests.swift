// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore
import Testing

struct DataUnitTests {
    @Test
    func givenInt_whenDescribedAsDataUnit_thenDescriptionIsExpected() {
        #expect(0.descriptionAsDataUnit == "0B")
        #expect(1.descriptionAsDataUnit == "1B")
        #expect(1023.descriptionAsDataUnit == "1023B")
        #expect(1024.descriptionAsDataUnit == "1kB")
        #expect(1025.descriptionAsDataUnit == "1kB")
        #expect(548575.descriptionAsDataUnit == "0.52MB")
        #expect(1048575.descriptionAsDataUnit == "1.00MB")
        #expect(1048576.descriptionAsDataUnit == "1.00MB")
        #expect(1048577.descriptionAsDataUnit == "1.00MB")
        #expect(600000000.descriptionAsDataUnit == "0.56GB")
        #expect(1073741823.descriptionAsDataUnit == "1.00GB")
        #expect(1073741824.descriptionAsDataUnit == "1.00GB")
        #expect(1073741825.descriptionAsDataUnit == "1.00GB")
    }
}
