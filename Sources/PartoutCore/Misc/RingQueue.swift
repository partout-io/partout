// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

struct RingQueue<Element> {
    private enum Slot {
        case empty
        case element(Element)
    }

    private var storage: [Slot]

    private var head: Int

    private(set) var count: Int

    init(minimumCapacity: Int = 0) {
        precondition(minimumCapacity >= 0, "minimumCapacity must be non-negative")
        storage = Array(repeating: .empty, count: minimumCapacity)
        head = 0
        count = 0
    }

    var isEmpty: Bool {
        count == 0
    }

    var first: Element? {
        guard !isEmpty else {
            return nil
        }
        switch storage[head] {
        case .empty:
            return nil
        case .element(let element):
            return element
        }
    }

    mutating func append(_ element: Element) {
        reserveCapacity(count + 1)
        storage[index(offsetBy: count)] = .element(element)
        count += 1
    }

    @discardableResult
    mutating func removeFirst() -> Element? {
        guard !isEmpty else {
            return nil
        }
        let element = first
        storage[head] = .empty
        count -= 1
        if isEmpty {
            head = 0
        } else {
            head = index(offsetBy: 1)
        }
        return element
    }

    @discardableResult
    mutating func replaceFirst(with element: Element) -> Bool {
        guard !isEmpty else {
            return false
        }
        storage[head] = .element(element)
        return true
    }

    mutating func removeAll(keepingCapacity: Bool = false) {
        if keepingCapacity {
            storage = Array(repeating: .empty, count: storage.count)
        } else {
            storage.removeAll(keepingCapacity: false)
        }
        head = 0
        count = 0
    }
}

private extension RingQueue {
    mutating func reserveCapacity(_ minimumCapacity: Int) {
        guard storage.count < minimumCapacity else {
            return
        }
        var newCapacity = max(1, storage.count * 2)
        while newCapacity < minimumCapacity {
            newCapacity *= 2
        }
        var newStorage = Array(repeating: Slot.empty, count: newCapacity)
        for offset in 0..<count {
            newStorage[offset] = storage[index(offsetBy: offset)]
        }
        storage = newStorage
        head = 0
    }

    func index(offsetBy offset: Int) -> Int {
        (head + offset) % storage.count
    }
}
