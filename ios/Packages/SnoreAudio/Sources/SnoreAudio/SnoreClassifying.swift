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

/// The swappable classifier seam (spec §0.1, design-ios §3). Spike 0 on a
/// physical iPhone (2026-09-19) showed the built-in SoundAnalysis classifier
/// dies at screen lock, so `YAMNetClassifier` (Core ML, CPU only) is the
/// production implementation; `SoundAnalysisClassifier` stays for A/B soak
/// tests. The pipeline never sees which one it has.
public protocol SnoreClassifying: AnyObject {
    /// Called before capture starts. Results arrive on an arbitrary queue.
    func start(resultHandler: @escaping @Sendable (ClassifierScores) -> Void) throws
    /// Feed 16 kHz mono float samples; `atSampleIndex` is the first sample's
    /// position in session sample time. Plain arrays (Sendable) so chunks can
    /// cross actor boundaries; implementations build their own buffers.
    /// Chunks must arrive in capture order.
    func process(samples: [Float], atSampleIndex: Int64)
    /// Capture is about to restart after a gap: drop any buffered audio so the
    /// first post-gap window holds only post-gap samples. The session sample
    /// clock is contiguous across restarts by design, so the classifier cannot
    /// detect the gap from indices alone.
    func reset()
    func stop()
    /// Most recent failure, nil while healthy. The recording actor surfaces
    /// it in the live snapshot; Spike 0 logs and rebuilds on it.
    var lastError: Error? { get }
    /// One-line diagnostics for the Spike 0 log (counts, latency, backend).
    var statusLine: String { get }
}
