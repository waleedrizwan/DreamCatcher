import Foundation
import SnoreCore

/// Builds the normalized `ClassifierFrame` stream (spec §0): one frame every
/// 500 ms covering a 1.0 s trailing window, RMS/peak computed here over the
/// exact window, classifier confidence attached from the most recent scores
/// whose window END falls inside this frame's window (adapter rule, §0.1).
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
    private let anchorSampleIndex: Int64
    private var window: [Float] = []
    private var samplesSeen: Int64 = 0
    private var latestScores: ClassifierScores?
    /// Session sample index at which `latestScores` arrived, for staleness.
    private var latestScoresAtSample: Int64?

    public init(anchorMs: Int64, anchorSampleIndex: Int64) {
        self.anchorMs = anchorMs
        self.anchorSampleIndex = anchorSampleIndex
        window.reserveCapacity(Self.windowSamples)
    }

    public func attach(scores: ClassifierScores) {
        latestScores = scores
        // Prefer the analyzer's own window-end position; fall back to how far
        // this assembler has consumed when the result carries no timing.
        latestScoresAtSample = scores.endSampleIndex ?? currentSampleIndex
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
                frames.append(makeFrame())
            }
        }
        return frames
    }

    private func makeFrame() -> ClassifierFrame {
        let levels = LevelMeter.measure(window)
        let windowStartSample = anchorSampleIndex + samplesSeen - Int64(Self.windowSamples)
        let tMs = anchorMs + (windowStartSample - anchorSampleIndex) * 1000
            / Int64(Self.sampleRate)
        let windowEndSample = anchorSampleIndex + samplesSeen
        let fresh = latestScoresAtSample
            .map { windowEndSample - $0 <= Self.maxScoreAgeSamples } ?? false
        let scores = fresh ? latestScores : nil
        return ClassifierFrame(
            tMs: tMs,
            rmsDbfs: levels.rmsDbfs,
            peakDbfs: levels.peakDbfs,
            snoreConf: scores?.snoreConf ?? 0,
            speechConf: scores?.speechConf ?? 0)
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
