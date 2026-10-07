import Foundation
import GRDB
import SnoreCore

/// Implements the write policy of spec §3: events land the moment they close,
/// episodes at confirm/close, rollups only at finalize — which is exactly what
/// makes crash recovery a pure replay.
public struct SessionRepository: Sendable {
    public let db: AppDatabase

    public init(_ db: AppDatabase) {
        self.db = db
    }

    // MARK: session lifecycle

    public func startSession(nowMs: Int64, tzId: String, tzOffsetMin: Int,
                             params: DetectorParams, sensitivity: Sensitivity,
                             appVersion: String, deviceModel: String) throws -> SessionRecord {
        let paramsJson = String(
            data: try JSONEncoder().encode(ParamsSnapshot(params: params,
                                                          sensitivity: sensitivity)),
            encoding: .utf8)!
        let record = SessionRecord(
            id: UUID().uuidString,
            startedAtMs: nowMs,
            endedAtMs: nil,
            tzId: tzId,
            tzOffsetMin: tzOffsetMin,
            nightOf: SessionRecord.nightOf(startedAtMs: nowMs, tzId: tzId),
            state: .recording,
            endReason: nil,
            lastHeartbeatMs: nowMs,
            snoreTimeMs: nil, episodeCount: nil, snoreScore: nil,
            lightMs: nil, moderateMs: nil, loudMs: nil,
            noiseFloorDbfs: nil, clipCount: nil, gapCount: nil,
            detectorParamsJson: paramsJson,
            appVersion: appVersion,
            deviceModel: deviceModel,
            createdAtMs: nowMs)
        try db.writer.write { try record.insert($0) }
        return record
    }

    public struct ParamsSnapshot: Codable, Sendable {
        public var params: DetectorParams
        public var sensitivity: Sensitivity
    }

    public func heartbeat(sessionId: String, nowMs: Int64) throws {
        try db.writer.write { dbc in
            try dbc.execute(
                sql: "UPDATE session SET last_heartbeat_ms = ? WHERE id = ?",
                arguments: [nowMs, sessionId])
        }
    }

    // MARK: detector output writes (spec §3 write policy)

    @discardableResult
    public func recordEvent(sessionId: String, _ ev: SnoreEvent) throws -> EventRecord {
        let record = EventRecord(id: UUID().uuidString, sessionId: sessionId,
                                 episodeId: nil, startMs: ev.startMs, endMs: ev.endMs,
                                 peakDbfs: ev.peakDbfs, maxConf: ev.maxConf,
                                 nfDbfs: ev.nfAtStart)
        try db.writer.write { try record.insert($0) }
        return record
    }

    /// EpisodeConfirmed: insert the episode row (provisional end) and claim its
    /// events, one transaction.
    public func confirmEpisode(sessionId: String, episodeId: String,
                               confirmed: ConfirmedEpisode,
                               eventIds: [String], params: DetectorParams,
                               provisionalPeak: SnoreEvent) throws {
        let record = EpisodeRecord(
            id: episodeId, sessionId: sessionId,
            startMs: confirmed.startMs, endMs: confirmed.lastEventEndMs,
            eventCount: confirmed.eventCount, snoreMs: 0,   // finalized at close
            peakDbfs: provisionalPeak.peakDbfs,
            peakRelDb: provisionalPeak.relDb(),
            bucket: provisionalPeak.bucket(params).rawValue)
        try db.writer.write { dbc in
            try record.insert(dbc)
            try dbc.execute(
                sql: """
                UPDATE event SET episode_id = ?
                WHERE id IN (\(eventIds.map { _ in "?" }.joined(separator: ",")))
                """,
                arguments: StatementArguments([episodeId] + eventIds))
        }
    }

