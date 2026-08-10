import AVFoundation
import SoundAnalysis
import SnoreCore

/// Classifier path A: Apple's built-in SoundAnalysis classifier (`.version1`,
/// labels include "snoring" and "speech"). KNOWN RISK (design-feasibility B1):
/// multiple reports of this classifier failing with SNError code 2 once the
/// screen locks, because the built-in model dispatches GPU work that iOS
/// forbids in the background. Spike 0 measures exactly that; the CPU-only
/// Core ML path replaces this class if it fails.
public final class SoundAnalysisClassifier: NSObject, SnoreClassifying,
    SNResultsObserving, @unchecked Sendable {

    public static let sampleRate = 16_000.0

    private var analyzer: SNAudioStreamAnalyzer?
    private var request: SNClassifySoundRequest?
    private var handler: (@Sendable (ClassifierScores) -> Void)?
    private let queue = DispatchQueue(label: "snorelab.soundanalysis")
    /// Last error from the analysis stream (Spike 0 reads this).
    public private(set) var lastError: Error?

    public func start(resultHandler: @escaping @Sendable (ClassifierScores) -> Void) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: Self.sampleRate,
                                   channels: 1, interleaved: false)!
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: 1.0, preferredTimescale: 16_000)
        request.overlapFactor = 0.5
        // Startup assertion (spec §0.1): required labels must exist.
        let labels = Set(request.knownClassifications)
        precondition(labels.contains("snoring") && labels.contains("speech"),
                     "built-in classifier is missing required labels")
        try analyzer.add(request, withObserver: self)
        self.analyzer = analyzer
        self.request = request
        self.handler = resultHandler
        self.lastError = nil
    }

    public func process(samples: [Float], atSampleIndex: Int64) {
        guard let analyzer else { return }
        queue.async {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: Self.sampleRate,
                                       channels: 1, interleaved: false)!
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)) else { return }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { src in
                buffer.floatChannelData![0].update(from: src.baseAddress!,
                                                   count: samples.count)
            }
            analyzer.analyze(buffer, atAudioFramePosition: atSampleIndex)
        }
    }

    public func stop() {
        if let request { analyzer?.remove(request) }
        analyzer?.completeAnalysis()
        analyzer = nil
        request = nil
        handler = nil
    }

    // MARK: SNResultsObserving

    public func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let snore = result.classification(forIdentifier: "snoring")?.confidence ?? 0
        let speech = result.classification(forIdentifier: "speech")?.confidence ?? 0
        let end = result.timeRange.end
        let endSample = end.isNumeric
            ? Int64((end.seconds * Self.sampleRate).rounded()) : nil
        handler?(ClassifierScores(endSampleIndex: endSample,
                                  snoreConf: snore, speechConf: speech))
    }

    public func request(_ request: SNRequest, didFailWithError error: Error) {
        lastError = error
    }
}
