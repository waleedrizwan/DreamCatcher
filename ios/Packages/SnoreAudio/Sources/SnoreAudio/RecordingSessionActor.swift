import AVFoundation
import Foundation
import SnoreCore
import SnoreStorage

/// The single mutable authority during a night (design-ios §6): owns the
/// capture engine, classifier, detector, ring buffer, clip writing, and all
/// DB writes. UI reads via `snapshot()`.
public actor RecordingSessionActor {

    public struct LiveSnapshot: Sendable {
        public var isRecording: Bool
        public var sessionId: String?
        public var startedAtMs: Int64?
        public var noiseFloorDbfs: Double?
        public var inEpisode: Bool
        public var eventsSoFar: Int
        public var episodesSoFar: Int
        public var lastClassifierError: String?
    }

    public enum StopOutcome: Sendable {
        case saved(sessionId: String)
        case discardedTooShort
    }

    // Dependencies
    private let repository: SessionRepository
    private let clipsRoot: URL
    private let makeClassifier: @Sendable () -> SnoreClassifying

    // Per-session state
    private var session: SessionRecord?
    private var params = DetectorParams()
    private var engine: AudioCaptureEngine?
    private var coordinator: AudioSessionCoordinator?
    private var classifier: SnoreClassifying?
    private var detector: SnoreDetector?
    private var assembler: FrameAssembler?
    private var ring: PCMRingBuffer?
    private var heartbeatTask: Task<Void, Never>?

    // Episode bookkeeping (write policy, spec §3)
    private var pendingEventIds: [String] = []
    private var confirmedEpisodeId: String?
    private var clipCount = 0
    private var eventsSoFar = 0
    private var episodesSoFar = 0
    private var inEpisodeNow = false

    // Interruption bookkeeping
    private var gapStartMs: Int64?

    public static let maxSessionMs: Int64 = 12 * 3_600_000   // spec §3.1 auto-stop
    public static let minSessionMs: Int64 = 5 * 60_000       // spec §3.1 discard
    public static let maxClipsPerNight = 30                  // spec §4
    public static let clipPreRollMs: Int64 = 3_000
    public static let clipLengthMs: Int64 = 12_000

    public init(repository: SessionRepository, clipsRoot: URL,
                makeClassifier: @escaping @Sendable () -> SnoreClassifying) {
        self.repository = repository
        self.clipsRoot = clipsRoot
        self.makeClassifier = makeClassifier
    }

    // MARK: lifecycle

    public func start(sensitivity: Sensitivity) throws {
        guard session == nil else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        params = DetectorParams.forSensitivity(sensitivity)

        let coordinator = AudioSessionCoordinator()
        try coordinator.activate()
        coordinator.startObserving { [weak self] event in
            Task { await self?.handle(sessionEvent: event) }
        }
        self.coordinator = coordinator

        let record = try repository.startSession(
            nowMs: nowMs,
            tzId: TimeZone.current.identifier,
            tzOffsetMin: TimeZone.current.secondsFromGMT() / 60,
            params: params, sensitivity: sensitivity,
            appVersion: Bundle.main
                .object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "dev",
            deviceModel: deviceModel())
        session = record

        detector = SnoreDetector(params: params)
        assembler = FrameAssembler(anchorMs: nowMs, anchorSampleIndex: 0)
        ring = PCMRingBuffer(seconds: 30)
        pendingEventIds = []
        confirmedEpisodeId = nil
        clipCount = 0
        eventsSoFar = 0
        episodesSoFar = 0
        inEpisodeNow = false

        let classifier = makeClassifier()
        try classifier.start { [weak self] scores in
            Task { await self?.attach(scores: scores) }
        }
        self.classifier = classifier

        let engine = AudioCaptureEngine()
        try engine.start { [weak self] chunk in
            Task { await self?.consume(chunk) }
        }
        self.engine = engine

        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.heartbeatTick()
            }
        }
    }

    @discardableResult
    public func stop(reason: SessionRecord.EndReason = .user) throws -> StopOutcome {
        guard let record = session else { return .discardedTooShort }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        teardownAudio()
        if let detector { handle(outputs: detector.flush()) }
        heartbeatTask?.cancel()
        heartbeatTask = nil

        defer {
            session = nil
            detector = nil
            assembler = nil
            ring = nil
        }
        if nowMs - record.startedAtMs < Self.minSessionMs {
            try repository.discardSession(sessionId: record.id)
            try? FileManager.default.removeItem(
                at: clipsRoot.appendingPathComponent(record.id))
            return .discardedTooShort
        }
        try repository.finalizeSession(sessionId: record.id, endMs: nowMs,
                                       endReason: reason)
        for expired in (try? repository.expireClips(nowMs: nowMs)) ?? [] {
            try? FileManager.default.removeItem(
                at: clipsRoot.deletingLastPathComponent()
                    .appendingPathComponent(expired))
        }
        return .saved(sessionId: record.id)
    }

    public func snapshot() -> LiveSnapshot {
        LiveSnapshot(
            isRecording: session != nil,
            sessionId: session?.id,
            startedAtMs: session?.startedAtMs,
            noiseFloorDbfs: detector?.noiseFloorDbfs,
            inEpisode: inEpisodeNow,
            eventsSoFar: eventsSoFar,
            episodesSoFar: episodesSoFar,
            lastClassifierError: (classifier as? SoundAnalysisClassifier)?
                .lastError?.localizedDescription)
    }

    // MARK: audio path

    private func consume(_ chunk: AudioCaptureEngine.Chunk) {
        guard session != nil, let assembler, let detector else { return }
        ring?.write(chunk.int16s)
        classifier?.process(samples: chunk.floats,
                            atSampleIndex: chunk.firstSampleIndex)
        for frame in assembler.push(chunk.floats) {
            handle(outputs: detector.process(frame))
        }
    }

    private func attach(scores: ClassifierScores) {
        assembler?.attach(scores: scores)
    }

    private func handle(outputs: [DetectorOutput]) {
        guard let record = session else { return }
        for output in outputs {
            do {
                switch output {
                case .eventDetected(let ev):
                    let row = try repository.recordEvent(sessionId: record.id, ev)
                    pendingEventIds.append(row.id)
                    eventsSoFar += 1
                    inEpisodeNow = true

                case .episodeConfirmed(let confirmed, let confirmingEvent):
                    let episodeId = UUID().uuidString
                    confirmedEpisodeId = episodeId
                    try repository.confirmEpisode(
                        sessionId: record.id, episodeId: episodeId,
                        confirmed: confirmed, eventIds: pendingEventIds,
                        params: params, provisionalPeak: confirmingEvent)
                    captureClip(sessionId: record.id, episodeId: episodeId,
                                confirmingEvent: confirmingEvent)

                case .episodeClosed(let closed):
                    if let episodeId = confirmedEpisodeId {
                        try repository.closeEpisode(episodeId: episodeId, closed,
                                                    params: params,
                                                    eventIds: pendingEventIds)
                        episodesSoFar += 1
                    }
                    pendingEventIds = []
                    confirmedEpisodeId = nil
                    inEpisodeNow = false

                case .episodeDiscarded:
                    try repository.discardEvents(ids: pendingEventIds)
                    pendingEventIds = []
                    confirmedEpisodeId = nil
                    inEpisodeNow = false
                }
            } catch {
                // Storage-full degrade (spec §3.1): metrics writes failing must
                // never crash the night. TODO(M3): in-memory retry + degraded flag.
            }
        }
    }

    /// Confirmation-time clip (spec §4): the confirming event is guaranteed
    /// fresh in the 30 s ring, so coverage always exists.
    private func captureClip(sessionId: String, episodeId: String,
                             confirmingEvent: SnoreEvent) {
        guard clipCount < Self.maxClipsPerNight,
              let ring, let assembler else { return }
        let wantedStart = assembler.sampleIndex(
            forTMs: confirmingEvent.startMs - Self.clipPreRollMs)
        let start = max(wantedStart, ring.oldestAvailableIndex)
        let end = min(start + Self.clipLengthMs * 16, ring.totalWritten)
        guard let samples = ring.snapshot(from: start, to: end),
              !samples.isEmpty else { return }
        let clipStartMs = confirmingEvent.startMs - Self.clipPreRollMs
        let fileName = "clips/\(sessionId)/\(clipStartMs).m4a"
        let url = clipsRoot.appendingPathComponent(sessionId)
            .appendingPathComponent("\(clipStartMs).m4a")
        do {
            let written = try ClipWriter.write(samples: samples, to: url)
            try repository.insertClip(ClipRecord(
                id: UUID().uuidString, sessionId: sessionId,
                episodeId: episodeId, fileName: fileName,
                startMs: clipStartMs, durationMs: written.durationMs,
                peakDbfs: confirmingEvent.peakDbfs, bytes: written.bytes,
                createdAtMs: Int64(Date().timeIntervalSince1970 * 1000)))
            clipCount += 1
        } catch {
            // Clip failure degrades silently; metrics are untouched (spec §3.1).
        }
    }

    // MARK: interruptions (design-ios §2.3–2.5)

    private func handle(sessionEvent: AudioSessionCoordinator.SessionEvent) {
        guard session != nil else { return }
        switch sessionEvent {
        case .interruptionBegan:
            if let detector { handle(outputs: detector.flush()) }
            engine?.stop()
            gapStartMs = Int64(Date().timeIntervalSince1970 * 1000)

        case .interruptionEnded:
            resumeCapture(reason: .interruption)

        case .routeChanged:
            // Mic re-pinned by the coordinator. If the engine died with the
            // route change, restart it.
            if engine?.isRunning == false {
                resumeCapture(reason: .routeChange)
            }

        case .mediaServicesReset:
            engine?.stop()
            if gapStartMs == nil {
                gapStartMs = Int64(Date().timeIntervalSince1970 * 1000)
            }
            resumeCapture(reason: .unknown)
        }
    }

    private func resumeCapture(reason: GapRecord.Reason) {
        guard let record = session else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            try coordinator?.activate()
            let continueAt = engine?.deliveredSampleIndex ?? 0
            // Re-anchor tMs to wall clock at resume (spec §0.2).
            assembler = FrameAssembler(anchorMs: nowMs,
                                       anchorSampleIndex: continueAt)
            let engine = AudioCaptureEngine()
            try engine.start(startingAtSampleIndex: continueAt) { [weak self] chunk in
                Task { await self?.consume(chunk) }
            }
            self.engine = engine
            if let gapStart = gapStartMs {
                try? repository.insertGap(GapRecord(
                    id: UUID().uuidString, sessionId: record.id,
                    startMs: gapStart, endMs: nowMs, reason: reason))
                gapStartMs = nil
            }
        } catch {
            // Reactivation can fail while another app holds the session; the
            // watchdog (heartbeat tick) retries. TODO(M3): backoff ladder +
            // beginBackgroundTask wrapper per design-feasibility M2.
        }
    }

    private func heartbeatTick() {
        guard let record = session else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try? repository.heartbeat(sessionId: record.id, nowMs: nowMs)
        if engine?.isRunning == false && gapStartMs != nil {
            resumeCapture(reason: .interruption)   // watchdog retry
        }
        if nowMs - record.startedAtMs >= Self.maxSessionMs {
            _ = try? stop(reason: .autoStopped)
        }
    }

    private func teardownAudio() {
        engine?.stop()
        engine = nil
        classifier?.stop()
        classifier = nil
        coordinator?.stopObserving()
        coordinator?.deactivate()
        coordinator = nil
    }

    private func deviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0) ?? "unknown"
            }
        }
    }
}
