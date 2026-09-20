import AVFoundation
import Foundation
import SnoreCore

/// Spike 0 (plan M0, go/no-go): does classification keep producing results
/// while the screen is locked? Run this on a PHYSICAL device: pick a
/// classifier, start, lock the phone, leave it for 60+ minutes next to any
/// sound source, then read the log. `staleSeconds` growing unbounded while
/// RMS keeps updating means capture is alive but inference is dead.
///
/// 2026-09-19, iPhone 17 / iOS 26.6: the built-in SoundAnalysis classifier
/// produced 7 results, hit `SNError` code 2 at screen lock, and produced
/// nothing for the next 70 minutes (the background-GPU ban,
/// design-feasibility B1). `YAMNetClassifier` (Core ML, `.cpuOnly`) is the
/// replacement; this runner exists to prove it survives the same hour.
public actor SpikeRunner {

    public struct LogLine: Sendable, Identifiable {
        public var id: Int
        public var text: String

        public init(id: Int, text: String) {
            self.id = id
            self.text = text
        }
    }

    /// Reports app/battery state from the app layer (UIKit stays out of this
    /// package); the string is appended to every tick line.
    public typealias Probe = @Sendable () async -> String

    private let makeClassifier: @Sendable () -> SnoreClassifying
    private let classifierName: String
    private let restartOnError: Bool
    private let probe: Probe

    private var engine: AudioCaptureEngine?
    private var coordinator: AudioSessionCoordinator?
    private var classifier: SnoreClassifying?
    private var tickTask: Task<Void, Never>?
    private var chunkTask: Task<Void, Never>?
    private var chunkContinuation: AsyncStream<AudioCaptureEngine.Chunk>.Continuation?

    private var startedAt: Date?
    private var lastScores: ClassifierScores?
    private var lastScoresAt: Date?
    private var lastRmsDbfs: Double = -100
    private var resultCount = 0
    private var restartCount = 0
    private var firstErrorLogged = false
    private var lines: [LogLine] = []
    private var nextLineId = 0
    private let logURL: URL

    /// `restartOnError: false` for the built-in SoundAnalysis classifier:
    /// creating its request while backgrounded is reported to crash inside
    /// the framework (Apple forum thread 751443), which would end the soak.
    public init(logDirectory: URL, classifierName: String,
                restartOnError: Bool = true,
                makeClassifier: @escaping @Sendable () -> SnoreClassifying,
                probe: @escaping Probe = { "" }) {
        logURL = logDirectory.appendingPathComponent("spike0.log")
        self.classifierName = classifierName
        self.restartOnError = restartOnError
        self.makeClassifier = makeClassifier
        self.probe = probe
    }

    public func start() throws {
        guard engine == nil else { return }
        let coordinator = AudioSessionCoordinator()
        try coordinator.activate()
        self.coordinator = coordinator

        do {
            try startClassifier()

            // One stream, one consumer: chunks reach the classifier in capture
            // order. One unstructured Task per chunk could be scheduled out of
            // order, which would hand the analyzer a backwards sample position.
            let (stream, continuation) = AsyncStream.makeStream(
                of: AudioCaptureEngine.Chunk.self)
            chunkContinuation = continuation
            chunkTask = Task { [weak self] in
                for await chunk in stream { await self?.consume(chunk) }
            }
            let engine = AudioCaptureEngine()
            try engine.start { chunk in continuation.yield(chunk) }
            self.engine = engine
        } catch {
            log("spike0 start failed classifier=\(classifierName): \(error)")
            teardown()
            throw error
        }
        startedAt = Date()
        resultCount = 0
        restartCount = 0
        firstErrorLogged = false
        log("spike0 started classifier=\(classifierName) — lock the screen now; results should keep flowing")

        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self?.tick()
            }
        }
    }

    public func stop() {
        teardown()
        log("spike0 stopped")
    }

    private func teardown() {
        tickTask?.cancel()
        tickTask = nil
        startedAt = nil
        engine?.stop()
        engine = nil
        chunkContinuation?.finish()
        chunkContinuation = nil
        chunkTask?.cancel()
        chunkTask = nil
        classifier?.stop()
        classifier = nil
        coordinator?.deactivate()
        coordinator = nil
    }

    public func recentLines() -> [LogLine] { lines.suffix(40) }
    public var isRunning: Bool { engine != nil }

    private func startClassifier() throws {
        let classifier = makeClassifier()
        try classifier.start { [weak self] scores in
            Task { await self?.record(scores: scores) }
        }
        self.classifier = classifier
    }

    private func consume(_ chunk: AudioCaptureEngine.Chunk) {
        classifier?.process(samples: chunk.floats,
                            atSampleIndex: chunk.firstSampleIndex)
        lastRmsDbfs = LevelMeter.measure(chunk.floats).rmsDbfs
    }

    private func record(scores: ClassifierScores) {
        lastScores = scores
        lastScoresAt = Date()
        resultCount += 1
    }

    private func tick() async {
        guard let startedAt else { return }
        // The probe hops to the main actor; stop() can run meanwhile. Read
        // state only after it, and bail if this run ended.
        let environment = await probe()
        guard !Task.isCancelled, engine != nil else { return }
        let uptime = Int(Date().timeIntervalSince(startedAt))
        let stale = lastScoresAt.map { Int(Date().timeIntervalSince($0)) } ?? -1
        let error = classifier?.lastError
        let verdict = stale >= 0 && stale < 5 ? "OK" : "STALLED"
        log(String(format:
            "t=%ds results=%d staleSeconds=%d rms=%.1fdBFS snore=%.2f speech=%.2f err=%@ %@ [%@] → %@",
            uptime, resultCount, stale, lastRmsDbfs,
            lastScores?.snoreConf ?? 0, lastScores?.speechConf ?? 0,
            error.map { "\($0)" } ?? "none", environment,
            classifier?.statusLine ?? "", verdict))
        // A request that errored is finished for good (SoundAnalysis
        // SNResult.h). Rebuild it so the log shows whether the next one also
        // dies while locked, instead of one error reading as an hour of silence.
        guard error != nil else { return }
        if !firstErrorLogged {
            firstErrorLogged = true
            log("first classifier error at t=\(uptime)s")
        }
        guard restartOnError else { return }
        classifier?.stop()
        classifier = nil
        do {
            try startClassifier()
            restartCount += 1
            log("classifier restarted (#\(restartCount))")
        } catch {
            log("classifier restart failed: \(error)")
        }
    }

    private func log(_ text: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(text)"
        lines.append(LogLine(id: nextLineId, text: line))
        nextLineId += 1
        if let data = (line + "\n").data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: logURL)
            }
        }
    }
}
