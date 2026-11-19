# Project: smart greenhouse controller platform (Raspberry Pi 5)

Time-lapse photos plus continuous sensor logging (temperature, humidity, more TBD) with recipe-driven
control — stage-based schedules that set actuator targets (light, fan, heater) over time windows.
Goal: one step above a prototype, open-sourceable, not market-ready. Development speed matters; avoid
over-engineering.

## Core principles

1. **Local-first.** The Pi is the source of truth for everything it produces and must work fully with no
   internet. The cloud is a replica, a remote UI, and a remote control surface.
2. **Outbound-only networking.** The device only makes HTTPS calls to the cloud. No port forwarding.
3. **One web codebase.** The same SvelteKit app runs on the device (LAN UI + touchscreen) and in the cloud
   (multi-tenant). The only differences are the `Store` implementation and the auth/tenancy layer.
4. **The control loop never depends on the UI, API, network, or cloud.** Fail-safe states are defined
   (e.g. fan ON if the temperature sensor goes stale) and setpoints/schedules are cached locally.
5. **SQLite is the boundary between the web process and the hardware daemon.** No HTTP between them.

## Domain model

The UI introduces two concepts that sit above recipes in the hierarchy:

- **Experiment** — a named study grouping one or more trials. Trials within an experiment can use different recipes (e.g. comparing two lighting schedules). Experiments are authored in the cloud UI.
- **Trial** — one specific grow run: a recipe assigned to a device with a planting date. The daemon drives the device according to the trial's recipe. A trial produces readings, photos, and events.

Hierarchy: `Experiment → Trial → Recipe + Device`

These are not yet in the DB schema (see Known gaps). When added:
- `experiments(id, tenant_id, name, description, ...)`
- `trials(id, experiment_id, recipe_id, device_id, planting_date, status, ...)`
- Trial status: `active | paused | completed`
- Trial thumbnail = most recent photo from that trial's device during the trial window.

URL structure: `/experiments/:experimentId` · `/experiments/:experimentId/trials/:trialId` · `/devices/:deviceId` · `/recipes/:recipeId`

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

**Web UI**
- Component library: **m3-svelte v7** (Material Design 3). Requires `vite-plugin-functions-mixins` as the first Vite plugin (before `sveltekit()`).
- Icons: `@ktibow/iconset-material-symbols`. Font: `@fontsource-variable/google-sans-flex`.
- Svelte 5 runes mode enforced project-wide (`runes: true` in vite.config.ts, except node_modules).
- Path aliases: `$lib` (SvelteKit standard) and `#lib` / `#lib/*` (Node package imports, defined in `package.json`).
- **Never set `class` on m3-svelte components** — wrap in a `<div>` for sizing/spacing.
- Use `import { page } from '$app/state'` (not `$app/stores`) in rune-mode files.
- Mock data lives in `src/lib/mock.ts` and is the only data source until the Store is wired up.
- Theme tokens live in `src/app.css` (imported once in `+layout.svelte`). Green/teal palette; supports `light-dark()` for automatic dark mode.

**Navigation** (global sidebar — `NavigationRail` from m3-svelte):
- Home, Experiments, Devices, **Recipes** (top-to-bottom)
- Account icon at bottom
- Collapsed: 96 px icon-only rail. Expanded: 220 px drawer showing org name + settings/switch-org buttons.
- Recipes are managed separately (create, edit, delete, download/export) — not shown on the home screen.

**Pages built so far:**
- `/` — Home: recent trials carousel (top 8, landscape photo cards), experiments preview list, devices preview list.
- `/experiments` — full experiment list.
- `/devices` — full device list.

**Pages planned next (in order):**
1. Experiment detail (`/experiments/:id`) — trial list with summary stats.
2. Trial detail (`/experiments/:expId/trials/:id`) — sensor charts, photo gallery, recipe stage timeline.
3. Device detail (`/devices/:id`) — live status, assigned trial, recent readings.
4. Recipes (`/recipes`) — CRUD list; recipe editor (stages → windows → setpoints).

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
- Writer rules: the daemon writes `readings`, `events`, `photos`, `rollups`, `status`, and `sync_state`. The web app
  is read-only (recipes come from the cloud via sync). The sync agent owns `sync_state`, `photos.state`, and inserts
  cloud-origin recipe rows.

