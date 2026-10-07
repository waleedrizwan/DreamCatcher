import XCTest
import GRDB
import SnoreCore
@testable import SnoreStorage

final class SchemaSyncTests: XCTestCase {
    /// The bundled DDL must be byte-identical to the normative file —
    /// spec/schema/v1.sql is the ONLY schema (spec §3).
    func testBundledSchemaMatchesSpec() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }  // → repo root
        let specSQL = try String(
            contentsOf: url.appendingPathComponent("spec/schema/v1.sql"),
            encoding: .utf8)
        let bundled = try String(
            contentsOf: Bundle.module.url(forResource: "v1", withExtension: "sql")!,
            encoding: .utf8)
        XCTAssertEqual(bundled, specSQL,
            "ios/Packages/SnoreStorage/Sources/SnoreStorage/Resources/v1.sql is out of sync with spec/schema/v1.sql — re-copy it")
    }

    func testMigrationCreatesAllTables() throws {
        let db = try AppDatabase.inMemory()
        let tables = try db.writer.read { dbc in
            try String.fetchAll(dbc, sql:
                "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'grdb%' ORDER BY name")
        }
        XCTAssertEqual(tables, ["clip", "episode", "event", "gap", "session"])
    }
}

final class SessionRepositoryTests: XCTestCase {

    func makeRepo() throws -> SessionRepository {
        SessionRepository(try AppDatabase.inMemory())
    }

    func startSession(_ repo: SessionRepository,
                      nowMs: Int64 = 1_700_000_000_000) throws -> SessionRecord {
        try repo.startSession(nowMs: nowMs, tzId: "America/Toronto",
                              tzOffsetMin: -300, params: DetectorParams(),
                              sensitivity: .medium, appVersion: "0.1.0",
                              deviceModel: "iPhone17,1")
    }

    func testNightOfGroupsPostAndPreMidnightTogether() {
        // 23:30 EDT Aug 9 (03:30 UTC Aug 10) and 01:30 EDT Aug 10 → same night.
        let lateEvening: Int64 = 1_786_332_600_000   // 2026-08-09 23:30 EDT
        let afterMidnight: Int64 = 1_786_339_800_000 // 2026-08-10 01:30 EDT
        XCTAssertEqual(
            SessionRecord.nightOf(startedAtMs: lateEvening, tzId: "America/Toronto"),
            "2026-08-09")
        XCTAssertEqual(
            SessionRecord.nightOf(startedAtMs: afterMidnight, tzId: "America/Toronto"),
            "2026-08-09")
    }

    func testEventEpisodeWritePolicyAndRollups() throws {
        let repo = try makeRepo()
        let session = try startSession(repo)
        let t0 = session.startedAtMs
        let params = DetectorParams()

        // Three events land as orphans, then the episode confirms and closes.
        var eventIds: [String] = []
        var events: [SnoreEvent] = []
        for i in 0..<3 {
            var ev = SnoreEvent(startMs: t0 + Int64(i) * 15_000, nfAtStart: -70)
            ev.endMs = ev.startMs + 2_000
            ev.peakDbfs = -40 + Double(i)   // last is loudest: -38 → relDb 32 → moderate
            ev.maxConf = 0.9
            events.append(ev)
            eventIds.append(try repo.recordEvent(sessionId: session.id, ev).id)
        }
        let epId = UUID().uuidString
        let confirmed = ConfirmedEpisode(id: 1, startMs: events[0].startMs,
                                         lastEventEndMs: events[2].endMs,
                                         eventCount: 3)
        try repo.confirmEpisode(sessionId: session.id, episodeId: epId,
                                confirmed: confirmed, eventIds: eventIds,
                                params: params, provisionalPeak: events[2])
        let closed = ClosedEpisode(id: 1, startMs: events[0].startMs,
                                   endMs: events[2].endMs, events: events,
                                   snoreMs: 6_000, peak: events[2],
                                   bucket: .moderate)
        try repo.closeEpisode(episodeId: epId, closed, params: params)

        // A lone orphan blip is discarded.
        var blip = SnoreEvent(startMs: t0 + 100_000, nfAtStart: -70)
        blip.endMs = blip.startMs + 1_500
        let blipId = try repo.recordEvent(sessionId: session.id, blip).id
        try repo.discardEvents(ids: [blipId])

        try repo.finalizeSession(sessionId: session.id,
                                 endMs: t0 + 8 * 3_600_000, endReason: .user)

        let stored = try repo.fetchSession(id: session.id)!
        XCTAssertEqual(stored.state, .completed)
        XCTAssertEqual(stored.snoreTimeMs, 6_000)
        XCTAssertEqual(stored.episodeCount, 1)
        XCTAssertEqual(stored.moderateMs, 6_000)
        XCTAssertEqual(stored.lightMs, 0)
        XCTAssertNil(stored.snoreScore, "snore_score must stay NULL in v1")

        // Debug assertion path: stored rollups == recompute (spec §5.1).
        let recomputed = try repo.recomputeRollups(sessionId: session.id)
        XCTAssertEqual(recomputed.snoreTimeMs, stored.snoreTimeMs)
        XCTAssertEqual(recomputed.episodeCount, stored.episodeCount)
    }

