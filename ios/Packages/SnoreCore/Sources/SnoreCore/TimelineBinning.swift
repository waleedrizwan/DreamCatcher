import Foundation

/// Timeline binning (spec §2.3): 5-minute bins computed on demand from event
/// intervals — never stored. Bin color = highest-severity bucket among
/// overlapping events; capture gaps are rendered separately by the UI layer.
public enum TimelineBinning {

    public static let binMs: Int64 = 300_000

    public struct EventInterval: Equatable, Sendable {
        public var startMs: Int64
        public var endMs: Int64
        public var bucket: IntensityBucket

        public init(startMs: Int64, endMs: Int64, bucket: IntensityBucket) {
            self.startMs = startMs
            self.endMs = endMs
            self.bucket = bucket
        }
    }

    public struct Bin: Equatable, Sendable {
        public var index: Int
        /// Seconds of event-time overlapping this bin, 0...300.
        public var snoreSeconds: Double
        /// nil when no event overlaps (renders as baseline).
        public var bucket: IntensityBucket?
    }

    public static func bins(sessionStartMs: Int64, sessionEndMs: Int64,
                            events: [EventInterval]) -> [Bin] {
        guard sessionEndMs > sessionStartMs else { return [] }
        let span = sessionEndMs - sessionStartMs
        let count = Int((span + binMs - 1) / binMs)
        var result = (0..<count).map { Bin(index: $0, snoreSeconds: 0, bucket: nil) }
        for ev in events {
            let firstBin = max(0, Int((ev.startMs - sessionStartMs) / binMs))
            let lastBin = min(count - 1, Int((ev.endMs - 1 - sessionStartMs) / binMs))
            guard firstBin <= lastBin else { continue }
            for i in firstBin...lastBin {
                let binStart = sessionStartMs + Int64(i) * binMs
                let overlap = min(ev.endMs, binStart + binMs) - max(ev.startMs, binStart)
                guard overlap > 0 else { continue }
                result[i].snoreSeconds += Double(overlap) / 1000.0
                result[i].bucket = maxSeverity(result[i].bucket, ev.bucket)
            }
        }
        return result
    }

    static func maxSeverity(_ a: IntensityBucket?, _ b: IntensityBucket) -> IntensityBucket {
        guard let a else { return b }
        return rank(a) >= rank(b) ? a : b
    }

    private static func rank(_ b: IntensityBucket) -> Int {
        switch b {
        case .light: return 0
        case .moderate: return 1
        case .loud: return 2
        }
    }
}
