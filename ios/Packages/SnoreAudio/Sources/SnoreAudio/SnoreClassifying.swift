import AVFoundation
import SnoreCore

/// Classifier scores for one analysis window, in session sample time
/// (16 kHz samples since capture start).
public struct ClassifierScores: Sendable {
    /// Sample index of the analysis window's END; nil if unknown.
    public var endSampleIndex: Int64?
    public var snoreConf: Double
    public var speechConf: Double

    public init(endSampleIndex: Int64?, snoreConf: Double, speechConf: Double) {
        self.endSampleIndex = endSampleIndex
        self.snoreConf = snoreConf
        self.speechConf = speechConf
    }
}

/// The swappable classifier seam (spec §0.1, design-ios §3): Spike 0 decides
/// whether the built-in SoundAnalysis classifier survives the locked screen;
/// if not, a CPU-only Core ML implementation replaces it behind this protocol
/// without touching the pipeline.
public protocol SnoreClassifying: AnyObject {
    /// Called before capture starts. Results arrive on an arbitrary queue.
    func start(resultHandler: @escaping @Sendable (ClassifierScores) -> Void) throws
    /// Feed 16 kHz mono float samples; `atSampleIndex` is the first sample's
    /// position in session sample time. Plain arrays (Sendable) so chunks can
    /// cross actor boundaries; implementations build their own buffers.
    func process(samples: [Float], atSampleIndex: Int64)
    func stop()
}
