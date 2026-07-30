// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct RingQueueTests {
    @Test
    func givenEmptyQueue_whenRemovingFirst_thenReturnsNil() {
        var sut = RingQueue<Int>()

        #expect(sut.isEmpty)
        #expect(sut.count == 0)
        #expect(sut.first == nil)
        #expect(sut.removeFirst() == nil)
    }

    @Test
    func givenQueue_whenAppendingAndRemoving_thenPreservesFIFOOrder() {
        var sut = RingQueue<Int>()

        sut.append(1)
        sut.append(2)
        sut.append(3)

        #expect(sut.count == 3)
        #expect(sut.first == 1)
        #expect(sut.removeFirst() == 1)
        #expect(sut.removeFirst() == 2)

        sut.append(4)
        sut.append(5)

        #expect(sut.removeFirst() == 3)
        #expect(sut.removeFirst() == 4)
        #expect(sut.removeFirst() == 5)
        #expect(sut.isEmpty)
    }

    @Test
    func givenQueue_whenReplacingFirst_thenOnlyHeadChanges() {
        var sut = RingQueue<Int>()

        sut.append(1)
        sut.append(2)

        let didReplaceFirst = sut.replaceFirst(with: 10)
        #expect(didReplaceFirst)
        #expect(sut.removeFirst() == 10)
        #expect(sut.removeFirst() == 2)
        let didReplaceEmptyFirst = sut.replaceFirst(with: 20)
        #expect(!didReplaceEmptyFirst)
    }

    @Test
    func givenQueue_whenRemovingAll_thenDropsElements() {
        var sut = RingQueue<Int>()

        sut.append(1)
        sut.append(2)
        sut.removeAll(keepingCapacity: true)

        #expect(sut.isEmpty)
        #expect(sut.first == nil)
        sut.append(3)
        #expect(sut.removeFirst() == 3)
    }
}