    /// EpisodeClosed: finalize the episode row and (belt-and-suspenders) claim
    /// any events that landed after confirmation, one transaction.
    public func closeEpisode(episodeId: String, _ closed: ClosedEpisode,
                             params: DetectorParams,
                             eventIds: [String] = []) throws {
        try db.writer.write { dbc in
            try dbc.execute(
                sql: """
                UPDATE episode SET end_ms = ?, event_count = ?, snore_ms = ?,
                    peak_dbfs = ?, peak_rel_db = ?, bucket = ?
                WHERE id = ?
                """,
                arguments: [closed.endMs, closed.events.count, closed.snoreMs,
                            closed.peak.peakDbfs, closed.peak.relDb(),
                            closed.bucket.rawValue, episodeId])
            if !eventIds.isEmpty {
                try dbc.execute(
                    sql: """
                    UPDATE event SET episode_id = ?
                    WHERE id IN (\(eventIds.map { _ in "?" }.joined(separator: ",")))
                    """,
                    arguments: StatementArguments([episodeId] + eventIds))
            }
        }
    }

    /// EpisodeDiscarded: the pending episode's events leave all metrics.
    public func discardEvents(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try db.writer.write { dbc in
            try dbc.execute(
                sql: "DELETE FROM event WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))",
                arguments: StatementArguments(ids))
        }
    }

    public func insertClip(_ clip: ClipRecord) throws {
        try db.writer.write { try clip.insert($0) }
    }

    public func insertGap(_ gap: GapRecord) throws {
        try db.writer.write { try gap.insert($0) }
    }

    // MARK: finalize / discard / recover (spec §3.1)

    public func finalizeSession(sessionId: String, endMs: Int64,
                                endReason: SessionRecord.EndReason,
                                state: SessionRecord.State = .completed) throws {
        let rollup = try recomputeRollups(sessionId: sessionId)
        try db.writer.write { dbc in
            try dbc.execute(
                sql: """
                UPDATE session SET ended_at_ms = ?, state = ?, end_reason = ?,
                    snore_time_ms = ?, episode_count = ?,
                    light_ms = ?, moderate_ms = ?, loud_ms = ?,
                    noise_floor_dbfs = ?,
                    clip_count = (SELECT COUNT(*) FROM clip WHERE session_id = ?),
                    gap_count = (SELECT COUNT(*) FROM gap WHERE session_id = ?)
                WHERE id = ?
                """,
                arguments: [endMs, state.rawValue, endReason.rawValue,
                            rollup.snoreTimeMs, rollup.episodeCount,
                            rollup.lightMs, rollup.moderateMs, rollup.loudMs,
                            rollup.noiseFloorDbfs,
                            sessionId, sessionId, sessionId])
        }
    }

    /// Sessions under 2 minutes are discarded (spec §3.1): the session row is
    /// marked `discarded` and its children are deleted; the caller deletes the
    /// clip files. Discarded sessions never appear in history.
    public func discardSession(sessionId: String) throws {
        try db.writer.write { dbc in
            for table in ["clip", "gap", "event", "episode"] {
                try dbc.execute(sql: "DELETE FROM \(table) WHERE session_id = ?",
                                arguments: [sessionId])
            }
            try dbc.execute(
                sql: "UPDATE session SET state = 'discarded' WHERE id = ?",
                arguments: [sessionId])
        }
    }

    /// Minimum session length worth keeping (spec §3.1) — shared by the normal
    /// stop path and crash recovery.
    public static let minSessionMs: Int64 = 2 * 60_000

