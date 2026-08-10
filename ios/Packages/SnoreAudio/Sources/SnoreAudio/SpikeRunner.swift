import AVFoundation
import Foundation
import SnoreCore

/// Spike 0 (plan M0, go/no-go): does classification keep producing results
/// while the screen is locked? Run this on a PHYSICAL device: start, lock the
/// phone, leave it for 60+ minutes next to any sound source (a video of
/// snoring works), then check the log. If `staleSeconds` grows unbounded or
/// errors accumulate while RMS keeps updating, the built-in SoundAnalysis
/// classifier is dead in the background on this OS → switch the classifier
/// seam to the CPU-only Core ML path (design-feasibility B1).
public actor SpikeRunner {

    public struct LogLine: Sendable, Identifiable {
        public var id: Int
        public var text: String
    }

    private var engine: AudioCaptureEngine?
    private var coordinator: AudioSessionCoordinator?
    private var classifier: SoundAnalysisClassifier?
    private var tickTask: Task<Void, Never>?

    private var startedAt: Date?
    private var lastScores: ClassifierScores?
    private var lastScoresAt: Date?
    private var lastRmsDbfs: Double = -100
    private var resultCount = 0
    private var errorCount = 0
    private var lines: [LogLine] = []
    private var nextLineId = 0
    private let logURL: URL

    public init(logDirectory: URL) {
        logURL = logDirectory.appendingPathComponent("spike0.log")
    }

    public func start() throws {
        guard engine == nil else { return }
        let coordinator = AudioSessionCoordinator()
        try coordinator.activate()
        self.coordinator = coordinator

        let classifier = SoundAnalysisClassifier()
        try classifier.start { [weak self] scores in
            Task { await self?.record(scores: scores) }
        }
        self.classifier = classifier

        let engine = AudioCaptureEngine()
        try engine.start { [weak self] chunk in
            Task { await self?.consume(chunk) }
        }
        self.engine = engine
        startedAt = Date()
        resultCount = 0
        errorCount = 0
        log("spike0 started — lock the screen now; results should keep flowing")

        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self?.tick()
            }
        }
    }

    public func stop() {
        tickTask?.cancel()
        tickTask = nil
        engine?.stop()
        engine = nil
        classifier?.stop()
        classifier = nil
        coordinator?.deactivate()
        coordinator = nil
        log("spike0 stopped")
    }

    public func recentLines() -> [LogLine] { lines.suffix(40) }
    public var isRunning: Bool { engine != nil }

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

    private func tick() {
        guard let startedAt else { return }
        let uptime = Int(Date().timeIntervalSince(startedAt))
        let stale = lastScoresAt.map { Int(Date().timeIntervalSince($0)) } ?? -1
        if classifier?.lastError != nil { errorCount += 1 }
        let verdict = stale >= 0 && stale < 5 ? "OK" : "STALLED"
        log(String(format:
            "t=%ds results=%d staleSeconds=%d rms=%.1fdBFS snore=%.2f err=%@ → %@",
            uptime, resultCount, stale, lastRmsDbfs,
            lastScores?.snoreConf ?? 0,
            classifier?.lastError.map { "\($0)" } ?? "none", verdict))
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
