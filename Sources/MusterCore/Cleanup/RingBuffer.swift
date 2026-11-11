import Foundation

/// 定长环形缓冲：写满后覆盖最旧元素，内存占用上限固定。
public struct RingBuffer<Element> {
    public let capacity: Int
    private var storage: [Element] = []
    private var head = 0

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    public var count: Int { storage.count }
    public var last: Element? {
        guard !storage.isEmpty else { return nil }
        return storage[(head + storage.count - 1) % storage.count]
    }

    public mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    /// 从旧到新
    public var elements: [Element] {
        guard storage.count == capacity, head != 0 else { return storage }
        return Array(storage[head...] + storage[..<head])
    }
}
