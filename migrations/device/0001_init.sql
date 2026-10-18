-- Device (SQLite) schema, migration 0001.
-- Applied by whichever process starts first; tracked with PRAGMA user_version.
-- Requires SQLite >= 3.37 (STRICT tables). Raspberry Pi OS Bookworm ships 3.40.
--
-- Per-connection settings (NOT stored in the file, set on every open, both Python and Node):
--   PRAGMA journal_mode = WAL;     -- persists in the file, but set it anyway
--   PRAGMA busy_timeout = 5000;
--   PRAGMA foreign_keys = ON;
--   PRAGMA synchronous = NORMAL;   -- safe with WAL, much less fsync wear on the SD card/SSD
--
-- WRITER RULES (keeps the two processes from fighting):
--   daemon (Python): readings, events, photos, rollups, status, sync_state
--   web (Node):      read-only; no direct writes
--   sync agent:      sync_state, photos.state, and cloud-origin recipe rows

BEGIN;

CREATE TABLE meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
) STRICT;
-- Expected keys: device_id (uuid), cloud_url, device_token_ref, schema_notes

-- ---------------------------------------------------------------- telemetry

CREATE TABLE readings (
  seq       INTEGER PRIMARY KEY AUTOINCREMENT,   -- sync cursor; AUTOINCREMENT so seq is never reused
  sensor_id TEXT    NOT NULL,                    -- 'temp_1', 'humidity_1', ...
  timestamp     INTEGER NOT NULL,                    -- UTC epoch milliseconds
  value     REAL    NOT NULL,
  UNIQUE (sensor_id, timestamp)                      -- same key the cloud dedupes on; also serves per-sensor range queries
) STRICT;
CREATE INDEX readings_ts ON readings (timestamp);    -- for retention pruning

-- Actuator changes, control decisions, sensor faults, system notes. Low volume.
CREATE TABLE events (
  seq      INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp    INTEGER NOT NULL,
  kind     TEXT NOT NULL CHECK (kind IN ('actuator', 'control', 'fault', 'system')),
  subject  TEXT NOT NULL,                        -- 'fan_1', 'temp_1', 'sync', ...
  data     TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(data)),
  clock_ok INTEGER NOT NULL DEFAULT 1 CHECK (clock_ok IN (0, 1))
) STRICT;
CREATE INDEX events_ts ON events (timestamp);

-- Local rollups, used when the UI is zoomed out. Store sum+count, not avg, so buckets merge correctly.
-- NOT synced: the cloud computes its own from raw rows.
CREATE TABLE rollups (
  sensor_id        TEXT    NOT NULL,
  bucket_s         INTEGER NOT NULL CHECK (bucket_s IN (60, 3600)),
  bucket_start_ms  INTEGER NOT NULL,
  n                INTEGER NOT NULL,
  sum              REAL    NOT NULL,
  min              REAL    NOT NULL,
  max              REAL    NOT NULL,
  PRIMARY KEY (sensor_id, bucket_s, bucket_start_ms)
) STRICT, WITHOUT ROWID;

-- Latest values and health, written by the daemon, read by the UI/SSE.
-- Keys like 'sensor:temp_1', 'actuator:fan_1', 'health:collector'.
CREATE TABLE status (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL CHECK (json_valid(value)),
  ts_ms INTEGER NOT NULL
) STRICT;

-- ------------------------------------------------------------------- photos

-- Photos do NOT use a cursor: uploads can finish out of order, so a cursor
-- would skip a photo whose upload failed while a later one succeeded.
-- Instead: state machine per row.
--   pending  -> file on disk only
--   uploaded -> object is in cloud storage
--   synced   -> cloud accepted the metadata row (only now is local deletion allowed)
CREATE TABLE photos (
  seq        INTEGER PRIMARY KEY AUTOINCREMENT,  -- also the idempotency key in the cloud (device_id, local_seq)
  ts_ms      INTEGER NOT NULL,
  path       TEXT    NOT NULL UNIQUE,            -- relative to the photo dir
  bytes      INTEGER NOT NULL,
  width      INTEGER,
  height     INTEGER,
  state      TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'uploaded', 'synced')),
  remote_key TEXT,                               -- object storage key, set at 'uploaded'
  attempts   INTEGER NOT NULL DEFAULT 0,
  clock_ok   INTEGER NOT NULL DEFAULT 1 CHECK (clock_ok IN (0, 1))
) STRICT;
CREATE INDEX photos_state ON photos (state) WHERE state <> 'synced';
CREATE INDEX photos_ts ON photos (ts_ms);

-- ------------------------------------------------------------------ recipes

-- Catalog of actuator types the greenhouse can control.
CREATE TABLE control (
  id        INTEGER PRIMARY KEY,
  name      TEXT NOT NULL UNIQUE,   -- 'light', 'fan', 'heater'
  unit      TEXT,                   -- '%', '°C', 'on/off'
  min_value REAL,
  max_value REAL
) STRICT;

-- A recipe is a named grow plan synced from the cloud.
CREATE TABLE recipe (
  id          INTEGER PRIMARY KEY,
  name        TEXT NOT NULL,
  description TEXT
) STRICT;

-- Stages divide a recipe by day range (day 1 = planting date).
CREATE TABLE stage (
  id        INTEGER PRIMARY KEY,
  recipe_id INTEGER NOT NULL REFERENCES recipe(id) ON DELETE CASCADE,
  name      TEXT,                   -- 'seedling', 'flowering'
  start_day INTEGER NOT NULL,       -- inclusive
  end_day   INTEGER,                -- NULL = until the end
  CHECK (end_day IS NULL OR end_day >= start_day)
) STRICT;

-- Time windows within a stage.
CREATE TABLE schedule_window (
  id         INTEGER PRIMARY KEY,
  stage_id   INTEGER NOT NULL REFERENCES stage(id) ON DELETE CASCADE,
  start_time TEXT NOT NULL,         -- 'HH:MM' local time
  end_time   TEXT NOT NULL          -- may be < start_time for overnight
) STRICT;

-- Target value for each actuator during a window.
CREATE TABLE setpoint (
  window_id  INTEGER NOT NULL REFERENCES schedule_window(id) ON DELETE CASCADE,
  control_id INTEGER NOT NULL REFERENCES control(id),
  value      REAL    NOT NULL,
  PRIMARY KEY (window_id, control_id)
) STRICT, WITHOUT ROWID;

-- --------------------------------------------------------------- sync state

CREATE TABLE sync_state (
  stream     TEXT PRIMARY KEY CHECK (stream IN ('readings', 'events')),
  cursor     INTEGER NOT NULL DEFAULT 0,         -- highest seq the cloud has confirmed persisted
  last_ok_ms INTEGER,
  last_error TEXT
) STRICT;
INSERT INTO sync_state (stream) VALUES ('readings'), ('events');

PRAGMA user_version = 1;
COMMIT;
