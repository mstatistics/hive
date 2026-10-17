CREATE TABLE control (          -- the things the greenhouse can actuate
  id          INTEGER PRIMARY KEY,
  name        TEXT NOT NULL UNIQUE,   -- 'light', 'fan', 'heater'
  unit        TEXT,                   -- '%', '°C', 'on/off'
  min_value   REAL,
  max_value   REAL
);

CREATE TABLE recipe (
  id          INTEGER PRIMARY KEY,
  name        TEXT NOT NULL,
  description TEXT
);

CREATE TABLE stage (
  id          INTEGER PRIMARY KEY,
  recipe_id   INTEGER NOT NULL REFERENCES recipe(id) ON DELETE CASCADE,
  name        TEXT,                   -- 'seedling', 'flowering'
  start_day   INTEGER NOT NULL,       -- inclusive, day 1 = planting
  end_day     INTEGER,                -- NULL = until the end
  CHECK (end_day IS NULL OR end_day >= start_day)
);

CREATE TABLE schedule_window (
  id          INTEGER PRIMARY KEY,
  stage_id    INTEGER NOT NULL REFERENCES stage(id) ON DELETE CASCADE,
  start_time  TEXT NOT NULL,          -- 'HH:MM' local time
  end_time    TEXT NOT NULL           -- may be < start_time for overnight
);

CREATE TABLE setpoint (
  window_id   INTEGER NOT NULL REFERENCES schedule_window(id) ON DELETE CASCADE,
  control_id  INTEGER NOT NULL REFERENCES control(id),
  value       REAL NOT NULL,
  PRIMARY KEY (window_id, control_id)
);