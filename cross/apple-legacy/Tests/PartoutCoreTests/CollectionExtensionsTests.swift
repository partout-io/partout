// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Testing

struct CollectionExtensionsTests {
    @Test
    func givenType_whenFirstOf_thenReturnsFirstOfGivenType() {
        let one = TypeOne()
        let two = TypeTwo()
        let three = TypeThree()
        let sut: [BaseType] = [
            one,
            two,
            three
        ]
        #expect(sut.first(ofType: TypeOne.self) != nil)
        #expect(sut.first(ofType: TypeTwo.self) != nil)
        #expect(sut.first(ofType: TypeThree.self) != nil)
        #expect(sut.first(ofType: Int.self) == nil)

        #expect(sut.first(ofType: TypeOne.self) === one)
        #expect(sut.first(ofType: TypeTwo.self) === two)
        #expect(sut.first(ofType: TypeThree.self) === three)
    }

    @Test
    func givenCollection_whenUnique_thenReturnsWithUniqueElements() {
        #expect([1, 2, 5, 8, 0, 1, 1, 5, 8, 18].unique() == [1, 2, 5, 8, 0, 18])
        #expect(["only"].unique() == ["only"])
        #expect([Int]().unique() == [])
    }
}

private protocol BaseType {}

private final class TypeOne: BaseType {}

private final class TypeTwo: BaseType {}

private final class TypeThree: BaseType {}
