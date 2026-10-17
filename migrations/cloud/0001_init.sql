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
-- Narrow format: one row per reading. Switching to a wide row (one row per
-- device+timestamp) later would cut row count several-fold but is a schema change.
-- tenant_id leads every key so RLS predicates and per-tenant sharding stay cheap.
-- No FK to devices here on purpose: it costs on the hottest insert path, and the
-- ingest policy's WITH CHECK already pins (tenant_id, device_id).

CREATE TABLE readings (
  tenant_id uuid NOT NULL,
  device_id uuid NOT NULL,
  sensor_id text NOT NULL,
  ts        timestamptz NOT NULL,                -- ms precision from the device
  value     double precision NOT NULL,
  clock_ok  boolean NOT NULL DEFAULT true,
  PRIMARY KEY (tenant_id, device_id, sensor_id, ts)   -- the idempotency key: retries do ON CONFLICT DO NOTHING
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
CREATE FUNCTION app.refresh_rollups(p_since timestamptz) RETURNS void
  LANGUAGE sql SET timezone = 'UTC' AS $$
  INSERT INTO rollups (tenant_id, device_id, sensor_id, bucket_s, bucket_start, n, sum, min, max)
  SELECT r.tenant_id, r.device_id, r.sensor_id, b.bucket_s,
         date_bin(make_interval(secs => b.bucket_s), r.ts, timestamptz '2000-01-01 00:00:00+00'),
         count(*), sum(r.value), min(r.value), max(r.value)
    FROM readings r CROSS JOIN (VALUES (60), (3600)) AS b (bucket_s)
   WHERE r.ts >= date_trunc('hour', p_since) AND r.clock_ok
   GROUP BY 1, 2, 3, 4, 5
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

-- ------------------------------------------------------- config and commands

CREATE TABLE config_revisions (
  id         uuid PRIMARY KEY,                   -- generated by the author (cloud UI or device)
  tenant_id  uuid NOT NULL,
  device_id  uuid NOT NULL,
  base_id    uuid,
  source     text NOT NULL CHECK (source IN ('cloud', 'local')),
  doc        jsonb NOT NULL,
  created_at timestamptz NOT NULL,               -- ordering for last-writer-wins
  created_by text,                               -- user id for cloud-authored revisions
  status     text NOT NULL DEFAULT 'pending'
             CHECK (status IN ('pending', 'applied', 'rejected', 'superseded')),
  error      text,
  applied_at timestamptz,
  FOREIGN KEY (tenant_id, device_id) REFERENCES devices (tenant_id, id)
);
CREATE INDEX config_by_device ON config_revisions (tenant_id, device_id, created_at DESC);

CREATE TABLE commands (
  id          uuid PRIMARY KEY,
  tenant_id   uuid NOT NULL,
  device_id   uuid NOT NULL,
  kind        text NOT NULL,
  args        jsonb NOT NULL DEFAULT '{}',
  source      text NOT NULL CHECK (source IN ('cloud', 'local')),
  created_by  text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  expires_at  timestamptz NOT NULL,              -- mandatory: stale commands must never fire
  status      text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'done', 'failed', 'expired')),
  result      jsonb,
  finished_at timestamptz,
  FOREIGN KEY (tenant_id, device_id) REFERENCES devices (tenant_id, id)
);
CREATE INDEX commands_pending ON commands (tenant_id, device_id) WHERE status = 'pending';

-- ---------------------------------------------------------------------- RLS
-- ENABLE, not FORCE: the owner (migrations, cron jobs) must keep working.
-- The safety net is that the app connects ONLY as app_web / app_ingest. Add a CI test
-- that connects as each role and asserts cross-tenant reads return zero rows.
-- Partitions get no grants of their own; access goes through the parent so its policies apply.

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['tenants','tenant_members','devices','device_tokens','claim_codes',
                           'readings','events','rollups','photos','config_revisions','commands']
  LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
  END LOOP;
  -- Tenant-scoped read access for web users.
  FOREACH t IN ARRAY ARRAY['readings','events','rollups','photos','config_revisions','commands','claim_codes']
  LOOP
    EXECUTE format('CREATE POLICY web_read ON %I FOR SELECT TO app_web
                    USING (tenant_id IN (SELECT app.my_tenants()))', t);
  END LOOP;
  -- Device-scoped read access for the ingest role.
  FOREACH t IN ARRAY ARRAY['readings','events','photos','config_revisions','commands']
  LOOP
    EXECUTE format('CREATE POLICY ingest_read ON %I FOR SELECT TO app_ingest
                    USING (device_id = app.device_id() AND tenant_id = app.tenant_id())', t);
  END LOOP;
  -- Device-scoped insert access for telemetry.
  FOREACH t IN ARRAY ARRAY['readings','events','photos','config_revisions','commands']
  LOOP
    EXECUTE format('CREATE POLICY ingest_insert ON %I FOR INSERT TO app_ingest
                    WITH CHECK (device_id = app.device_id() AND tenant_id = app.tenant_id())', t);
  END LOOP;
END $$;

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

-- config + commands: web may only create cloud-authored, pending rows
CREATE POLICY web_create ON config_revisions FOR INSERT TO app_web
  WITH CHECK (app.can_write(tenant_id) AND source = 'cloud' AND status = 'pending' AND created_by = app.user_id());
CREATE POLICY web_create ON commands FOR INSERT TO app_web
  WITH CHECK (app.can_write(tenant_id) AND source = 'cloud' AND status = 'pending' AND created_by = app.user_id());

-- config + commands: the device reports status back on its own rows
CREATE POLICY ingest_report ON config_revisions FOR UPDATE TO app_ingest
  USING (device_id = app.device_id() AND tenant_id = app.tenant_id())
  WITH CHECK (device_id = app.device_id() AND tenant_id = app.tenant_id());
CREATE POLICY ingest_report ON commands FOR UPDATE TO app_ingest
  USING (device_id = app.device_id() AND tenant_id = app.tenant_id())
  WITH CHECK (device_id = app.device_id() AND tenant_id = app.tenant_id());

-- device_tokens: RLS on, no policies, no grants -> unreachable except via the definer functions.

-- ------------------------------------------------------------------- grants
-- Column-level UPDATE grants keep each role to the fields it should touch.

GRANT SELECT ON tenants, tenant_members, devices, readings, events, rollups, photos,
                config_revisions, commands, claim_codes TO app_web;
GRANT INSERT ON config_revisions, commands, claim_codes TO app_web;
GRANT UPDATE (name) ON devices TO app_web;

GRANT SELECT, INSERT ON readings, events, photos TO app_ingest;
GRANT SELECT ON devices TO app_ingest;
GRANT SELECT, INSERT ON config_revisions, commands TO app_ingest;
GRANT UPDATE (last_seen_at) ON devices TO app_ingest;
GRANT UPDATE (status, error, applied_at) ON config_revisions TO app_ingest;
GRANT UPDATE (status, result, finished_at) ON commands TO app_ingest;

COMMIT;