    /// Crash recovery (spec §3.1): every session still in state 'recording' is
    /// finalized from its persisted rows. Returns the recovered session ids
    /// (sessions too short to keep are discarded, not recovered).
    ///
    /// Callers run this at launch, before any new session starts, so every
    /// 'recording' row is by definition orphaned.
    @discardableResult
    public func recoverOrphanSessions() throws -> [String] {
        let stale = try db.writer.read { dbc in
            try SessionRecord
                .filter(sql: "state = 'recording'")
                .fetchAll(dbc)
        }
        var recovered: [String] = []
        for session in stale {
            // A night that died in its first few minutes is noise, however it
            // ended (spec §3.1 discard rule applies on this path too).
            let lastKnownMs = try db.writer.read { dbc in
                try Int64.fetchOne(dbc,
                    sql: "SELECT MAX(end_ms) FROM event WHERE session_id = ?",
                    arguments: [session.id])
            }
            if max(session.lastHeartbeatMs, lastKnownMs ?? 0)
                - session.startedAtMs < Self.minSessionMs {
                try discardSession(sessionId: session.id)
                continue
            }
            let params = decodeParams(session.detectorParamsJson)
            let orphans = try db.writer.read { dbc in
                try EventRecord
                    .filter(sql: "session_id = ? AND episode_id IS NULL",
                            arguments: [session.id])
                    .order(sql: "start_ms")
                    .fetchAll(dbc)
            }
            let replay = EventReplay.replay(orphans.map(\.asOrphan), params: params)
            try db.writer.write { dbc in
                for episode in replay.episodes {
                    let epId = UUID().uuidString
                    let rel = episode.peak.peakDbfs - episode.peak.nfDbfs
                    try EpisodeRecord(
                        id: epId, sessionId: session.id,
                        startMs: episode.startMs, endMs: episode.endMs,
                        eventCount: episode.events.count, snoreMs: episode.snoreMs,
                        peakDbfs: episode.peak.peakDbfs, peakRelDb: rel,
                        bucket: episode.bucket.rawValue).insert(dbc)
                    for ev in episode.events {
                        try dbc.execute(
                            sql: """
                            UPDATE event SET episode_id = ?
                            WHERE session_id = ? AND start_ms = ? AND episode_id IS NULL
                            """,
                            arguments: [epId, session.id, ev.startMs])
                    }
                }
                // Events in groups that never confirmed leave all metrics.
                try dbc.execute(
                    sql: "DELETE FROM event WHERE session_id = ? AND episode_id IS NULL",
                    arguments: [session.id])
            }
            let lastEventEnd = try db.writer.read { dbc in
                try Int64.fetchOne(dbc,
                    sql: "SELECT MAX(end_ms) FROM event WHERE session_id = ?",
                    arguments: [session.id])
            }
            let endMs = max(session.lastHeartbeatMs, lastEventEnd ?? 0)
            try finalizeSession(sessionId: session.id, endMs: endMs,
                                endReason: .crashRecovered, state: .recovered)
            recovered.append(session.id)
        }
        return recovered
    }

    // MARK: rollups (spec §2 / §5.1 debug assertion)

    public struct Rollups: Equatable, Sendable {
        public var snoreTimeMs: Int64
        public var episodeCount: Int
        public var lightMs: Int64
        public var moderateMs: Int64
        public var loudMs: Int64
        public var noiseFloorDbfs: Double?
    }

    /// Recompute the session rollups from episode/event rows. This is both the
    /// finalize path AND the debug assertion that stored rollups are honest.
    public func recomputeRollups(sessionId: String) throws -> Rollups {
        guard let session = try fetchSession(id: sessionId) else {
            return Rollups(snoreTimeMs: 0, episodeCount: 0, lightMs: 0,
                           moderateMs: 0, loudMs: 0, noiseFloorDbfs: nil)
        }
        let params = decodeParams(session.detectorParamsJson)
        return try db.writer.read { dbc in
            let events = try EventRecord
                .filter(sql: "session_id = ? AND episode_id IS NOT NULL",
                        arguments: [sessionId])
                .fetchAll(dbc)
            var snore: Int64 = 0
            var light: Int64 = 0, moderate: Int64 = 0, loud: Int64 = 0
            var floors: [Double] = []
            for ev in events {
                let dur = ev.endMs - ev.startMs
                snore += dur
                let rel = ev.peakDbfs - ev.nfDbfs
                if rel < params.intensityLightMaxDb { light += dur }
                else if rel < params.intensityModMaxDb { moderate += dur }
                else { loud += dur }
                floors.append(ev.nfDbfs)
            }
            let count = try Int.fetchOne(dbc,
                sql: "SELECT COUNT(*) FROM episode WHERE session_id = ?",
                arguments: [sessionId]) ?? 0
            return Rollups(snoreTimeMs: snore, episodeCount: count,
                           lightMs: light, moderateMs: moderate, loudMs: loud,
                           noiseFloorDbfs: SessionMetrics.median(floors))
        }
    }

