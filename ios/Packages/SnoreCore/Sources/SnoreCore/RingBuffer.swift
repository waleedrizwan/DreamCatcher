import Foundation

/// Fixed-capacity PCM ring buffer (spec §4): holds the last N samples of the
/// 16 kHz mono Int16 stream so a clip can be cut with pre-roll when an
/// episode confirms. Raw audio outside this buffer never exists off the
/// audio path. Single-writer; snapshots are cheap copies.
public final class PCMRingBuffer {
    private var storage: [Int16]
    private let capacity: Int
    /// Total samples ever written; sample index `totalWritten - capacity`
    /// (clamped to 0) is the oldest still available.
    public private(set) var totalWritten: Int64 = 0

    public init(capacitySamples: Int) {
        precondition(capacitySamples > 0)
        capacity = capacitySamples
        storage = [Int16](repeating: 0, count: capacitySamples)
    }

    public convenience init(seconds: Double, sampleRate: Int = 16_000) {
        self.init(capacitySamples: Int(seconds * Double(sampleRate)))
    }

    public var oldestAvailableIndex: Int64 { max(0, totalWritten - Int64(capacity)) }

    public func write(_ samples: [Int16]) {
        for s in samples {
            storage[Int(totalWritten % Int64(capacity))] = s
            totalWritten += 1
        }
    }

    /// Copy absolute sample range [from, to). Returns nil if any of it has
    /// already been overwritten or hasn't been written yet.
    public func snapshot(from: Int64, to: Int64) -> [Int16]? {
        guard from >= oldestAvailableIndex, to <= totalWritten, from < to else {
            return nil
        }
        var out = [Int16]()
        out.reserveCapacity(Int(to - from))
        for i in from..<to {
            out.append(storage[Int(i % Int64(capacity))])
        }
        return out
    }

    /// Convenience for clip capture: the latest `count` samples ending at the
    /// current write position, clamped to what is actually available.
    public func latest(_ count: Int) -> [Int16] {
        let from = max(oldestAvailableIndex, totalWritten - Int64(count))
        return snapshot(from: from, to: totalWritten) ?? []
    }
}
