import Foundation

/// Normative detection parameters (spec §1.1). The effective set is
/// snapshotted into `session.detector_params_json` at session start.
public struct DetectorParams: Codable, Equatable, Sendable {
    public var windowMs: Int64 = 1000
    public var hopMs: Int64 = 500
    public var confThreshold: Double = 0.35   // Medium default (YAMNet sigmoid scale)
    public var confStrong: Double = 0.55      // Medium default (YAMNet sigmoid scale)
    public var speechVetoConf: Double = 0.50
    public var nfInit: Double = -60.0
    public var nfRisePerFrame: Double = 0.05
    public var nfClampLo: Double = -80.0
    public var nfClampHi: Double = -30.0
    public var gateOffsetDb: Double = 12.0
    public var gateClampLo: Double = -56.0
    public var gateClampHi: Double = -38.0
    public var mergeGapMs: Int64 = 30000
    public var minEpisodeEvents: Int = 3
    public var minEpisodeSpanMs: Int64 = 30000
    public var intensityLightMaxDb: Double = 25.0
    public var intensityModMaxDb: Double = 40.0

    public init() {}

    /// Sensitivity setting (spec §1.1): overrides exactly two constants.
    public static func forSensitivity(_ s: Sensitivity) -> DetectorParams {
        var p = DetectorParams()
        switch s {
        case .low:    p.confThreshold = 0.50; p.confStrong = 0.70
        case .medium: break
        case .high:   p.confThreshold = 0.22; p.confStrong = 0.40
        }
        return p
    }
}

public enum Sensitivity: String, Codable, Sendable {
    case low, medium, high
}

/// One normalized frame from the platform audio adapter (spec §0).
public struct ClassifierFrame: Equatable, Sendable {
    public var tMs: Int64
    public var rmsDbfs: Double
    public var peakDbfs: Double
    public var snoreConf: Double
    public var speechConf: Double

    public init(tMs: Int64, rmsDbfs: Double, peakDbfs: Double,
                snoreConf: Double, speechConf: Double) {
        self.tMs = tMs
        self.rmsDbfs = rmsDbfs
        self.peakDbfs = peakDbfs
        self.snoreConf = snoreConf
        self.speechConf = speechConf
    }
}

public enum IntensityBucket: String, Codable, Sendable {
    case light, moderate, loud
}

/// One snore sound: a maximal run of contiguous positive frames (spec §1.2).
public struct SnoreEvent: Equatable, Sendable {
    public var startMs: Int64
    public var endMs: Int64 = 0
    public var frameCount: Int = 0
    public var peakDbfs: Double = -100.0
    public var maxConf: Double = 0.0
    public var nfAtStart: Double

    public init(startMs: Int64, endMs: Int64 = 0, frameCount: Int = 0,
                peakDbfs: Double = -100.0, maxConf: Double = 0.0,
                nfAtStart: Double) {
        self.startMs = startMs
        self.endMs = endMs
        self.frameCount = frameCount
        self.peakDbfs = peakDbfs
        self.maxConf = maxConf
        self.nfAtStart = nfAtStart
    }

    /// Per-event relative intensity (spec §2.2).
    public func relDb() -> Double { peakDbfs - nfAtStart }

    public func bucket(_ p: DetectorParams) -> IntensityBucket {
        let rel = relDb()
        if rel < p.intensityLightMaxDb { return .light }
        if rel < p.intensityModMaxDb { return .moderate }
        return .loud
    }

    fileprivate var lastFrameTMs: Int64 = 0
}

/// A finalized CONFIRMED episode (spec §1.2).
public struct ClosedEpisode: Equatable, Sendable {
    public var id: Int
    public var startMs: Int64
    public var endMs: Int64
    public var events: [SnoreEvent]
    public var snoreMs: Int64
    public var peak: SnoreEvent
    public var bucket: IntensityBucket

    public init(id: Int, startMs: Int64, endMs: Int64, events: [SnoreEvent],
                snoreMs: Int64, peak: SnoreEvent, bucket: IntensityBucket) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.events = events
        self.snoreMs = snoreMs
        self.peak = peak
        self.bucket = bucket
    }
}

/// Snapshot passed with `episodeConfirmed` so the service can start clip capture.
public struct ConfirmedEpisode: Equatable, Sendable {
    public var id: Int
    public var startMs: Int64
    public var lastEventEndMs: Int64
    public var eventCount: Int

    public init(id: Int, startMs: Int64, lastEventEndMs: Int64, eventCount: Int) {
        self.id = id
        self.startMs = startMs
        self.lastEventEndMs = lastEventEndMs
        self.eventCount = eventCount
    }
}