    func decodeParams(_ json: String) -> DetectorParams {
        (try? JSONDecoder().decode(ParamsSnapshot.self,
                                   from: Data(json.utf8)))?.params ?? DetectorParams()
    }

    // MARK: queries for UI

    public func fetchSession(id: String) throws -> SessionRecord? {
        try db.writer.read { try SessionRecord.fetchOne($0, key: id) }
    }

    /// History list: newest first, discarded sessions never appear.
    public func recentSessions(limit: Int = 90) throws -> [SessionRecord] {
        try db.writer.read { dbc in
            try SessionRecord
                .filter(sql: "state IN ('completed','recovered')")
                .order(sql: "started_at_ms DESC")
                .limit(limit)
                .fetchAll(dbc)
        }
    }

    public func episodes(sessionId: String) throws -> [EpisodeRecord] {
        try db.writer.read { dbc in
            try EpisodeRecord.filter(sql: "session_id = ?", arguments: [sessionId])
                .order(sql: "start_ms").fetchAll(dbc)
        }
    }

    public func events(sessionId: String) throws -> [EventRecord] {
        try db.writer.read { dbc in
            try EventRecord.filter(sql: "session_id = ?", arguments: [sessionId])
                .order(sql: "start_ms").fetchAll(dbc)
        }
    }

    public func clips(sessionId: String) throws -> [ClipRecord] {
        try db.writer.read { dbc in
            try ClipRecord.filter(sql: "session_id = ?", arguments: [sessionId])
                .order(sql: "start_ms").fetchAll(dbc)
        }
    }

    public func gaps(sessionId: String) throws -> [GapRecord] {
        try db.writer.read { dbc in
            try GapRecord.filter(sql: "session_id = ?", arguments: [sessionId])
                .order(sql: "start_ms").fetchAll(dbc)
        }
    }

    /// Trend series for History (spec §5.2): one point per RECORDED night,
    /// newest first. Nights with no session are simply absent — they are gaps,
    /// never zeros, and they never dilute the averages.
    public struct NightPoint: Equatable, Sendable {
        public var nightOf: String
        public var sessionId: String
        public var snoreTimeMs: Int64
        public var episodeCount: Int
        public var inBedMs: Int64
    }

    public func nightTrend(limit: Int = 30) throws -> [NightPoint] {
        try recentSessions(limit: limit).map { s in
            NightPoint(
                nightOf: s.nightOf,
                sessionId: s.id,
                snoreTimeMs: s.snoreTimeMs ?? 0,
                episodeCount: s.episodeCount ?? 0,
                inBedMs: (s.endedAtMs ?? s.startedAtMs) - s.startedAtMs)
        }
    }

    /// Every clip file the DB still references. The launch-time orphan GC
    /// (spec §4) deletes any file on disk that is not in this set.
    public func allClipFileNames() throws -> Set<String> {
        try db.writer.read { dbc in
            Set(try String.fetchAll(dbc, sql: "SELECT file_name FROM clip"))
        }
    }

    /// Clip retention (spec §4): delete clip rows older than 90 days and
    /// report the file names so the caller can delete the audio files.
    public func expireClips(nowMs: Int64,
                            retentionDays: Int = 90) throws -> [String] {
        let cutoff = nowMs - Int64(retentionDays) * 86_400_000
        return try db.writer.write { dbc in
            let expired = try ClipRecord
                .filter(sql: "created_at_ms < ?", arguments: [cutoff])
                .fetchAll(dbc)
            try dbc.execute(sql: "DELETE FROM clip WHERE created_at_ms < ?",
                            arguments: [cutoff])
            return expired.map(\.fileName)
        }
    }
}
