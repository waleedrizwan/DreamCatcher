import CoreML
import Foundation
import SnoreCore

/// Production classifier (spec §0.1): YAMNet (Google, AudioSet, Apache 2.0)
/// converted to Core ML (tools/yamnet/) and run with `computeUnits =
/// .cpuOnly`, the one compute path iOS allows a backgrounded app. Feeds the
/// model exactly one patch (15 600 samples = 0.975 s) every hop (8 000
/// samples = 500 ms). The hop grid restarts wherever the audio does (session
/// start, `reset()`, or an index jump), which is also where
/// `FrameAssembler` re-anchors, so every result's `endSampleIndex` lands on
/// a frame boundary.
///
/// Each window is peak-normalized before inference: YAMNet's log-mel front
/// end has no level normalization, and tools/yamnet/level_experiment.py
/// shows strong snores attenuated 36 dB (phone across the room) fall from
/// 100 % to 35 % detected at threshold 0.35 without it, with 0 % extra false
/// positives on 500 non-snoring clips. Level still reaches the detector
/// through `rmsDbfs`, which FrameAssembler measures on the raw audio.
public final class YAMNetClassifier: SnoreClassifying, @unchecked Sendable {

    public static let sampleRate = 16_000
    public static let windowSamples = 15_600      // one YAMNet patch, 0.975 s
    public static let hopSamples = 8_000          // spec HOP_MS = 500
    static let normalizeTargetPeak: Float = 0.5
    static let normalizeMaxGain: Float = 31.6     // +30 dB

    public enum LoadError: Error {
        case resourceMissing(String)
        case labelMissing(String)
        case unexpectedOutputShape([Int])
    }

    private let queue = DispatchQueue(label: "dreamcatcher.yamnet")
    /// Debug tuning log (nil in normal use); see `ScoreLog`.
    private let scoreLog: ScoreLog?
    private var loggedIndices: [Int] = []
    private var model: MLModel?
    private var input: MLMultiArray?
    private var handler: (@Sendable (ClassifierScores) -> Void)?
    private var snoreIndex = 0
    private var speechIndex = 0

    // Session-sample bookkeeping (touched only on `queue`).
    private var window: [Float] = []
    private var samplesSeen: Int64 = 0
    /// Session sample index the hop grid is counted from.
    private var gridOrigin: Int64 = 0
    private var expectedNextIndex: Int64?

    // Diagnostics: written on `queue`, read from anywhere (approximate is fine
    // for plain numbers).
    private var inferenceCount = 0
    private var errorCount = 0
    private var lastInferenceMs = 0.0
    // An `Error?` is a reference-counted box, so unlike the counters above it
    // needs real synchronization between the inference queue and its readers.
    private let errorLock = NSLock()
    private var storedError: Error?
    public var lastError: Error? {
        errorLock.lock(); defer { errorLock.unlock() }
        return storedError
    }

    private func setLastError(_ error: Error?) {
        errorLock.lock(); defer { errorLock.unlock() }
        storedError = error
    }

    /// `scoreLog` writes one row per window with the raw level and the scores
    /// for `ScoreLog.watchedClasses`. Debug builds only; costs one CSV row
    /// per 500 ms.
    public init(scoreLog: ScoreLog? = nil) {
        self.scoreLog = scoreLog
    }

    public var statusLine: String {
        String(format: "yamnet.cpuOnly inferences=%d errors=%d last=%.1fms",
               inferenceCount, errorCount, lastInferenceMs)
    }

    public func start(resultHandler: @escaping @Sendable (ClassifierScores) -> Void) throws {
        let classes = try Self.classIndices()
        guard let snore = classes["Snoring"] else { throw LoadError.labelMissing("Snoring") }
        guard let speech = classes["Speech"] else { throw LoadError.labelMissing("Speech") }
        // A class the model does not have is skipped rather than fatal: the
        // watch list is exploratory, the two required ones are asserted above.
        let logged = scoreLog == nil ? [] : ScoreLog.watchedClasses.compactMap { classes[$0] }
        guard let url = Bundle.module.url(forResource: "YAMNet", withExtension: "mlmodelc") else {
            throw LoadError.resourceMissing("YAMNet.mlmodelc")
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: url, configuration: config)
        // Startup assertion (spec §0.1): the bundled model must be the one the
        // class map describes.
        let shape = model.modelDescription.outputDescriptionsByName["scores"]?
            .multiArrayConstraint?.shape.map(\.intValue) ?? []
        guard shape == [1, 521] else { throw LoadError.unexpectedOutputShape(shape) }
        let input = try MLMultiArray(shape: [NSNumber(value: Self.windowSamples)],
                                     dataType: .float32)
        queue.sync {
            self.model = model
            self.input = input
            self.handler = resultHandler
            self.snoreIndex = snore
            self.speechIndex = speech
            self.loggedIndices = logged
            self.window = []
            self.window.reserveCapacity(Self.windowSamples)
            self.samplesSeen = 0
            self.gridOrigin = 0
            self.expectedNextIndex = nil
        }
        setLastError(nil)
    }

