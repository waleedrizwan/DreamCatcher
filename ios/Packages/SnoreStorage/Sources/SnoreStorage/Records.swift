import Foundation
import GRDB
import SnoreCore

/// Row types mirror spec/schema/v1.sql exactly — column names are the
/// snake_case schema names via CodingKeys.

public struct SessionRecord: Codable, Equatable, Sendable,
    FetchableRecord, PersistableRecord {
    public static let databaseTableName = "session"

    public var id: String
    public var startedAtMs: Int64
    public var endedAtMs: Int64?
    public var tzId: String
    public var tzOffsetMin: Int
    public var nightOf: String
    public var state: State
    public var endReason: EndReason?
    public var lastHeartbeatMs: Int64
    public var snoreTimeMs: Int64?
    public var episodeCount: Int?
    public var snoreScore: Int?          // reserved, always nil in v1
    public var lightMs: Int64?
    public var moderateMs: Int64?
    public var loudMs: Int64?
    public var noiseFloorDbfs: Double?
    public var clipCount: Int?
    public var gapCount: Int?
    public var detectorParamsJson: String
    public var appVersion: String
    public var deviceModel: String
    public var createdAtMs: Int64

    public enum State: String, Codable, Sendable {
        case recording, completed, recovered, discarded
    }

    public enum EndReason: String, Codable, Sendable {
        case user, autoStopped = "auto_stopped", crashRecovered = "crash_recovered"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case startedAtMs = "started_at_ms"
        case endedAtMs = "ended_at_ms"
        case tzId = "tz_id"
        case tzOffsetMin = "tz_offset_min"
        case nightOf = "night_of"
        case state
        case endReason = "end_reason"
        case lastHeartbeatMs = "last_heartbeat_ms"
        case snoreTimeMs = "snore_time_ms"
        case episodeCount = "episode_count"
        case snoreScore = "snore_score"
        case lightMs = "light_ms"
        case moderateMs = "moderate_ms"
        case loudMs = "loud_ms"
        case noiseFloorDbfs = "noise_floor_dbfs"
        case clipCount = "clip_count"
        case gapCount = "gap_count"
        case detectorParamsJson = "detector_params_json"
        case appVersion = "app_version"
        case deviceModel = "device_model"
        case createdAtMs = "created_at_ms"
    }

    /// Grouping key (spec §3.1): local calendar date of (start − 12 h) in the
    /// session's own zone.
    public static func nightOf(startedAtMs: Int64, tzId: String) -> String {
        let date = Date(timeIntervalSince1970: Double(startedAtMs) / 1000 - 12 * 3600)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tzId) ?? .current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}

public struct EpisodeRecord: Codable, Equatable, Sendable,
    FetchableRecord, PersistableRecord {
    public static let databaseTableName = "episode"

    public var id: String
    public var sessionId: String
    public var startMs: Int64
    public var endMs: Int64
    public var eventCount: Int
    public var snoreMs: Int64
    public var peakDbfs: Double
    public var peakRelDb: Double
    public var bucket: String            // IntensityBucket.rawValue

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case startMs = "start_ms"
        case endMs = "end_ms"
        case eventCount = "event_count"
        case snoreMs = "snore_ms"
        case peakDbfs = "peak_dbfs"
        case peakRelDb = "peak_rel_db"
        case bucket
    }
}

public struct EventRecord: Codable, Equatable, Sendable,
    FetchableRecord, PersistableRecord {
    public static let databaseTableName = "event"

    public var id: String
    public var sessionId: String
    public var episodeId: String?        // NULL until the episode confirms
    public var startMs: Int64
    public var endMs: Int64
    public var peakDbfs: Double
    public var maxConf: Double
    public var nfDbfs: Double

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case episodeId = "episode_id"
        case startMs = "start_ms"
        case endMs = "end_ms"
        case peakDbfs = "peak_dbfs"
        case maxConf = "max_conf"
        case nfDbfs = "nf_dbfs"
    }

    public var asOrphan: EventReplay.OrphanEvent {
        EventReplay.OrphanEvent(startMs: startMs, endMs: endMs,
                                peakDbfs: peakDbfs, maxConf: maxConf,
                                nfDbfs: nfDbfs)
    }
}

public struct ClipRecord: Codable, Equatable, Sendable,
    FetchableRecord, PersistableRecord {
    public static let databaseTableName = "clip"

    public var id: String
    public var sessionId: String
    public var episodeId: String
    public var fileName: String          // relative: clips/<session_id>/<start_ms>.m4a
    public var startMs: Int64
    public var durationMs: Int64
    public var peakDbfs: Double
    public var bytes: Int64
    public var createdAtMs: Int64

    public init(id: String, sessionId: String, episodeId: String,
                fileName: String, startMs: Int64, durationMs: Int64,
                peakDbfs: Double, bytes: Int64, createdAtMs: Int64) {
        self.id = id
        self.sessionId = sessionId
        self.episodeId = episodeId
        self.fileName = fileName
        self.startMs = startMs
        self.durationMs = durationMs
        self.peakDbfs = peakDbfs
        self.bytes = bytes
        self.createdAtMs = createdAtMs
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case episodeId = "episode_id"
        case fileName = "file_name"
        case startMs = "start_ms"
        case durationMs = "duration_ms"
        case peakDbfs = "peak_dbfs"
        case bytes
        case createdAtMs = "created_at_ms"
    }
}

public struct GapRecord: Codable, Equatable, Sendable,
    FetchableRecord, PersistableRecord {
    public static let databaseTableName = "gap"

    public var id: String
    public var sessionId: String
    public var startMs: Int64
    public var endMs: Int64
    public var reason: Reason

    public enum Reason: String, Codable, Sendable {
        case interruption, micSilenced = "mic_silenced",
             routeChange = "route_change", unknown
    }

    public init(id: String, sessionId: String, startMs: Int64, endMs: Int64,
                reason: Reason) {
        self.id = id
        self.sessionId = sessionId
        self.startMs = startMs
        self.endMs = endMs
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case startMs = "start_ms"
        case endMs = "end_ms"
        case reason
    }
}
