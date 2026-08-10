import Foundation

/// Session rollups (spec §2): derived ONLY from confirmed episodes and their
/// events. Written to the session row at finalize; debug builds assert the
/// stored rollups equal a fresh recompute on every report render.
public struct SessionMetrics: Equatable, Sendable {
    public var snoreTimeMs: Int64
    public var episodeCount: Int
    public var lightMs: Int64
    public var moderateMs: Int64
    public var loudMs: Int64
    /// Median nfAtStart over all events; nil if no events ("room level").
    public var noiseFloorDbfs: Double?

    /// Whole-percent share of the FULL session span (gaps shown visually,
    /// never subtracted — spec §2).
    public func percentOfNight(sessionStartMs: Int64, sessionEndMs: Int64) -> Int {
        let span = sessionEndMs - sessionStartMs
        guard span > 0 else { return 0 }
        return Int((Double(snoreTimeMs) / Double(span) * 100).rounded())
    }

    public static func compute(episodes: [ClosedEpisode],
                               params: DetectorParams) -> SessionMetrics {
        var snore: Int64 = 0
        var light: Int64 = 0, moderate: Int64 = 0, loud: Int64 = 0
        var floors: [Double] = []
        for epi in episodes {
            for ev in epi.events {
                let dur = ev.endMs - ev.startMs
                snore += dur
                switch ev.bucket(params) {
                case .light: light += dur
                case .moderate: moderate += dur
                case .loud: loud += dur
                }
                floors.append(ev.nfAtStart)
            }
        }
        return SessionMetrics(
            snoreTimeMs: snore,
            episodeCount: episodes.count,
            lightMs: light,
            moderateMs: moderate,
            loudMs: loud,
            noiseFloorDbfs: median(floors))
    }

    public static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let mid = s.count / 2
        return s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2
    }
}
