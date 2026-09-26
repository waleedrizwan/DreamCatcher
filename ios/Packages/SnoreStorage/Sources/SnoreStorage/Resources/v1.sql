-- DREAM CATCHER — normative schema v1
-- This file is the ONLY DDL. iOS (GRDB) executes it verbatim; Android Room
-- entities are written to match it and CI diffs Room's exported schema
-- against this file. See spec/SHARED_BEHAVIOR_SPEC.md §3.
--
-- Conventions: all timestamps INTEGER epoch milliseconds UTC; all ids UUIDv4 TEXT.
-- Versioning: PRAGMA user_version = 1; sequential numbered migrations.

PRAGMA user_version = 1;

CREATE TABLE session (
  id                   TEXT PRIMARY KEY,
  started_at_ms        INTEGER NOT NULL,
  ended_at_ms          INTEGER,              -- NULL while recording
  tz_id                TEXT NOT NULL,        -- IANA, e.g. 'America/Toronto', captured at start
  tz_offset_min        INTEGER NOT NULL,     -- UTC offset at start (display fallback)
  night_of             TEXT NOT NULL,        -- 'YYYY-MM-DD': local date of (started_at - 12h) in tz_id
  state                TEXT NOT NULL,        -- 'recording' | 'completed' | 'recovered' | 'discarded'
  end_reason           TEXT,                 -- 'user' | 'auto_stopped' | 'crash_recovered' | NULL while recording
  last_heartbeat_ms    INTEGER NOT NULL,     -- updated every 60 s while recording
  -- Rollups: written at finalize only; MUST equal recompute from episode/event rows
  -- (debug builds assert equality on every report render).
  snore_time_ms        INTEGER,
  episode_count        INTEGER,
  snore_score          INTEGER,              -- reserved, always NULL in v1 (post-MVP)
  light_ms             INTEGER,
  moderate_ms          INTEGER,
  loud_ms              INTEGER,
  noise_floor_dbfs     REAL,                 -- median nf_dbfs over events; NULL if no events
  clip_count           INTEGER,
  gap_count            INTEGER,
  detector_params_json TEXT NOT NULL,        -- exact effective constants used this night
  app_version          TEXT NOT NULL,
  device_model         TEXT NOT NULL,
  created_at_ms        INTEGER NOT NULL
);
CREATE INDEX idx_session_night   ON session(night_of);
CREATE INDEX idx_session_started ON session(started_at_ms DESC);

CREATE TABLE episode (
  id           TEXT PRIMARY KEY,
  session_id   TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
  start_ms     INTEGER NOT NULL,
  end_ms       INTEGER NOT NULL,             -- provisional (= last event end) at confirm; final at close
  event_count  INTEGER NOT NULL,
  snore_ms     INTEGER NOT NULL,             -- sum of event durations
  peak_dbfs    REAL NOT NULL,
  peak_rel_db  REAL NOT NULL,                -- peak event: peak_dbfs - nf_dbfs at event start
  bucket       TEXT NOT NULL                 -- 'light' | 'moderate' | 'loud'
);
CREATE INDEX idx_episode_session ON episode(session_id);

-- The crash-recovery and recompute backbone: one row per valid detector event,
-- inserted the moment the event closes (episode_id NULL until its episode confirms;
-- deleted if the episode is discarded).
CREATE TABLE event (
  id         TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
  episode_id TEXT REFERENCES episode(id) ON DELETE CASCADE,
  start_ms   INTEGER NOT NULL,
  end_ms     INTEGER NOT NULL,
  peak_dbfs  REAL NOT NULL,
  max_conf   REAL NOT NULL,
  nf_dbfs    REAL NOT NULL                   -- noise floor at event start (basis of relative intensity)
);
CREATE INDEX idx_event_session ON event(session_id);
CREATE INDEX idx_event_episode ON event(episode_id);

CREATE TABLE clip (
  id            TEXT PRIMARY KEY,
  session_id    TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
  episode_id    TEXT NOT NULL REFERENCES episode(id) ON DELETE CASCADE,
  file_name     TEXT NOT NULL,               -- relative: clips/<session_id>/<clip_start_ms>.m4a
  start_ms      INTEGER NOT NULL,
  duration_ms   INTEGER NOT NULL,            -- nominal 12000, clamped to available audio
  peak_dbfs     REAL NOT NULL,
  bytes         INTEGER NOT NULL,
  created_at_ms INTEGER NOT NULL
);
CREATE INDEX idx_clip_session ON clip(session_id);

-- Capture interruptions; rendered as gray segments on the timeline.
CREATE TABLE gap (
  id         TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
  start_ms   INTEGER NOT NULL,
  end_ms     INTEGER NOT NULL,
  reason     TEXT NOT NULL                   -- 'interruption' | 'mic_silenced' | 'route_change' | 'unknown'
);
CREATE INDEX idx_gap_session ON gap(session_id);
