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
        /// Low-disk degrade (spec §3.1): clips paused, metrics still running.
        public var clipsDisabled: Bool
        /// Classifier has stopped producing results (design-feasibility B1).
        public var classifierStalled: Bool
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
    private var chunkTask: Task<Void, Never>?
    private var chunkContinuation: AsyncStream<AudioCaptureEngine.Chunk>.Continuation?
    /// Bumped whenever the pipe is torn down, so a chunk the old consumer had
    /// already pulled is recognizable when it reaches `consume` afterwards.
    private var pipeGeneration = 0

    // Episode bookkeeping (write policy, spec §3)
    private var pendingEventIds: [String] = []
    private var confirmedEpisodeId: String?
    private var clipCount = 0
    private var eventsSoFar = 0
    private var episodesSoFar = 0
    private var inEpisodeNow = false

    // Interruption bookkeeping
    private var gapStartMs: Int64?
    private var resumeRetryTask: Task<Void, Never>?

    // Storage-full degrade ladder (spec §3.1)
    private var clipsDisabled = false
    private var writeFailureStreak = 0
    private static let maxWriteFailureStreak = 8

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
        resumeRetryTask?.cancel()
        resumeRetryTask = nil
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        params = DetectorParams.forSensitivity(sensitivity)

        let coordinator = AudioSessionCoordinator()
        try coordinator.activate()
        coordinator.startObserving { [weak self] event in
            Task { await self?.handle(sessionEvent: event) }
        }
        self.coordinator = coordinator

        // Everything from here can throw (DB insert, model load, engine
        // start). A half-started session reads as "recording" to the UI and
        // makes every later start() a silent no-op, so undo all of it.
        do {
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
            clipsDisabled = false
            writeFailureStreak = 0

            let classifier = makeClassifier()
            self.classifier = classifier
            try classifier.start { [weak self] scores in
                Task { await self?.attach(scores: scores) }
            }

            engine = try startEngine(startingAtSampleIndex: 0)
        } catch {
            rollBackFailedStart()
            throw error
        }

        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.heartbeatTick()
            }
        }
    }

    private func rollBackFailedStart() {
        resumeRetryTask?.cancel()
        resumeRetryTask = nil
        teardownAudio()
        if let record = session {
            try? repository.discardSession(sessionId: record.id)
        }
        session = nil
        detector = nil
        assembler = nil
        ring = nil
        gapStartMs = nil
    }

    @discardableResult
    public func stop(reason: SessionRecord.EndReason = .user,
                     state: SessionRecord.State = .completed) throws -> StopOutcome {
        guard let record = session else { return .discardedTooShort }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        resumeRetryTask?.cancel()
        resumeRetryTask = nil
        teardownAudio()
        flushDetector()
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
                                       endReason: reason, state: state)
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
            lastClassifierError: classifier?.lastError?.localizedDescription,
            clipsDisabled: clipsDisabled,
            classifierStalled: assembler?.classifierIsStale ?? false)
    }

    // MARK: audio path

    /// Chunks flow through one AsyncStream consumed by one task so they reach
    /// `consume` in capture order. One unstructured Task per chunk gives no
    /// ordering guarantee, and a reordered chunk would hand the classifier a
    /// backwards sample position and the ring buffer a scrambled window.
    private func startEngine(startingAtSampleIndex index: Int64) throws -> AudioCaptureEngine {
        stopChunkPipe()
        let (stream, continuation) = AsyncStream.makeStream(
            of: AudioCaptureEngine.Chunk.self)
        chunkContinuation = continuation
        let generation = pipeGeneration
        chunkTask = Task { [weak self] in
            for await chunk in stream {
                await self?.consume(chunk, generation: generation)
            }
        }
        let engine = AudioCaptureEngine()
        engine.onConfigurationChange = { [weak self] in
            Task { await self?.handle(sessionEvent: .configurationChanged) }
        }
        do {
            try engine.start(startingAtSampleIndex: index) { chunk in
                continuation.yield(chunk)
            }
        } catch {
            stopChunkPipe()
            throw error
        }
        return engine
    }

    private func stopEngine() {
        engine?.stop()
        stopChunkPipe()
    }

    private func stopChunkPipe() {
        pipeGeneration += 1
        chunkContinuation?.finish()
        chunkContinuation = nil
        chunkTask?.cancel()
        chunkTask = nil
    }

    private func consume(_ chunk: AudioCaptureEngine.Chunk, generation: Int) {
        guard session != nil else { return }
        // The engine's sample clock already counted this chunk, so the ring
        // (indexed by that clock) takes it even when it is stale.
        ring?.write(chunk.int16s)
        // Cancelling the old consumer does not abort a call it had already
        // made. A pre-gap chunk must not reach the flushed detector or shift
        // the re-anchored assembler's sample clock.
        guard generation == pipeGeneration, let assembler, let detector else { return }
        classifier?.process(samples: chunk.floats,
                            atSampleIndex: chunk.firstSampleIndex)
        for frame in assembler.push(chunk.floats) {
            handle(outputs: detector.process(frame))
        }
    }

    private func attach(scores: ClassifierScores) {
        guard session != nil, let assembler, let detector else { return }
        for frame in assembler.attach(scores: scores) {
            handle(outputs: detector.process(frame))
        }
    }

    /// Close out the detector at the end of a capture segment. The assembler
    /// may still hold the segment's last frame; it goes through first.
    private func flushDetector() {
        guard let detector else { return }
        for frame in assembler?.drain() ?? [] {
            handle(outputs: detector.process(frame))
        }
        handle(outputs: detector.flush())
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
                writeFailureStreak = 0
            } catch {
                // Storage-full degrade (spec §3.1): metrics writes failing must
                // never crash the night. Clips are already cut off by the disk
                // probe; a sustained streak of failed metrics writes means the
                // disk is truly gone — the heartbeat finalizes gracefully off
                // whatever rows made it in.
                writeFailureStreak += 1
                clipsDisabled = true
            }
        }
    }

    /// Confirmation-time clip (spec §4): the confirming event is guaranteed
    /// fresh in the 30 s ring, so coverage always exists.
    private func captureClip(sessionId: String, episodeId: String,
                             confirmingEvent: SnoreEvent) {
        guard clipCount < Self.maxClipsPerNight, !clipsDisabled,
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
            flushDetector()
            stopEngine()
            gapStartMs = Int64(Date().timeIntervalSince1970 * 1000)

        case .interruptionEnded:
            resumeCapture(reason: .interruption)

        case .routeChanged:
            // Mic re-pinned by the coordinator. If the engine died with the
            // route change, restart it.
            if engine?.isRunning == false {
                flushDetector()
                stopEngine()
                markGapStart()
                resumeCapture(reason: .routeChange)
            }

        case .configurationChanged:
            // Input format changed under the engine: the tap and converter are
            // bound to the old format, so tear down and rebuild at the new one.
            flushDetector()
            stopEngine()
            markGapStart()
            resumeCapture(reason: .routeChange)

        case .mediaServicesReset:
            // Every audio object belonged to the daemon that just died — the
            // classifier included (Apple guidance). Rebuild all of it.
            flushDetector()
            stopEngine()
            classifier?.stop()
            classifier = nil
            markGapStart()
            resumeCapture(reason: .unknown)
        }
    }

    /// Gap bookkeeping must open before any resume attempt: the watchdog only
    /// retries while a gap is open, so a resume that fails without one would
    /// leave the night silently dead.
    private func markGapStart() {
        if gapStartMs == nil {
            gapStartMs = Int64(Date().timeIntervalSince1970 * 1000)
        }
    }

    /// Resume after an interruption: one immediate attempt, then a backoff
    /// ladder inside a background assertion (design-feasibility M2 — the OS
    /// grants ~30 s of runtime after `interruptionEnded`; the ladder fits it).
    /// Beyond the ladder the 60 s heartbeat watchdog keeps retrying, and
    /// heartbeat recovery keeps the night honest regardless.
    private func resumeCapture(reason: GapRecord.Reason) {
        guard attemptResume(reason: reason) == false else { return }
        guard resumeRetryTask == nil else { return }
        let assertion = BackgroundAssertion(name: "snorelab.resume")
        resumeRetryTask = Task { [weak self] in
            defer { assertion.end() }
            for delay in [0.5, 2.0, 8.0, 20.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled,
                      let self, await self.session != nil else { return }
                if await self.attemptResume(reason: reason) { break }
            }
            await self?.clearResumeRetry()
        }
    }

    private func clearResumeRetry() {
        resumeRetryTask = nil
    }

    /// One resume attempt. Returns true when capture is running again.
    private func attemptResume(reason: GapRecord.Reason) -> Bool {
        guard let record = session else { return true }
        if engine?.isRunning == true { return true }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            try coordinator?.activate()
            let continueAt = engine?.deliveredSampleIndex ?? 0
            // Re-anchor tMs to wall clock at resume (spec §0.2).
            assembler = FrameAssembler(anchorMs: nowMs,
                                       anchorSampleIndex: continueAt)
            // A media-services reset takes the classifier with it.
            if classifier == nil {
                let fresh = makeClassifier()
                try fresh.start { [weak self] scores in
                    Task { await self?.attach(scores: scores) }
                }
                classifier = fresh
            }
            // The sample clock is contiguous across the gap, so the classifier
            // would otherwise splice pre-gap audio into its first window.
            classifier?.reset()
            engine = try startEngine(startingAtSampleIndex: continueAt)
            resumeRetryTask?.cancel()
            resumeRetryTask = nil
            if let gapStart = gapStartMs {
                try? repository.insertGap(GapRecord(
                    id: UUID().uuidString, sessionId: record.id,
                    startMs: gapStart, endMs: nowMs, reason: reason))
                gapStartMs = nil
            }
            return true
        } catch {
            // Another app may still hold the audio session; the ladder (and
            // then the watchdog) will try again.
            return false
        }
    }

    private func heartbeatTick() {
        guard let record = session else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try? repository.heartbeat(sessionId: record.id, nowMs: nowMs)
        if engine?.isRunning == false && gapStartMs != nil {
            resumeCapture(reason: .interruption)   // watchdog retry
        }
        // A stalled classifier with a live engine is the locked-screen failure
        // mode: audio keeps flowing, inference is dead. Rebuild it once per
        // tick — cheap, and it recovers the rest of the night if it was a
        // transient daemon fault rather than the permanent background-GPU ban.
        if engine?.isRunning == true, assembler?.classifierIsStale == true {
            classifier?.stop()
            classifier = nil
            let fresh = makeClassifier()
            if (try? fresh.start { [weak self] scores in
                Task { await self?.attach(scores: scores) }
            }) != nil {
                classifier = fresh
                assembler?.noteClassifierRestarted()
            }
        }
        // Storage-full degrade ladder (spec §3.1): clips stop first; at
        // critical the session finalizes gracefully instead of dying mid-write.
        let free = DiskSpace.freeBytes(at: clipsRoot)
        if free < DiskSpace.clipCutoffBytes { clipsDisabled = true }
        if free < DiskSpace.criticalBytes
            || writeFailureStreak >= Self.maxWriteFailureStreak {
            // Persistent write failure finalizes gracefully as `recovered`
            // rather than crash-looping (spec §3.1 storage-full).
            _ = try? stop(reason: .crashRecovered, state: .recovered)
            return
        }
        if nowMs - record.startedAtMs >= Self.maxSessionMs {
            _ = try? stop(reason: .autoStopped)
        }
    }

    private func teardownAudio() {
        stopEngine()
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
