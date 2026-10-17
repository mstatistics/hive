# Project: local-first IoT logger/controller (Raspberry Pi 5)

Time-lapse photos plus continuous sensor logging (temperature, humidity, more TBD) with simple control
(fan on/off, temperature control). Goal: one step above a prototype, open-sourceable, not market-ready.
Development speed matters; avoid over-engineering.

## Core principles

1. **Local-first.** The Pi is the source of truth for everything it produces and must work fully with no
   internet. The cloud is a replica, a remote UI, and a remote control surface.
2. **Outbound-only networking.** The device only makes HTTPS calls to the cloud. No port forwarding.
3. **One web codebase.** The same SvelteKit app runs on the device (LAN UI + touchscreen) and in the cloud
   (multi-tenant). The only differences are the `Store` implementation and the auth/tenancy layer.
4. **The control loop never depends on the UI, API, network, or cloud.** Fail-safe states are defined
   (e.g. fan ON if the temperature sensor goes stale) and setpoints/schedules are cached locally.
5. **SQLite is the boundary between the web process and the hardware daemon.** No HTTP between them.

## Stack

**Device (Pi 5)**
- `daemon/`: Python 3.12, plain `sqlite3` (no ORM). Sensor drivers, collector, control loop, rollups,
  sync agent, photo capture. Uses `picamera2` and `gpiod`/lgpio (RPi.GPIO does NOT work on Pi 5).