    func testCrashRecoveryReplaysOrphans() throws {
        let repo = try makeRepo()
        let session = try startSession(repo)
        let t0 = session.startedAtMs

        // Simulated crash: five orphan events over 40 s (confirmable group),
        // then two stragglers a minute later (discardable group). No episodes,
        // no finalize — the process "died".
        for i in 0..<5 {
            var ev = SnoreEvent(startMs: t0 + Int64(i) * 10_000, nfAtStart: -70)
            ev.endMs = ev.startMs + 2_000
            ev.peakDbfs = -33 - Double(i)
            ev.maxConf = 0.9
            try repo.recordEvent(sessionId: session.id, ev)
        }
        for i in 0..<2 {
            var ev = SnoreEvent(startMs: t0 + 120_000 + Int64(i) * 8_000,
                                nfAtStart: -70)
            ev.endMs = ev.startMs + 2_000
            ev.peakDbfs = -30
            try repo.recordEvent(sessionId: session.id, ev)
        }
        // Past the 2-minute keep threshold, so the discard rule does not apply.
        try repo.heartbeat(sessionId: session.id, nowMs: t0 + 400_000)

        let recovered = try repo.recoverOrphanSessions()
        XCTAssertEqual(recovered, [session.id])

        let stored = try repo.fetchSession(id: session.id)!
        XCTAssertEqual(stored.state, .recovered)
        XCTAssertEqual(stored.endReason, .crashRecovered)
        XCTAssertEqual(stored.endedAtMs, t0 + 400_000,
                       "end = max(heartbeat, last event end)")
        XCTAssertEqual(stored.episodeCount, 1)
        XCTAssertEqual(stored.snoreTimeMs, 10_000)

        let episodes = try repo.episodes(sessionId: session.id)
        XCTAssertEqual(episodes.count, 1)
        XCTAssertEqual(episodes[0].eventCount, 5)
        XCTAssertEqual(episodes[0].peakDbfs, -33, accuracy: 0.001,
                       "earliest-max peak rule")
        XCTAssertEqual(episodes[0].bucket, "moderate")

        // Straggler orphans were deleted; only linked events remain.
        let remaining = try repo.events(sessionId: session.id)
        XCTAssertEqual(remaining.count, 5)
        XCTAssertTrue(remaining.allSatisfy { $0.episodeId != nil })
    }

    /// Spec §3.1: a discarded session keeps its row marked `discarded`, loses
    /// every child row, and never appears in history.
    func testDiscardSessionMarksAndClearsChildren() throws {
        let repo = try makeRepo()
        let session = try startSession(repo)
        var ev = SnoreEvent(startMs: session.startedAtMs, nfAtStart: -70)
        ev.endMs = ev.startMs + 2_000
        try repo.recordEvent(sessionId: session.id, ev)
        try repo.discardSession(sessionId: session.id)

        XCTAssertEqual(try repo.fetchSession(id: session.id)?.state, .discarded)
        let count = try repo.db.writer.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM event") ?? -1
        }
        XCTAssertEqual(count, 0, "child rows must be cleared")
        XCTAssertFalse(try repo.recentSessions().contains { $0.id == session.id },
                       "discarded sessions never appear in history")
    }

    /// Spec §3.1: the under-2-minute rule applies on the crash-recovery path
    /// too — a night that died at 90 seconds is noise, not a report.
    func testCrashRecoveryDiscardsShortSessions() throws {
        let repo = try makeRepo()
        let session = try startSession(repo)
        var ev = SnoreEvent(startMs: session.startedAtMs + 10_000, nfAtStart: -70)
        ev.endMs = ev.startMs + 2_000
        ev.maxConf = 0.9
        try repo.recordEvent(sessionId: session.id, ev)
        try repo.heartbeat(sessionId: session.id,
                           nowMs: session.startedAtMs + 90_000)

        XCTAssertEqual(try repo.recoverOrphanSessions(), [],
                       "a 90-second crashed session is not recovered")
        XCTAssertEqual(try repo.fetchSession(id: session.id)?.state, .discarded)
    }

    func testClipExpiry() throws {
        let repo = try makeRepo()
        let session = try startSession(repo)
        let now: Int64 = session.startedAtMs
        let old = ClipRecord(id: UUID().uuidString, sessionId: session.id,
                             episodeId: UUID().uuidString,
                             fileName: "clips/\(session.id)/1.m4a",
                             startMs: 0, durationMs: 12_000, peakDbfs: -30,
                             bytes: 48_000,
                             createdAtMs: now - 91 * 86_400_000)
        let fresh = ClipRecord(id: UUID().uuidString, sessionId: session.id,
                               episodeId: UUID().uuidString,
                               fileName: "clips/\(session.id)/2.m4a",
                               startMs: 0, durationMs: 12_000, peakDbfs: -30,
                               bytes: 48_000,
                               createdAtMs: now - 10 * 86_400_000)
        // Parent episodes must exist (FK): insert minimal rows.
        for clip in [old, fresh] {
            try repo.db.writer.write { dbc in
                try EpisodeRecord(id: clip.episodeId, sessionId: session.id,
                                  startMs: 0, endMs: 1, eventCount: 3,
                                  snoreMs: 1, peakDbfs: -30, peakRelDb: 40,
                                  bucket: "loud").insert(dbc)
            }
            try repo.insertClip(clip)
        }
        let expired = try repo.expireClips(nowMs: now)
        XCTAssertEqual(expired, ["clips/\(session.id)/1.m4a"])
        XCTAssertEqual(try repo.clips(sessionId: session.id).count, 1)
    }
}
