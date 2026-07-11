import Synchronization

/// Lock-free single-producer/single-consumer float ring. The IOProc writes,
/// the drain queue reads. Overflow drops the incoming samples (never blocks).
final class AudioRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let head = Atomic<Int>(0)   // total samples written
    private let tail = Atomic<Int>(0)   // total samples read

    init(capacity: Int) {
        var c = 1
        while c < capacity { c <<= 1 }
        self.capacity = c
        self.storage = .allocate(capacity: c)
        storage.initialize(repeating: 0, count: c)
    }

    deinit {
        storage.deallocate()
    }

    /// Realtime-safe: memcpy + one atomic store. Drops if the ring is full.
    func write(_ src: UnsafePointer<Float>, count: Int) {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        guard h - t + count <= capacity else { return }   // overflow: drop
        let start = h & (capacity - 1)
        let firstRun = min(count, capacity - start)
        (storage + start).update(from: src, count: firstRun)
        if firstRun < count {
            storage.update(from: src + firstRun, count: count - firstRun)
        }
        head.store(h + count, ordering: .releasing)
    }

    /// Reads up to `max` samples into `dst`, returns the count read.
    func read(into dst: UnsafeMutablePointer<Float>, max: Int) -> Int {
        let h = head.load(ordering: .acquiring)
        let t = tail.load(ordering: .relaxed)
        let available = min(h - t, max)
        guard available > 0 else { return 0 }
        let start = t & (capacity - 1)
        let firstRun = min(available, capacity - start)
        dst.update(from: storage + start, count: firstRun)
        if firstRun < available {
            (dst + firstRun).update(from: storage, count: available - firstRun)
        }
        tail.store(t + available, ordering: .releasing)
        return available
    }
}
