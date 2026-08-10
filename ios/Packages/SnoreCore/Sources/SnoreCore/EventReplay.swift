import Foundation

/// Crash-recovery replay (spec §3.1): re-merge orphan `event` rows into
/// episodes using the same merge/confirm rules as the live detector.
/// Deterministic; kept in lockstep with `replay_events` in
/// spec/reference/detector.py and the Kotlin port.
public enum EventReplay {

    /// A persisted event row (episode_id NULL) read back from the database.
    public struct OrphanEvent: Equatable, Sendable {
        public var startMs: Int64
        public var endMs: Int64
        public var peakDbfs: Double
        public var maxConf: Double
        public var nfDbfs: Double

        public init(startMs: Int64, endMs: Int64, peakDbfs: Double,
                    maxConf: Double, nfDbfs: Double) {
            self.startMs = startMs
            self.endMs = endMs
            self.peakDbfs = peakDbfs
            self.maxConf = maxConf
            self.nfDbfs = nfDbfs
        }
    }

    public struct ReplayedEpisode: Equatable, Sendable {
        public var startMs: Int64
        public var endMs: Int64
        public var events: [OrphanEvent]
        public var snoreMs: Int64
        public var peak: OrphanEvent
        public var bucket: IntensityBucket
    }

    public struct Result: Equatable, Sendable {
        public var episodes: [ReplayedEpisode]
        public var discardedGroups: Int
    }

    public static func replay(_ rows: [OrphanEvent], params: DetectorParams) -> Result {
        var episodes: [ReplayedEpisode] = []
        var discarded = 0
        var group: [OrphanEvent] = []

        func resolve() {
            guard !group.isEmpty else { return }
            defer { group = [] }
            let span = group.last!.endMs - group.first!.startMs
            guard group.count >= params.minEpisodeEvents,
                  span >= params.minEpisodeSpanMs else {
                discarded += 1
                return
            }
            var peak = group[0]
            for e in group.dropFirst() where e.peakDbfs > peak.peakDbfs {
                peak = e
            }
            let rel = peak.peakDbfs - peak.nfDbfs
            let bucket: IntensityBucket = rel < params.intensityLightMaxDb ? .light
                : rel < params.intensityModMaxDb ? .moderate : .loud
            episodes.append(ReplayedEpisode(
                startMs: group.first!.startMs,
                endMs: group.last!.endMs,
                events: group,
                snoreMs: group.reduce(0) { $0 + ($1.endMs - $1.startMs) },
                peak: peak,
                bucket: bucket))
        }

        for row in rows.sorted(by: { $0.startMs < $1.startMs }) {
            if let last = group.last, row.startMs - last.endMs > params.mergeGapMs {
                resolve()
            }
            group.append(row)
        }
        resolve()
        return Result(episodes: episodes, discardedGroups: discarded)
    }
}