- Sensor drivers sit behind one interface (`read() -> list[Reading]`). Includes a **simulated-sensor mode**
  so everything runs without hardware. The native C sensor library is wrapped via `cffi`/`ctypes`, or run as a
  small helper process emitting JSON lines (preferred first; a crash can't take down the collector).
  Do not write new C unless unavoidable.
- `web/`: SvelteKit with `adapter-node` on **Node (current LTS)**, not Bun. Serves UI, JSON API, SSE, and local auth.
- Touchscreen = Chromium kiosk (under `cage` or labwc) pointed at localhost. One responsive, touch-friendly UI.
- Process management: systemd units (daemon, web) with watchdog. Install via script.
- Optional: Litestream to back up the SQLite file (backup only, NOT the sync mechanism).

**Cloud**
- Same SvelteKit app (`adapter-node`), Better Auth, plain Postgres (>= 14), S3-compatible object storage
  (R2/B2/MinIO) for photos. Deploy with `docker compose`.
- Multi-tenant via Postgres **row-level security**. Not Supabase (it would force a second backend and a
  `DataSource` abstraction).
- Ingest is an isolated module (`+server.ts` route plus a batch API contract) so it can be extracted into its own
  service later.

**Data access**
- **No ORM.** `better-sqlite3` (device) and `pg`/`postgres.js` (cloud) with hand-written SQL, behind a `Store`
  interface (`web/src/lib/server/store.ts`) with two implementations: `sqliteStore` and `pgStore`.
  Routes never touch a database directly. (Drizzle was rejected: pre-1.0, SQLite dialect still being reworked.)
- Better Auth takes a `better-sqlite3`/`pg` handle directly. Keep its tables out of our migrations
  (suggest a separate `auth.db` on the device).
- Migrations are plain numbered `.sql` files. SQLite uses `PRAGMA user_version`. Add a CI test that opens the migrated
  SQLite DB and checks the columns the web side uses.

**Live updates:** SSE (`ReadableStream` from a `+server.ts` route), not WebSockets. Fan-out is hidden behind a tiny
`LiveBus` interface so it can move from polling/LISTEN-NOTIFY to Redis later. The cloud view is only as fresh as the
sync cadence (10-30 s); real-time control is a LAN feature.

## Repo layout (suggested)

```
CLAUDE.md
daemon/                 Python package + tests (pytest)
web/                    SvelteKit app (src/lib/server/store.ts, sqliteStore.ts, pgStore.ts)
migrations/device/      0001_init.sql (SQLite)
migrations/cloud/       0001_init.sql (Postgres + RLS)
deploy/                 systemd units, Pi install script, docker-compose.yml (cloud)
```

Already written: both `0001_init.sql` files and `store.ts`. Treat them as the starting contract; read them first.

## SQLite rules (device)

- Per connection, in BOTH Python and Node: `journal_mode=WAL`, `busy_timeout=5000`, `foreign_keys=ON`,
  `synchronous=NORMAL`.
- WAL allows multiple writers taking turns. It is fine for the web process to insert commands. Keep write
  transactions short, no hardware or network I/O inside a transaction, and use `BEGIN IMMEDIATE` (better-sqlite3:
  `.immediate()`) for read-then-write transactions.
- If the web app runs in Docker, bind-mount the *directory* containing the DB (WAL needs `-wal`/`-shm`). Local
  filesystem only, never NFS.
- Writer rules: the daemon writes `readings`, `events`, `photos`, `rollups`, `status`, `sync_state`, and the
  status/result columns of `config_revisions` and `commands`. The web app only INSERTs into `config_revisions` and
  `commands`. The sync agent owns `sync_state`, `photos.state`, `cloud_synced` flags, and inserts cloud-origin rows.

## Commands and config (UI -> hardware)

- The table is the channel. The web app inserts a `commands` row (UUID id, mandatory `expires_ms`). The daemon polls
  `WHERE status='pending'` every ~250-500 ms inside the control loop, expires stale rows, executes through the control
  loop, and writes `done`/`failed`/`expired`. Cloud-originated commands are pulled by the sync agent into the same table.
- Config is one versioned JSON document in `config_revisions`. Identity is a UUID (two possible authors, so no integer
  counter), ordering is `created_at` (last-writer-wins), and `base_id` records what the author was looking at. The daemon
  validates a pending revision and marks it `applied` or `rejected` with an error. The active config is the newest
  `applied` row.

## Sync design

- **Telemetry is an append-only log with one writer per device.** `readings` and `events` use a `seq` cursor per stream
  (`sync_state`). The sync agent POSTs batches of a few hundred, the cloud does multi-row
  `INSERT ... ON CONFLICT DO NOTHING` (readings key: `tenant_id, device_id, sensor_id, ts`; events key: `device_id, seq`),
  returns the highest persisted `seq`, and only then does the device advance its cursor. At-least-once delivery plus
  idempotent ingest. Exponential backoff, and rate-limit the backlog drain after an outage so live data isn't starved.
- **Photos do not use a cursor** (uploads finish out of order). The state machine is `pending -> uploaded -> synced`.
  Upload via presigned URL (bytes never pass through the app), then sync the metadata row (idempotency key
  `device_id, local_seq`). Local retention may delete only `synced` photos, oldest first, past a disk threshold.
  Never delete unsynced data unless the disk is critically full, and log it loudly if so.
- **Config/commands are the only two-way flow.** The device polls (~30 s) for pending cloud rows, applies them,
  and reports status back. No true bidirectional sync.
- **Time:** store UTC only. Use the Pi 5 RTC battery. Rows carry `clock_ok` (NTP-synced or not). Bad-clock rows land in
  `readings_default` in the cloud and are excluded from rollups.
- **Retention:** raw readings kept locally 30-90 days. Rollups (1 min, 1 h; store sum+count, not avg) are kept far
  longer. Device rollups are not synced. The cloud computes its own, and drops old raw partitions.

## Cloud schema and security (Postgres)

- `tenant_id` and `device_id` on every row, leading every key. `readings` is partitioned monthly by `ts`. Device identity
  is independent of user accounts.
- RLS is enabled on all tables. Roles: `app_web` (per-user, sets `app.user_id` per transaction), `app_ingest`
  (per-device, sets `app.device_id` and `app.tenant_id`), and the owner (migrations and cron only, bypasses RLS).
  **The app must never connect as the owner.** Add a CI test connecting as each role to assert cross-tenant reads return
  zero rows.
- Every request runs in one transaction starting with `set_config(..., true)`. Build ONE wrapper (`withUserTx`) and
  route all cloud queries through it. Plain `SET` would leak across pooled connections.
- Device provisioning: a signed-in user generates a claim code (stored hashed, short expiry). The device exchanges it
  for a per-device token via `app.claim_device()`. Tokens are stored as hashes. `app.authenticate_device()` is the only
  token lookup path.

## Engineering checklist ("one step above prototype")

- Simulated-sensor mode, and pytest for sync (kill the network mid-batch, assert no loss and no duplicates).
- ruff, mypy, CI. TOML config for the daemon, structured logging.
- Versioned JSON API. Shared schema validation for the config document (zod/valibot on the web side, mirrored in Python).
- Dockerfile/compose for the cloud and a systemd install script for the Pi.
- Deferred: OTA updates, mTLS, richer multi-user management, Redis fan-out, TimescaleDB, wide-row telemetry.

## Known gaps / TODO

- Partition maintenance and rollup refresh jobs are `TODO(job)` comments in the cloud migration (pg_cron).
- The Postgres migration was only syntax-checked, never run. Run it and test the RLS policies first.
- Tenant member listing needs a SECURITY DEFINER function (a user currently sees only their own membership row).
- The daemon must seed a default `applied` config revision on first boot.
- Remaining sensors are TBD. Sensor ids follow `temp_1`, `humidity_1`, etc.

## Suggested build order

1. Device migration + daemon skeleton: simulated sensors -> `readings`, status table, control loop with fail-safes.
2. `sqliteStore` + SvelteKit local UI: live view over SSE, charts (uPlot/ECharts), command and config forms.
3. Real drivers (C-library sensor via helper process first), photo capture.
4. Sync agent plus the cloud ingest endpoint plus pytest sync tests.
5. `pgStore`, Better Auth, RLS, claim flow, cloud UI. 6. Deploy scripts, retention, hardening.