## Recipes and control (cloud → hardware)

- A `recipe` is a named grow plan. It contains `stage`s defined by day ranges (day 1 = planting date), each stage has
  `schedule_window`s (by time-of-day, `HH:MM`; overnight windows wrap past midnight), and each window has `setpoint`s
  mapping a `control` actuator to a target value. The daemon reads the active recipe and drives actuators to match the
  current setpoint each control cycle, with fail-safe defaults when no window applies.
- `control` is a catalog of actuator types (`light`, `fan`, `heater`, etc.) with unit and value range metadata.
- Recipes are authored in the cloud UI and synced down to the device. An active-recipe assignment (recipe id + planting
  date) is stored locally so the daemon runs the full schedule offline. Recipe sync is inbound-only (cloud → device).
- One-shot actuator overrides (previously `commands`) are not yet replaced. TBD.

## Sync design

- **Telemetry is an append-only log with one writer per device.** `readings` and `events` use a `seq` cursor per stream
  (`sync_state`). The sync agent POSTs batches of a few hundred, the cloud does multi-row
  `INSERT ... ON CONFLICT DO NOTHING` (readings key: `device_id, sensor_id, ts`; events key: `device_id, seq`),
  returns the highest persisted `seq`, and only then does the device advance its cursor. At-least-once delivery plus
  idempotent ingest. Exponential backoff, and rate-limit the backlog drain after an outage so live data isn't starved.
- **Photos do not use a cursor** (uploads finish out of order). The state machine is `pending -> uploaded -> synced`.
  Upload via presigned URL (bytes never pass through the app), then sync the metadata row (idempotency key
  `device_id, local_seq`). Local retention may delete only `synced` photos, oldest first, past a disk threshold.
  Never delete unsynced data unless the disk is critically full, and log it loudly if so.
- **Recipes are the only inbound sync flow.** The device polls (~30 s) for updated recipe data and applies it locally.
  No other two-way sync exists currently.
- **Time:** store UTC only. Use the Pi 5 RTC battery. Rows carry `clock_ok` (NTP-synced or not). Bad-clock rows land in
  `readings_default` in the cloud and are excluded from rollups.
- **Retention:** raw readings kept locally 30-90 days. Rollups (1 min, 1 h; store sum+count, not avg) are kept far
  longer. Device rollups are not synced. The cloud computes its own, and drops old raw partitions.

## Cloud schema and security (Postgres)

- `tenant_id` leads most table keys. `readings` is the exception: it carries no `tenant_id` because `device_id` provides
  that link via `devices`. RLS on `readings` uses a subquery join through `devices` to enforce tenant isolation.
  `readings` is partitioned monthly by `ts`. Device identity is independent of user accounts.
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
- Recipe sync (cloud → device) and active-recipe assignment (device_recipe table tracking recipe id + planting date)
  are not yet designed or implemented.
- One-shot actuator overrides (formerly `commands`) have no replacement yet; mechanism TBD.
- Remaining sensors are TBD. Sensor ids follow `temp_1`, `humidity_1`, etc.
- `experiments` and `trials` tables not yet in DB schema (UI uses mock data only).
- Recipes nav item not yet added to the sidebar (planned, not built).
- `svelte-kit sync` / `pnpm check` has a pre-existing TS error from a missing `auth.schema` import in `src/lib/server/db/schema.ts`; not introduced by the UI work.

## Suggested build order

1. Device migration + daemon skeleton: simulated sensors -> `readings`, status table, control loop with fail-safes.
2. `sqliteStore` + SvelteKit local UI: live view over SSE, charts (uPlot/ECharts), recipe management UI.
3. Real drivers (C-library sensor via helper process first), photo capture.
4. Sync agent plus the cloud ingest endpoint plus pytest sync tests.
5. `pgStore`, Better Auth, RLS, claim flow, cloud UI. 6. Deploy scripts, retention, hardening.