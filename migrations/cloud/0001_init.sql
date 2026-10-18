-- Cloud (Postgres >= 14) schema, migration 0001.
-- Run as the OWNER role (never use the owner from the app: owners bypass RLS).
--
-- Roles
--   app_web     web requests made on behalf of a logged-in user
--   app_ingest  device-facing endpoints (ingest, config/command pull, claim)
--   owner       runs migrations and pg_cron jobs (bypasses RLS on purpose)
-- Set passwords outside this file: ALTER ROLE app_web PASSWORD '...';
--
-- Per-request contract (always inside ONE transaction, via ONE helper in the app):
--   web:    SELECT set_config('app.user_id',   $userId,   true);
--   ingest: SELECT set_config('app.device_id', $deviceId, true);
--           SELECT set_config('app.tenant_id', $tenantId, true);
-- `true` = transaction-local, so it is safe behind a transaction-mode pooler.
--
-- Better Auth owns its own tables ("user", "session", ...). We reference user ids
-- as plain text with no FK, so auth migrations stay independent of ours.

BEGIN;

CREATE SCHEMA IF NOT EXISTS app;

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_web')    THEN CREATE ROLE app_web    LOGIN; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_ingest') THEN CREATE ROLE app_ingest LOGIN; END IF;
END $$;

GRANT USAGE ON SCHEMA app TO app_web, app_ingest;

-- ----------------------------------------------------------- session helpers

CREATE FUNCTION app.user_id() RETURNS text
  LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('app.user_id', true), '') $$;

CREATE FUNCTION app.device_id() RETURNS uuid
  LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('app.device_id', true), '')::uuid $$;

CREATE FUNCTION app.tenant_id() RETURNS uuid
  LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('app.tenant_id', true), '')::uuid $$;

-- ------------------------------------------------------------ tenancy tables

CREATE TABLE tenants (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name       text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE tenant_members (
  tenant_id uuid NOT NULL REFERENCES tenants (id) ON DELETE CASCADE,
  user_id   text NOT NULL,                      -- Better Auth user id
  role      text NOT NULL CHECK (role IN ('owner', 'admin', 'member', 'viewer')),
  PRIMARY KEY (tenant_id, user_id)
);
CREATE INDEX tenant_members_user ON tenant_members (user_id);

-- Tenants the current user belongs to. Runs as the caller, so tenant_members' own
-- RLS applies (a user only sees their own membership rows), which avoids recursion.
CREATE FUNCTION app.my_tenants() RETURNS SETOF uuid
  LANGUAGE sql STABLE AS $$ SELECT tenant_id FROM tenant_members WHERE user_id = app.user_id() $$;

CREATE FUNCTION app.can_write(p_tenant uuid) RETURNS boolean
  LANGUAGE sql STABLE AS $$
    SELECT EXISTS (SELECT 1 FROM tenant_members
                   WHERE tenant_id = p_tenant AND user_id = app.user_id() AND role <> 'viewer')
  $$;

-- Device identity is independent of any user, so ownership can move between tenants later.
CREATE TABLE devices (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL REFERENCES tenants (id),
  name         text NOT NULL,
  claimed_at   timestamptz,
  last_seen_at timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id)                        -- target for composite FKs below
);

CREATE TABLE device_tokens (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  device_id    uuid NOT NULL REFERENCES devices (id) ON DELETE CASCADE,
  token_hash   bytea NOT NULL UNIQUE,           -- sha256 of a 32-byte random token; plaintext is never stored
  created_at   timestamptz NOT NULL DEFAULT now(),
  revoked_at   timestamptz
);

-- Provisioning: a signed-in user generates a short code (stored hashed, short expiry),
-- types it into the device, and the device exchanges it for a token via app.claim_device().
CREATE TABLE claim_codes (
  code_hash  bytea PRIMARY KEY,
  tenant_id  uuid NOT NULL REFERENCES tenants (id) ON DELETE CASCADE,
  created_by text NOT NULL,
  expires_at timestamptz NOT NULL,
  used_at    timestamptz,
  device_id  uuid REFERENCES devices (id)
);

-- Narrow SECURITY DEFINER doors for the two things the device must do before it has an identity.
CREATE FUNCTION app.claim_device(p_code_hash bytea, p_token_hash bytea, p_name text)
  RETURNS TABLE (out_device_id uuid, out_tenant_id uuid)
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  c public.claim_codes%ROWTYPE;
  d uuid;