public enum DetectorOutput: Equatable, Sendable {
    case eventDetected(SnoreEvent)
    /// Carries the confirming event: its audio is guaranteed fresh in the
    /// ring buffer, which is what makes confirmation-time clips safe (spec §4).
    case episodeConfirmed(ConfirmedEpisode, confirmingEvent: SnoreEvent)
    case episodeClosed(ClosedEpisode)
    case episodeDiscarded(id: Int)
}

/// The shared detection state machine — a direct transliteration of
/// spec/SHARED_BEHAVIOR_SPEC.md §1.3, kept in lockstep with
/// spec/reference/detector.py and the Kotlin port. Pure: no wall clock,
/// no I/O, no platform types.
public final class SnoreDetector {
    private let p: DetectorParams
    private var nf: Double
    private var curEvent: SnoreEvent?
    private var episode: OpenEpisode?
    private var nextId = 1

    private struct OpenEpisode {
        var id: Int
        var confirmed = false
        var events: [SnoreEvent] = []
        var startMs: Int64
        var lastEventEndMs: Int64 = 0
    }

    public init(params: DetectorParams) {
        self.p = params
        self.nf = params.nfInit
    }

    /// Current noise floor (display/diagnostics only).
    public var noiseFloorDbfs: Double { nf }

    public func process(_ f: ClassifierFrame) -> [DetectorOutput] {
        var out: [DetectorOutput] = []
        nf = clamp(min(f.rmsDbfs, nf + p.nfRisePerFrame), p.nfClampLo, p.nfClampHi)
        let gate = clamp(nf + p.gateOffsetDb, p.gateClampLo, p.gateClampHi)
        let vetoed = f.speechConf >= p.speechVetoConf && f.speechConf > f.snoreConf
        let positive = f.rmsDbfs >= gate && f.snoreConf >= p.confThreshold && !vetoed

        if positive {
            if curEvent == nil {
                curEvent = SnoreEvent(startMs: f.tMs, nfAtStart: nf)
            }
            curEvent!.lastFrameTMs = f.tMs
            curEvent!.frameCount += 1
            curEvent!.peakDbfs = max(curEvent!.peakDbfs, f.peakDbfs)
            curEvent!.maxConf = max(curEvent!.maxConf, f.snoreConf)
        } else if curEvent != nil {
            out += closeEvent()
        }

        if let epi = episode, curEvent == nil, f.tMs - epi.lastEventEndMs > p.mergeGapMs {
            out += resolveEpisode()
        }
        return out
    }

    /// Session end or capture interruption (spec §1.3). The noise floor
    /// intentionally survives — it is the same room.
    public func flush() -> [DetectorOutput] {
        var out: [DetectorOutput] = []
        if curEvent != nil { out += closeEvent() }
        if episode != nil { out += resolveEpisode() }
        return out
    }

    private func closeEvent() -> [DetectorOutput] {
        var ev = curEvent!
        curEvent = nil
        ev.endMs = ev.lastFrameTMs + p.windowMs
        let valid = ev.frameCount >= 2 || ev.maxConf >= p.confStrong
        guard valid else { return [] }
        var out: [DetectorOutput] = []
        if let epi = episode, ev.startMs - epi.lastEventEndMs > p.mergeGapMs {
            out += resolveEpisode()  // stale episode; close before attaching
        }
        if episode == nil {
            episode = OpenEpisode(id: nextId, startMs: ev.startMs)
            nextId += 1
        }
        episode!.events.append(ev)
        episode!.lastEventEndMs = ev.endMs
        out.append(.eventDetected(ev))
        if !episode!.confirmed
            && episode!.events.count >= p.minEpisodeEvents
            && episode!.lastEventEndMs - episode!.startMs >= p.minEpisodeSpanMs {
            episode!.confirmed = true
            let snap = ConfirmedEpisode(id: episode!.id, startMs: episode!.startMs,
                                        lastEventEndMs: episode!.lastEventEndMs,
                                        eventCount: episode!.events.count)
            out.append(.episodeConfirmed(snap, confirmingEvent: ev))
        }
        return out
    }

    private func resolveEpisode() -> [DetectorOutput] {
        let epi = episode!
        episode = nil
        guard epi.confirmed else { return [.episodeDiscarded(id: epi.id)] }
        // Normative tie-break: highest peakDbfs, EARLIEST event wins
        // (strict `>` while scanning in order — not Swift max(by:)).
        var peak = epi.events[0]
        for e in epi.events.dropFirst() where e.peakDbfs > peak.peakDbfs {
            peak = e
        }
        let closed = ClosedEpisode(
            id: epi.id,
            startMs: epi.startMs,
            endMs: epi.lastEventEndMs,
            events: epi.events,
            snoreMs: epi.events.reduce(0) { $0 + ($1.endMs - $1.startMs) },
            peak: peak,
            bucket: peak.bucket(p)
        )
        return [.episodeClosed(closed)]
    }
}

@inline(__always)
func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
    max(lo, min(hi, x))
}
