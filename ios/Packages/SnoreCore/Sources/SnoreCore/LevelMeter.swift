import Foundation

/// RMS/peak measurement over PCM float samples (spec §0): the normalization
/// layer always computes levels over its own exact 1.0 s window, independent
/// of the classifier's windowing. Pure; no Accelerate so behavior is
/// bit-obvious (a vDSP fast path can come later behind the same contract).
public enum LevelMeter {

    public struct Levels: Equatable, Sendable {
        public var rmsDbfs: Double
        public var peakDbfs: Double
    }

    /// Samples are PCM float normalized to [-1, 1]. Silence clamps to -100 dBFS.
    public static func measure(_ samples: [Float]) -> Levels {
        guard !samples.isEmpty else {
            return Levels(rmsDbfs: -100, peakDbfs: -100)
        }
        var sumSquares = 0.0
        var maxAbs = 0.0
        for s in samples {
            let d = Double(s)
            sumSquares += d * d
            maxAbs = max(maxAbs, abs(d))
        }
        let rms = (sumSquares / Double(samples.count)).squareRoot()
        return Levels(rmsDbfs: dbfs(rms), peakDbfs: dbfs(maxAbs))
    }

    @inline(__always)
    public static func dbfs(_ linear: Double) -> Double {
        guard linear > 0 else { return -100 }
        return max(-100, min(0, 20 * log10(linear)))
    }
}