BEGIN
  SELECT * INTO c FROM public.claim_codes
   WHERE code_hash = p_code_hash AND used_at IS NULL AND expires_at > now()
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'invalid or expired claim code' USING ERRCODE = '28000';
  END IF;
  INSERT INTO public.devices (tenant_id, name, claimed_at) VALUES (c.tenant_id, p_name, now())
    RETURNING id INTO d;
  INSERT INTO public.device_tokens (device_id, token_hash) VALUES (d, p_token_hash);
  UPDATE public.claim_codes SET used_at = now(), device_id = d WHERE code_hash = p_code_hash;
  RETURN QUERY SELECT d, c.tenant_id;
END $$;

CREATE FUNCTION app.authenticate_device(p_token_hash bytea)
  RETURNS TABLE (out_device_id uuid, out_tenant_id uuid)
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
    SELECT d.id, d.tenant_id
      FROM public.device_tokens t JOIN public.devices d ON d.id = t.device_id
     WHERE t.token_hash = p_token_hash AND t.revoked_at IS NULL
  $$;

REVOKE ALL ON FUNCTION app.claim_device(bytea, bytea, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.authenticate_device(bytea) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.claim_device(bytea, bytea, text) TO app_ingest;
GRANT EXECUTE ON FUNCTION app.authenticate_device(bytea) TO app_ingest;

-- ---------------------------------------------------------------- telemetry
-- readings has no tenant_id: device_id provides the tenant link via devices.
-- RLS on readings joins through devices rather than carrying a redundant column.
-- No FK to devices here on purpose: it costs on the hottest insert path, and the
-- ingest policy's WITH CHECK already pins device_id to the authenticated device.

CREATE TABLE readings (
  device_id uuid NOT NULL,
  sensor_id text NOT NULL,
  ts        timestamptz NOT NULL,                -- ms precision from the device
  value     double precision NOT NULL,
  clock_ok  boolean NOT NULL DEFAULT true,
  PRIMARY KEY (device_id, sensor_id, ts)         -- the idempotency key: retries do ON CONFLICT DO NOTHING
) PARTITION BY RANGE (ts);

-- Monthly partitions. Retention for raw data = DROP the old partition (instant, no bloat).
CREATE FUNCTION app.ensure_readings_partition(p_month date) RETURNS void
  LANGUAGE plpgsql SET timezone = 'UTC' AS $$
DECLARE
  s date := date_trunc('month', p_month)::date;
  e date := (date_trunc('month', p_month) + interval '1 month')::date;
BEGIN
  EXECUTE format('CREATE TABLE IF NOT EXISTS %I PARTITION OF readings FOR VALUES FROM (%L) TO (%L)',
                 'readings_' || to_char(s, 'YYYY_MM'), s, e);
END $$;

-- Catches rows with garbage timestamps (clock not synced, year 1970) instead of failing ingest.
-- Inspect and clean it by hand. Note: a partition for a range can't be created while
-- the default partition holds rows in that range, so keep future partitions ahead of "now".
CREATE TABLE readings_default PARTITION OF readings DEFAULT;

SELECT app.ensure_readings_partition((current_date + make_interval(months => g))::date)
  FROM generate_series(-1, 3) AS g;
-- TODO(job): daily, call ensure_readings_partition(next 2 months); monthly, DROP partitions
-- older than the raw-retention window (pg_cron, or pg_partman if you prefer).

CREATE TABLE events (
  tenant_id uuid NOT NULL,
  device_id uuid NOT NULL,
  seq       bigint NOT NULL,                     -- device-side seq: stable, makes retries idempotent
  ts        timestamptz NOT NULL,
  kind      text NOT NULL CHECK (kind IN ('actuator', 'control', 'fault', 'system')),
  subject   text NOT NULL,
  data      jsonb NOT NULL DEFAULT '{}',
  clock_ok  boolean NOT NULL DEFAULT true,
  PRIMARY KEY (tenant_id, device_id, seq)
);
CREATE INDEX events_by_time ON events (tenant_id, device_id, ts DESC);

-- Computed in the cloud from raw rows (device rollups are not synced).
CREATE TABLE rollups (
  tenant_id    uuid NOT NULL,
  device_id    uuid NOT NULL,
  sensor_id    text NOT NULL,
  bucket_s     integer NOT NULL CHECK (bucket_s IN (60, 3600)),
  bucket_start timestamptz NOT NULL,
  n            integer NOT NULL,
  sum          double precision NOT NULL,
  min          double precision NOT NULL,
  max          double precision NOT NULL,
  PRIMARY KEY (tenant_id, device_id, sensor_id, bucket_s, bucket_start)
);

-- Recomputes whole buckets from raw data, so late-arriving batches after an outage
-- are picked up by simply re-running over a window (e.g. the last 6 hours, every minute).
-- Rows with clock_ok = false are excluded from rollups.
-- Joins devices to recover tenant_id (readings carries no tenant_id column).
CREATE FUNCTION app.refresh_rollups(p_since timestamptz) RETURNS void
  LANGUAGE sql SET timezone = 'UTC' AS $$
  INSERT INTO rollups (tenant_id, device_id, sensor_id, bucket_s, bucket_start, n, sum, min, max)
  SELECT d.tenant_id, r.device_id, r.sensor_id, b.bucket_s,
         date_bin(make_interval(secs => b.bucket_s), r.ts, timestamptz '2000-01-01 00:00:00+00'),
         count(*), sum(r.value), min(r.value), max(r.value)
    FROM readings r
    JOIN devices d ON d.id = r.device_id
    CROSS JOIN (VALUES (60), (3600)) AS b (bucket_s)
   WHERE r.ts >= date_trunc('hour', p_since) AND r.clock_ok
   GROUP BY d.tenant_id, r.device_id, r.sensor_id, b.bucket_s,
            date_bin(make_interval(secs => b.bucket_s), r.ts, timestamptz '2000-01-01 00:00:00+00')
  ON CONFLICT (tenant_id, device_id, sensor_id, bucket_s, bucket_start)
  DO UPDATE SET n = EXCLUDED.n, sum = EXCLUDED.sum, min = EXCLUDED.min, max = EXCLUDED.max
$$;
-- TODO(job): SELECT cron.schedule('rollups', '* * * * *', $$SELECT app.refresh_rollups(now() - interval '6 hours')$$);

CREATE TABLE photos (
  tenant_id   uuid NOT NULL,
  device_id   uuid NOT NULL,
  local_seq   bigint NOT NULL,                   -- device photos.seq: idempotency key
  ts          timestamptz NOT NULL,
  storage_key text NOT NULL,                     -- S3-compatible key; bytes never pass through the app
  bytes       bigint NOT NULL,
  width       integer,
  height      integer,
  clock_ok    boolean NOT NULL DEFAULT true,
  PRIMARY KEY (tenant_id, device_id, local_seq),
  FOREIGN KEY (tenant_id, device_id) REFERENCES devices (tenant_id, id)
);
CREATE INDEX photos_by_time ON photos (tenant_id, device_id, ts DESC);

-- ------------------------------------------------------------------- recipes

-- Global catalog of actuator types. Not tenant-scoped.
CREATE TABLE control (
  id        serial PRIMARY KEY,
  name      text NOT NULL UNIQUE,               -- 'light', 'fan', 'heater'
  unit      text,                               -- '%', '°C', 'on/off'
  min_value double precision,
  max_value double precision
);

-- A recipe is a named grow plan, authored in the cloud and synced to devices.
CREATE TABLE recipe (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES tenants (id) ON DELETE CASCADE,
  name        text NOT NULL,
  description text,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX recipe_by_tenant ON recipe (tenant_id);

-- Stages divide a recipe by day range (day 1 = planting date).
CREATE TABLE stage (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  recipe_id uuid NOT NULL REFERENCES recipe (id) ON DELETE CASCADE,
  name      text,                               -- 'seedling', 'flowering'
  start_day integer NOT NULL,
  end_day   integer,                            -- NULL = until the end
  CHECK (end_day IS NULL OR end_day >= start_day)
);
CREATE INDEX stage_by_recipe ON stage (recipe_id);

-- Time windows within a stage.
CREATE TABLE schedule_window (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  stage_id   uuid NOT NULL REFERENCES stage (id) ON DELETE CASCADE,
  start_time text NOT NULL,                     -- 'HH:MM' local time
  end_time   text NOT NULL                      -- may be < start_time for overnight
);
CREATE INDEX schedule_window_by_stage ON schedule_window (stage_id);

-- Target value for each actuator during a window.
CREATE TABLE setpoint (
  window_id  uuid    NOT NULL REFERENCES schedule_window (id) ON DELETE CASCADE,
  control_id integer NOT NULL REFERENCES control (id),
  value      double precision NOT NULL,
  PRIMARY KEY (window_id, control_id)
);

-- ---------------------------------------------------------------------- RLS
-- ENABLE, not FORCE: the owner (migrations, cron jobs) must keep working.
-- The safety net is that the app connects ONLY as app_web / app_ingest. Add a CI test
-- that connects as each role and asserts cross-tenant reads return zero rows.
-- Partitions get no grants of their own; access goes through the parent so its policies apply.

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['tenants','tenant_members','devices','device_tokens','claim_codes',
                           'readings','events','rollups','photos','recipe','stage','schedule_window','setpoint']
  LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
  END LOOP;
  -- Tenant-scoped read access for web users (tables with direct tenant_id column).
  FOREACH t IN ARRAY ARRAY['events','rollups','photos','claim_codes']
  LOOP
    EXECUTE format('CREATE POLICY web_read ON %I FOR SELECT TO app_web
                    USING (tenant_id IN (SELECT app.my_tenants()))', t);
  END LOOP;
  -- Device-scoped read/insert access for the ingest role (tables with tenant_id).
  FOREACH t IN ARRAY ARRAY['events','photos']
  LOOP
    EXECUTE format('CREATE POLICY ingest_read ON %I FOR SELECT TO app_ingest
                    USING (device_id = app.device_id() AND tenant_id = app.tenant_id())', t);
    EXECUTE format('CREATE POLICY ingest_insert ON %I FOR INSERT TO app_ingest
                    WITH CHECK (device_id = app.device_id() AND tenant_id = app.tenant_id())', t);
  END LOOP;
END $$;

-- readings has no tenant_id; enforce isolation via devices join
CREATE POLICY web_read    ON readings FOR SELECT TO app_web
  USING (device_id IN (SELECT id FROM devices WHERE tenant_id IN (SELECT app.my_tenants())));
CREATE POLICY ingest_read ON readings FOR SELECT TO app_ingest
  USING (device_id = app.device_id());
CREATE POLICY ingest_insert ON readings FOR INSERT TO app_ingest
  WITH CHECK (device_id = app.device_id());

-- tenants / membership / devices (web)
CREATE POLICY web_read ON tenants        FOR SELECT TO app_web USING (id IN (SELECT app.my_tenants()));
CREATE POLICY web_read ON tenant_members FOR SELECT TO app_web USING (user_id = app.user_id());
CREATE POLICY web_read ON devices        FOR SELECT TO app_web USING (tenant_id IN (SELECT app.my_tenants()));
CREATE POLICY web_rename ON devices      FOR UPDATE TO app_web
  USING (app.can_write(tenant_id)) WITH CHECK (app.can_write(tenant_id));

-- devices (ingest): see and touch only itself
CREATE POLICY ingest_read ON devices   FOR SELECT TO app_ingest USING (id = app.device_id());
CREATE POLICY ingest_seen ON devices   FOR UPDATE TO app_ingest
  USING (id = app.device_id()) WITH CHECK (id = app.device_id());

-- claim codes (web): create for tenants where the user may write
CREATE POLICY web_create ON claim_codes FOR INSERT TO app_web
  WITH CHECK (app.can_write(tenant_id) AND created_by = app.user_id());

-- recipe (web): full CRUD within the user's tenants; ingest: read own tenant's recipes
CREATE POLICY web_read   ON recipe FOR SELECT TO app_web USING (tenant_id IN (SELECT app.my_tenants()));
CREATE POLICY web_create ON recipe FOR INSERT TO app_web WITH CHECK (app.can_write(tenant_id));
CREATE POLICY web_update ON recipe FOR UPDATE TO app_web
  USING (app.can_write(tenant_id)) WITH CHECK (app.can_write(tenant_id));
CREATE POLICY web_delete ON recipe FOR DELETE TO app_web USING (app.can_write(tenant_id));
CREATE POLICY ingest_read ON recipe FOR SELECT TO app_ingest USING (tenant_id = app.tenant_id());

-- stage: access controlled by parent recipe
CREATE POLICY web_read   ON stage FOR SELECT TO app_web
  USING (recipe_id IN (SELECT id FROM recipe WHERE tenant_id IN (SELECT app.my_tenants())));
CREATE POLICY web_write  ON stage FOR INSERT TO app_web
  WITH CHECK (recipe_id IN (SELECT id FROM recipe WHERE app.can_write(tenant_id)));
CREATE POLICY web_update ON stage FOR UPDATE TO app_web
  USING (recipe_id IN (SELECT id FROM recipe WHERE app.can_write(tenant_id)));
CREATE POLICY web_delete ON stage FOR DELETE TO app_web
  USING (recipe_id IN (SELECT id FROM recipe WHERE app.can_write(tenant_id)));
CREATE POLICY ingest_read ON stage FOR SELECT TO app_ingest
  USING (recipe_id IN (SELECT id FROM recipe WHERE tenant_id = app.tenant_id()));

-- schedule_window: access controlled by parent stage → recipe
CREATE POLICY web_read   ON schedule_window FOR SELECT TO app_web
  USING (stage_id IN (SELECT s.id FROM stage s
                        JOIN recipe r ON r.id = s.recipe_id
                       WHERE r.tenant_id IN (SELECT app.my_tenants())));
CREATE POLICY web_write  ON schedule_window FOR INSERT TO app_web
  WITH CHECK (stage_id IN (SELECT s.id FROM stage s
                             JOIN recipe r ON r.id = s.recipe_id
                            WHERE app.can_write(r.tenant_id)));
CREATE POLICY web_update ON schedule_window FOR UPDATE TO app_web
  USING (stage_id IN (SELECT s.id FROM stage s
                        JOIN recipe r ON r.id = s.recipe_id
                       WHERE app.can_write(r.tenant_id)));
CREATE POLICY web_delete ON schedule_window FOR DELETE TO app_web
  USING (stage_id IN (SELECT s.id FROM stage s
                        JOIN recipe r ON r.id = s.recipe_id
                       WHERE app.can_write(r.tenant_id)));
CREATE POLICY ingest_read ON schedule_window FOR SELECT TO app_ingest
  USING (stage_id IN (SELECT s.id FROM stage s
                        JOIN recipe r ON r.id = s.recipe_id
                       WHERE r.tenant_id = app.tenant_id()));

-- setpoint: access controlled by parent window → stage → recipe
CREATE POLICY web_read   ON setpoint FOR SELECT TO app_web
  USING (window_id IN (SELECT w.id FROM schedule_window w
                         JOIN stage s ON s.id = w.stage_id
                         JOIN recipe r ON r.id = s.recipe_id
                        WHERE r.tenant_id IN (SELECT app.my_tenants())));
CREATE POLICY web_write  ON setpoint FOR INSERT TO app_web
  WITH CHECK (window_id IN (SELECT w.id FROM schedule_window w
                              JOIN stage s ON s.id = w.stage_id
                              JOIN recipe r ON r.id = s.recipe_id
                             WHERE app.can_write(r.tenant_id)));
CREATE POLICY web_update ON setpoint FOR UPDATE TO app_web
  USING (window_id IN (SELECT w.id FROM schedule_window w
                         JOIN stage s ON s.id = w.stage_id
                         JOIN recipe r ON r.id = s.recipe_id
                        WHERE app.can_write(r.tenant_id)));
CREATE POLICY web_delete ON setpoint FOR DELETE TO app_web
  USING (window_id IN (SELECT w.id FROM schedule_window w
                         JOIN stage s ON s.id = w.stage_id
                         JOIN recipe r ON r.id = s.recipe_id
                        WHERE app.can_write(r.tenant_id)));
CREATE POLICY ingest_read ON setpoint FOR SELECT TO app_ingest
  USING (window_id IN (SELECT w.id FROM schedule_window w
                         JOIN stage s ON s.id = w.stage_id
                         JOIN recipe r ON r.id = s.recipe_id
                        WHERE r.tenant_id = app.tenant_id()));

-- device_tokens: RLS on, no policies, no grants -> unreachable except via the definer functions.

-- ------------------------------------------------------------------- grants
-- Column-level UPDATE grants keep each role to the fields it should touch.

GRANT SELECT ON tenants, tenant_members, devices, readings, events, rollups, photos,
                control, recipe, stage, schedule_window, setpoint, claim_codes TO app_web;
GRANT INSERT ON recipe, stage, schedule_window, setpoint, claim_codes TO app_web;
GRANT UPDATE ON recipe, stage, schedule_window, setpoint TO app_web;
GRANT DELETE ON recipe, stage, schedule_window, setpoint TO app_web;
GRANT UPDATE (name) ON devices TO app_web;

GRANT SELECT, INSERT ON readings, events, photos TO app_ingest;
GRANT SELECT ON devices, control, recipe, stage, schedule_window, setpoint TO app_ingest;
GRANT UPDATE (last_seen_at) ON devices TO app_ingest;

COMMIT;
