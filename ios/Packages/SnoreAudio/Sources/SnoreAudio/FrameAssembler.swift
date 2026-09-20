import Foundation
import SnoreCore

/// Builds the normalized `ClassifierFrame` stream (spec §0): one frame every
/// 500 ms covering a 1.0 s trailing window, RMS/peak computed here over the
/// exact window, classifier confidence attached from the scores whose window
/// END is nearest this frame's window end (adapter rule, §0.1).
///
/// Levels are known the instant a hop boundary is reached, but the classifier
/// result for that same window arrives a few milliseconds later, from another
/// queue. So a completed frame is held as `pending` until its score lands
/// (`attach` then returns it) or until the next hop boundary, whichever comes
/// first. Without the hold every frame would carry the PREVIOUS hop's score:
/// loudness and confidence 500 ms apart, which drops short snores.
///
/// Timestamps are sample-count anchored (spec §0.2): the recording service
/// re-anchors at every capture (re)start by constructing a fresh assembler.
public final class FrameAssembler {
    public static let sampleRate = 16_000
    public static let windowSamples = 16_000       // 1.0 s
    public static let hopSamples = 8_000           // 500 ms

    /// A score set older than this (in session samples) is treated as absent:
    /// a stalled classifier must read as `snoreConf = 0`, never as frozen
    /// confidence (spec §0.1 — late/dropped results normalize to zero). Two
    /// hops of slack absorbs normal analysis latency.
    public static let maxScoreAgeSamples: Int64 = 16_000 * 3

    private let anchorMs: Int64
    /// Session sample index this assembler was anchored at (capture (re)start).
    public let anchorSampleIndex: Int64
    private var window: [Float] = []
    private var samplesSeen: Int64 = 0
    private var latestScores: ClassifierScores?
    /// Session sample index at which `latestScores` arrived, for staleness.
    private var latestScoresAtSample: Int64?
    /// Frame whose levels are measured and whose score has not arrived yet.
    private var pending: (frame: ClassifierFrame, endSample: Int64)?

    public init(anchorMs: Int64, anchorSampleIndex: Int64) {
        self.anchorMs = anchorMs
        self.anchorSampleIndex = anchorSampleIndex
        window.reserveCapacity(Self.windowSamples)
    }

    /// Record a classifier result. Returns the pending frame when this result
    /// is the one it was waiting for; the caller feeds it to the detector
    /// exactly like frames returned from `push`.
    @discardableResult
    public func attach(scores: ClassifierScores) -> [ClassifierFrame] {
        // Prefer the analyzer's own window-end position; fall back to how far
        // this assembler has consumed when the result carries no timing.
        let at = scores.endSampleIndex ?? currentSampleIndex
        // A window that ended at or before this anchor describes audio from
        // before the capture gap; it must not colour post-gap frames.
        if at <= anchorSampleIndex { return [] }
        // Results hop actors on their way here; a late-arriving older window
        // must not replace a newer one.
        if let latest = latestScoresAtSample, at < latest { return [] }
        let previous = latestScores
        let previousAt = latestScoresAtSample
        latestScores = scores
        latestScoresAtSample = at
        guard let waiting = pending, at >= waiting.endSample else { return [] }
        // Two candidates straddle the frame end: the score that just arrived
        // (ends at or after it) and the one before (ends before it). Take the
        // nearer; on aligned grids that is always the new one, at distance 0.
        var chosen = scores
        if let previous, let previousAt,
           waiting.endSample - previousAt < at - waiting.endSample {
            chosen = previous
        }
        pending = nil
        return [waiting.frame.with(chosen)]
    }

    /// Emit the pending frame, if any, with the best score available now.
    /// Call before flushing the detector (stop, interruption) so the last
    /// 500 ms of a segment is not lost.
    public func drain() -> [ClassifierFrame] {
        guard let waiting = pending else { return [] }
        pending = nil
        return [waiting.frame.with(freshScores(atWindowEnd: waiting.endSample))]
    }

    /// Push converted samples; returns zero or more completed frames.
    public func push(_ samples: [Float]) -> [ClassifierFrame] {
        var frames: [ClassifierFrame] = []
        var cursor = 0
        while cursor < samples.count {
            let need = Self.hopSamples - Int(samplesSeen % Int64(Self.hopSamples))
            let take = min(need, samples.count - cursor)
            window.append(contentsOf: samples[cursor..<cursor + take])
            if window.count > Self.windowSamples {
                window.removeFirst(window.count - Self.windowSamples)
            }
            samplesSeen += Int64(take)
            cursor += take
            if samplesSeen % Int64(Self.hopSamples) == 0,
               samplesSeen >= Int64(Self.windowSamples) {
                // Deadline for the previous frame: its score never came (slow
                // or dead classifier, or a backlog being drained faster than
                // real time). Emit it first so frames stay in order.
                frames.append(contentsOf: drain())
                holdFrame()
            }
        }
        return frames
    }

    private func holdFrame() {
        let levels = LevelMeter.measure(window)
        let windowStartSample = anchorSampleIndex + samplesSeen - Int64(Self.windowSamples)
        let tMs = anchorMs + (windowStartSample - anchorSampleIndex) * 1000
            / Int64(Self.sampleRate)
        let frame = ClassifierFrame(tMs: tMs, rmsDbfs: levels.rmsDbfs,
                                    peakDbfs: levels.peakDbfs,
                                    snoreConf: 0, speechConf: 0)
        pending = (frame, anchorSampleIndex + samplesSeen)
    }

    /// Latest scores, unless they are too old to describe this window: a
    /// stalled classifier must read as zero, never as frozen confidence.
    private func freshScores(atWindowEnd windowEndSample: Int64) -> ClassifierScores? {
        guard let at = latestScoresAtSample,
              windowEndSample - at <= Self.maxScoreAgeSamples else { return nil }
        return latestScores
    }

    /// Reset the staleness clock after the owner rebuilds a dead classifier,
    /// so the next watchdog tick judges the new one, not the old silence.
    public func noteClassifierRestarted() {
        latestScores = nil
        latestScoresAtSample = anchorSampleIndex + samplesSeen
    }

    /// True when classifier results have gone stale — the locked-screen
    /// failure mode (design-feasibility B1). The recording actor surfaces this
    /// so a dead classifier is visible instead of silently scoring zero.
    public var classifierIsStale: Bool {
        guard let at = latestScoresAtSample else {
            // No result yet: only stale once enough audio has gone by.
            return samplesSeen > Self.maxScoreAgeSamples
        }
        return (anchorSampleIndex + samplesSeen) - at > Self.maxScoreAgeSamples
    }

    /// Session sample time of the next sample this assembler will consume.
    public var currentSampleIndex: Int64 { anchorSampleIndex + samplesSeen }

    /// Map an absolute frame timestamp back to session sample time
    /// (valid for times within this anchor segment — used for clip capture).
    public func sampleIndex(forTMs tMs: Int64) -> Int64 {
        anchorSampleIndex + (tMs - anchorMs) * Int64(Self.sampleRate) / 1000
    }
}

private extension ClassifierFrame {
    func with(_ scores: ClassifierScores?) -> ClassifierFrame {
        var frame = self
        frame.snoreConf = scores?.snoreConf ?? 0
        frame.speechConf = scores?.speechConf ?? 0
        return frame
    }
}