    public func reset() {
        // Async keeps the caller (the recording actor) from waiting behind an
        // in-flight inference; chunks fed after this call queue up behind it.
        queue.async { [self] in
            window.removeAll(keepingCapacity: true)
            expectedNextIndex = nil
        }
    }

    public func process(samples: [Float], atSampleIndex: Int64) {
        queue.async { [self] in
            guard model != nil else { return }
            // A capture restart or a dropped chunk breaks the window: start
            // over at this chunk's position rather than splice unrelated audio.
            if expectedNextIndex != atSampleIndex {
                window.removeAll(keepingCapacity: true)
                samplesSeen = atSampleIndex
                gridOrigin = atSampleIndex
            }
            expectedNextIndex = atSampleIndex + Int64(samples.count)
            let hop = Int64(Self.hopSamples)
            var cursor = 0
            while cursor < samples.count {
                let need = Self.hopSamples - Int((samplesSeen - gridOrigin) % hop)
                let take = min(need, samples.count - cursor)
                window.append(contentsOf: samples[cursor..<cursor + take])
                if window.count > Self.windowSamples {
                    window.removeFirst(window.count - Self.windowSamples)
                }
                samplesSeen += Int64(take)
                cursor += take
                if (samplesSeen - gridOrigin) % hop == 0,
                   window.count == Self.windowSamples {
                    infer(endSampleIndex: samplesSeen)
                }
            }
        }
    }

    /// Blocks until every chunk fed so far has been classified. Tests use it
    /// to run the pipeline deterministically; production never waits.
    func waitUntilIdle() {
        queue.sync {}
    }

    public func stop() {
        scoreLog?.finish()
        queue.sync {
            model = nil
            input = nil
            handler = nil
            window = []
        }
    }

    private func infer(endSampleIndex: Int64) {
        guard let model, let input, let handler else { return }
        let started = Date()
        var peak: Float = 0
        for v in window { peak = max(peak, abs(v)) }
        let gain = peak > 0
            ? min(Self.normalizeTargetPeak / peak, Self.normalizeMaxGain) : 1
        input.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            for i in 0..<Self.windowSamples {
                buffer[i] = max(-1, min(1, window[i] * gain))
            }
        }
        do {
            let provider = try MLDictionaryFeatureProvider(
                dictionary: ["waveform": MLFeatureValue(multiArray: input)])
            let output = try model.prediction(from: provider)
            guard let scores = output.featureValue(for: "scores")?.multiArrayValue else {
                throw LoadError.unexpectedOutputShape([])
            }
            let snore = scores[[0, NSNumber(value: snoreIndex)] as [NSNumber]].doubleValue
            let speech = scores[[0, NSNumber(value: speechIndex)] as [NSNumber]].doubleValue
            if let scoreLog {
                // Level is logged RAW (pre-normalization) because that is what
                // the detector's gate sees; the gain applied says how much the
                // window was lifted before the model saw it.
                let levels = LevelMeter.measure(window)
                scoreLog.append(
                    sampleEnd: endSampleIndex,
                    rmsDbfs: levels.rmsDbfs, peakDbfs: levels.peakDbfs,
                    gainDb: 20 * log10(Double(max(gain, .leastNormalMagnitude))),
                    scores: loggedIndices.map {
                        scores[[0, NSNumber(value: $0)] as [NSNumber]].doubleValue
                    })
            }
            inferenceCount += 1
            lastInferenceMs = Date().timeIntervalSince(started) * 1000
            handler(ClassifierScores(endSampleIndex: endSampleIndex,
                                     snoreConf: snore, speechConf: speech))
        } catch {
            errorCount += 1
            setLastError(error)
        }
    }

    /// Indices of the snore and speech classes in the bundled AudioSet class
    /// map (spec §0.1 startup assertion: fail loudly if either is absent).
    static func labelIndices() throws -> (snore: Int, speech: Int) {
        let classes = try classIndices()
        guard let snore = classes["Snoring"] else { throw LoadError.labelMissing("Snoring") }
        guard let speech = classes["Speech"] else { throw LoadError.labelMissing("Speech") }
        return (snore, speech)
    }

    /// The whole bundled class map, display name → output index.
    static func classIndices() throws -> [String: Int] {
        guard let url = Bundle.module.url(forResource: "yamnet_class_map", withExtension: "csv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw LoadError.resourceMissing("yamnet_class_map.csv")
        }
        var classes: [String: Int] = [:]
        // The upstream file has CRLF line endings, and "\r\n" is a single
        // Character in Swift, so split on any newline rather than on "\n".
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {
            // index,mid,display_name — names may be quoted and contain commas.
            let parts = line.split(separator: ",", maxSplits: 2,
                                   omittingEmptySubsequences: false)
            guard parts.count == 3, let index = Int(parts[0]) else { continue }
            let name = parts[2].trimmingCharacters(in: CharacterSet(charactersIn: "\"\r "))
            classes[name] = index
        }
        return classes
    }
}
