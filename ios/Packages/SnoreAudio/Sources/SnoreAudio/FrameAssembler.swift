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

    private let anchorMs: Int64
    private let anchorSampleIndex: Int64
    private var window: [Float] = []
    private var samplesSeen: Int64 = 0
    private var latestScores: ClassifierScores?

    public init(anchorMs: Int64, anchorSampleIndex: Int64) {
        self.anchorMs = anchorMs
        self.anchorSampleIndex = anchorSampleIndex
        window.reserveCapacity(Self.windowSamples)
    }

    public func attach(scores: ClassifierScores) {
        latestScores = scores
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
        let scores = latestScores
        return ClassifierFrame(
            tMs: tMs,
            rmsDbfs: levels.rmsDbfs,
            peakDbfs: levels.peakDbfs,
            snoreConf: scores?.snoreConf ?? 0,
            speechConf: scores?.speechConf ?? 0)
    }

    /// Session sample time of the next sample this assembler will consume.
    public var currentSampleIndex: Int64 { anchorSampleIndex + samplesSeen }

    /// Map an absolute frame timestamp back to session sample time
    /// (valid for times within this anchor segment — used for clip capture).
    public func sampleIndex(forTMs tMs: Int64) -> Int64 {
        anchorSampleIndex + (tMs - anchorMs) * Int64(Self.sampleRate) / 1000
    }
}
