# Privacy & Security

This document describes NOOP's privacy posture, security model, and the hardening
applied to the parts of the codebase that touch untrusted input. It is written
against the actual source tree; file paths and identifiers below are real and can
be checked.

> **Not affiliated with WHOOP. Not a medical device.** NOOP is an independent,
> unofficial, local-first companion app. It interoperates with a WHOOP strap that
> **you own**, reading **your own** biometric data from **your own** device. It is
> not affiliated with, endorsed by, or connected to WHOOP, Inc. All computed
> outputs (Charge, Effort, Rest, HRV, SpO₂, skin temperature, respiratory rate — Charge/Effort/Rest
> being NOOP's own recovery/strain/sleep scores, not WHOOP's)
> are approximations and are not clinically validated. Self-tracking features such
> as the Mind / mood check-in and nutrition import are **informational only** and are
> **not** a diagnosis, treatment, or dietary/medical advice. Use at your own risk;
> your data stays on your device unless you explicitly enable a destination you
> control. See `DISCLAIMER.md`, `TERMS.md`, and
> `ATTRIBUTION.md` at the repo root.

---

## 1. Design principle: offline by default

NOOP is **offline by default**. The biometric pipeline — strap → on-device decode →
local SQLite — has no network layer at all: no phone-home, no analytics, no accounts,
no login, no cloud sync, and no telemetry. Everything NOOP computes about you lives in a
single SQLite file on your own device.

There are exactly **three data-bearing destinations**: the **AI Coach** (§1.1a),
the **Oura history import** (§1.1b), and a server the user operates through
**Self-hosted Sync** (§1.1c). **Friends** (§1.1d) is a least-privilege daily-summary
projection on that same self-hosted server, not a fourth service or a
Noop-operated social network. The AI Coach is off until you turn it on with your own API key; when you
ask it a question it sends a short text summary of your recent metrics to the provider you
choose. The Oura history import is **not even compiled into a default build** — the code
only exists in your binary if you build from source with your own Oura developer app's
credentials (§1.1b); instead of sending data out, it pulls your own Oura data **in** over
OAuth, once, and never sends any existing NOOP data out. Self-hosted Sync is also off by
default; after you enter your own endpoint/token and enable it, decoded streams and selected
local records are replicated to that server. A fourth, non-data-bearing path runs only when
you tap **Check for updates**: it reads public release metadata from GitHub and sends no
biometric content or app identifier.

Data enters NOOP three ways. It leaves only when **you** deliberately configure or initiate
one of the explicit outputs:

| Path | Transport | Direction |
|------|-----------|-----------|
| Live collection | Bluetooth LE, strap → device | Read-only from the strap |
| File import (Apple Health, WHOOP CSV, nutrition CSV) | User-selected files on disk | Read-only from disk |
| Oura history import (opt-in build flag, §1.1b) | HTTPS OAuth + REST, `api.ouraring.com` → device | Read-only from your own Oura account |
| Self-hosted Sync + Friends (§1.1c–d) | HTTPS, or HTTP only on loopback/private LAN | Selected records and optional friend summaries ↔ the server you configure |
| Check for updates | HTTPS GET to GitHub's public releases API, only when tapped | Public version metadata → device; no biometric payload |
| Apple Health export, incl. iOS "Export for Shortcuts" | On-device, user-initiated | NOOP → your Apple Health, on your device only (§1.3) |

The only **data-bearing network destinations** are those three opt-ins. Friends
uses the already configured self-hosted destination and its own scoped
credential. The collection/analysis pipeline itself produces no network traffic.
Apple Health export is an **on-device** hand-off — see §1.3.

### 1.1 Network code: only explicit optional destinations

The biometric pipeline and core decode/analytics packages
(`WhoopProtocol`, `WhoopStore`, `StrandAnalytics`, `StrandImport`, `StrandDesign`)
contain **no runtime network transport**. The isolated `NoopRemoteSync` package contains the
authenticated sync and invitation-only Friends clients for the self-host feature; the Oura lane's OAuth
and REST calls live entirely in the app target, `Strand/Oura/`, and `StrandImport`
gained only pure, network-free parsers for Oura's payload shapes. These Swift packages
are **shared by the macOS and iOS apps** (iOS is build-from-source only — no App Store /
TestFlight — and was folded into the main tree in v1.94), so the Swift-side privacy
behaviour described here applies equally to both. Android is a separate codebase using
Room for storage and Kotlin for the BLE / import / Coach paths; its own Oura support is
the local BLE ring-pairing lane, not a network API, so it has no equivalent to §1.1b. The
networking is `Strand/Oura/`, and Coach transport lives under `Strand/AI/` / `com.noop.ai`.
Self-host transport lives in `Packages/NoopRemoteSync` and the Android remote-sync client.
The package manifests reference dependency *download* URLs that Swift Package Manager
resolves at build time, never at runtime:

```
Packages/WhoopStore/Package.swift   → https://github.com/groue/GRDB.swift.git
Packages/StrandImport/Package.swift → https://github.com/weichsel/ZIPFoundation.git
```

GRDB.swift is the SQLite layer; ZIPFoundation is the archive reader used by the
importers. Neither opens a socket.

### 1.1a The AI Coach (optional, off by default, bring your own key)

The AI Coach lets you ask questions about your data in plain language. It uses
one of the three opt-in data-bearing destinations and runs only on your terms:

- **Off until you enable it.** You enter your own API key for the provider you choose
  (Anthropic, OpenAI, or a local / self-hosted OpenAI-compatible LLM such as Ollama or
  LM Studio). No key, no network calls, ever.
- **What is sent.** When you ask a question, NOOP builds a compact **text** summary of
  your recent metrics (Charge, Effort, Rest, HRV, resting HR over ~14 days, plus
  30-day averages and recent workouts) and sends it, with your question, directly to
  your chosen endpoint (e.g. `api.anthropic.com` / `api.openai.com` for the hosted
  providers). If you point the Coach at a local / self-hosted LLM, that endpoint is on
  your own machine and the request never leaves it.
- **What is NOT sent.** No raw biometric streams, no Bluetooth data, no account or
  device identifiers — only the summary text and your question.
- **Your key, your relationship.** The request goes from your device straight to the
  provider you picked, under your own account. NOOP runs no server in between and keeps
  no copy.

If you never enable the AI Coach, Self-hosted Sync, or Friends, never build the
Oura import in (§1.1b), and never tap **Check for updates**, NOOP makes zero
network connections — and in a default build, the Oura code isn't in the binary
to begin with.

### 1.1b The Oura history import (compiled out by default, bring your own OAuth app)

The Oura history import pulls your own historical Oura data into NOOP over Oura's official
API — a one-time, foreground backfill you trigger yourself, not an ongoing background sync
(nothing runs on a timer, at launch, or in the background):

- **Not in the binary unless you build it in.** Every file of the lane's network code
  (`Strand/Oura/*.swift` and its Data Sources card) sits behind the `OURA_CLOUD_IMPORT`
  compilation condition, which is **unset in every default build** — the release binaries
  and any plain `xcodegen && xcodebuild` from a clean checkout contain **zero Oura network
  code**, provably, at the byte level. The condition is set only by the untracked
  `Strand/Oura/OuraSecrets.xcconfig` you create yourself from the example template, which
  also carries your own Oura developer app's client ID/secret — so the code and the
  credentials arrive in the same deliberate act. Then the import runs only when you tap
  **"Import your Oura history"** in Data Sources. (Belt-and-braces, the runtime guard
  remains too: absent/blank credentials disable the lane — `OuraCredentials.fromBundle`.)
- **What is sent.** An OAuth authorization-code handshake — you sign into Oura's own
  consent page (`cloud.ouraring.com`) through Apple's system `ASWebAuthenticationSession`,
  not an in-app WebView NOOP controls — followed by bearer-token `GET` requests to
  `api.ouraring.com/v2/usercollection/*` carrying only your access token and the
  endpoint/date-range parameters needed to page through your history. No NOOP data rides
  along with these requests beyond the token itself.
- **What comes back.** Your own Oura data — sleep, readiness, activity, workouts, heart
  rate, and the other endpoints your granted scopes cover — flowing **in**, once, to seed
  your local database. Oura's own readiness/sleep scores are kept for reference only
  (`ref_*`/`oura_*` metric keys); NOOP's own Charge/Effort/Rest are never derived from
  them and are never sent anywhere.
- **What is NOT sent.** None of your existing NOOP data — no WHOOP streams, no other
  imports, no computed scores — ever leaves the device via this lane. It is inbound-only.
- **Your app, your grant, revocable at Oura.** You register your own OAuth app at Oura's
  developer portal; NOOP runs no server in between. Revoke access any time from your Oura
  account settings, or tap **Forget Oura access** in NOOP, which signs out locally and
  deletes the stored tokens plus every row this lane wrote — including the raw archive
  (`ouraRaw` table, see `docs/DATA_MODEL.md`).
- **Tokens in the Keychain, not a plist.** The access/refresh tokens are stored via
  `OuraTokenStore` as a single Keychain item (`kSecAttrAccessibleAfterFirstUnlock`), the
  same pattern as the AI Coach's API key (`AIKeyStore`) — never UserDefaults, never on
  disk in the clear.

If you never build the lane in, your binary cannot call `ouraring.com` — the code is not there.

### 1.1c Self-hosted Sync (optional, off by default)

Self-hosted Sync is a replication path to a server the user operates:

- **No endpoint, no upload.** Automatic sync defaults off. The app makes no self-host
  request until the user saves a URL and API token and enables or manually starts sync.
- **What is sent.** Decoded HR/RR/battery and supported raw sensor channels, protocol
  events, daily metrics, sleep sessions, workouts, and journal answers. Source metadata
  keeps measured strap, imported official-reference, and Noop-computed namespaces distinct.
  The wire `device_id` is scoped by client platform and app installation to prevent two
  clients from overwriting one another. Metadata carries the readable `logical_source_id`,
  unsuffixed `paired_device_id`, namespace, score provenance, and the Noop algorithm
  revision where applicable. The server requires `installation_id`,
  `logical_source_id`, `namespace`, `paired_device_id`, `privacy=explicit_opt_in`,
  and `score_provenance` on every source. It validates provenance against the
  role (`strap_measured`, `user_imported_whoop_export`,
  `noop_transparent_algorithm`, the relevant `user_imported_*` label, or
  `user_entered_noop_journal`) and rejects mixed raw/derived/journal envelopes.
- **What v1 does not send.** Gravity vectors, band sleep-state samples, PPG waveform
  blobs/derived PPG-HR storage, raw IMU blobs, compressed `rawBatch` frames, Oura raw API
  pages, arbitrary `metricSeries` rows, labs, nutrition, hydration, mood, and per-epoch
  sleep motion/state JSON remain local. Self-hosted Sync v1 is a supported-subset archive,
  not a byte-for-byte database backup.
- **Credentials.** Apple stores the Bearer token in this-device-only Keychain storage;
  Android uses encrypted preferences. The token is never stored in UserDefaults, Room,
  SQLite, logs, or server status text.
- **Transport.** Public endpoints require HTTPS. Cleartext is accepted only for validated
  loopback, `.local`, RFC1918, IPv4 link-local, or private/link-local IPv6 destinations.
  Endpoint credentials, queries, fragments, and
  cross-origin redirects are rejected.
- **Delivery.** Supported decoded rows are a durable outbox. They are marked delivered only
  after the response matches the batch id and explicitly reports `status = "accepted"`.
  Derived rows are traversed in resumable pages and idempotently upserted. A destination
  change requeues raw rows and replays up to ten years of the supported derived subset;
  this is not a promise to copy data outside the v1 boundary.
- **Scheduling.** On macOS/iOS, automatic upload is a launch/foreground catch-up plus a
  manual **Run now** action; it is not registered as a guaranteed iOS background-processing
  task. Android additionally schedules best-effort WorkManager jobs, which the OS may defer.
- **Deletion semantics.** Upload is archival and upsert-only. Deleting a row in the app
  does not send a tombstone, and disconnecting only stops future uploads. Use the
  authenticated server dashboard/API to delete server data. Keep a local
  `.noopbak`/database backup for complete local restore.
- **Operator responsibility.** The bundled FastAPI/TimescaleDB stack is not a Noop cloud.
  Whoever deploys it controls access, TLS, storage encryption, backups, retention, export,
  deletion, patching, and legal compliance.

Raw ADC fields remain labeled raw/unvalidated throughout ingestion and display. Noop does
not silently turn optical or thermistor register values into clinical SpO₂, temperature,
or respiration.

### 1.1d Private Friends (optional, self-hosted, Apple clients)

Friends is an invitation-only summary layer on the server in §1.1c. It does not
create a Noop-operated account, directory, or social graph:

- **Separate credentials.** The configured `NOOP_API_TOKEN` is used once to
  bootstrap the server owner's profile and remains the full-data/admin
  credential. The server returns a random 256-bit `noop_member_…` token for
  normal Friends use, stores only its SHA-256 digest, and can rotate or disable
  it. A first-time invited member instead has the Apple client generate its own
  256-bit member token and enrollment UUID. The client saves the token before
  the join request and reuses the same token and enrollment UUID for a
  retry-safe, idempotent enrollment if the response is lost. The server does not
  echo the plaintext invited-member token. The Apple app keeps member tokens under
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; non-secret endpoint,
  profile, display-name, and producer identifiers live in preferences.
- **Accepted-only, minimized upload.** The client fetches its accepted-friend
  visibility rules first and uploads no biometric summary values while no
  friendship is accepted. It may send empty replacement maps to clear a
  previously populated Friends window.
  Once accepted, it uploads only the union of fields currently enabled across
  accepted friends. The member token can write only a dedicated logical
  `*-noop-friends` daily producer, separate from the full self-hosted backup
  producer. Daily keys are restricted to `recovery`, `effort`,
  `sleep_performance`, `total_sleep_min`, `avg_hrv`, and `resting_hr`, with
  server-side range checks. Streams, events, sleep sessions, workouts, and
  journal entries must be empty. The credential cannot call raw, export,
  device, or admin routes; its status response omits server-wide storage
  statistics.
- **Plain-text invitation details.** Invite codes contain 96 random bits, expire
  within one to 168 hours (72 hours by default), work once, and are stored only
  as SHA-256 digests. The invitation shares the full configured server address
  and code as plain text, never an admin or member token. The recipient reviews
  and enters both manually. NOOP intentionally does not create a
  capability-bearing custom app URL, avoiding custom-scheme interception.
- **Mutual consent.** Redeeming or joining with a code creates a pending request,
  not a friendship. The original inviter must accept before either person
  appears in the other's feed or the client uploads any Friends summary. A
  first-time recipient atomically creates a scoped profile and request with the
  invite code, client-generated member token, and enrollment UUID, so the
  administrator credential is never handed to them.
- **Directional, per-friend visibility.** Charge, Effort, and Rest start enabled
  after acceptance. Sleep duration, HRV, and resting HR start disabled. Each
  owner controls their allowlist independently for each accepted friend.
- **Projection, not raw access.** The feed reads only those six fields from
  the dedicated Friends daily rows, omits values disabled for that reader, and
  starts on the friendship's acceptance date—earlier history is not returned.
  It never queries or returns raw heart rate/R-R, sensor streams, protocol
  events, location, routes, workouts, journals, sleep stages, exports, device
  identifiers, metadata, or imported WHOOP-reference rows.
- **Server-operator trust, not end-to-end encryption.** HTTPS protects the
  connection in transit, and per-friend projection limits what another member
  receives. Friends is not end-to-end encrypted: the operator of the selected
  server can inspect the membership graph and every summary field the client
  uploads (the union needed by accepted friends). Join only a server whose
  operator you trust.
- **Best-effort foreground catch-up.** When the Apple app becomes active it
  attempts at most one automatic Friends catch-up per 15 minutes. This is not a
  periodic background timer and iOS does not guarantee background delivery;
  opening or refreshing Friends is the reliable user-driven path.
- **Revocation.** Removing a friendship deletes both directional visibility
  records immediately. Blocking additionally cancels pending requests and
  prevents the blocked pair from reconnecting through another invite until
  unblocked. **Leave & delete profile** removes the member profile, credential,
  social graph, and dedicated Friends summary rows from the server, while local
  health data and a separately configured full self-hosted backup remain.
- **One server at a time.** The Apple client refuses to replace an existing
  Friends origin with an invite from another server. There is no federation,
  contacts upload, handle search, public profile, follower model, leaderboard,
  or Android Friends UI.

Anyone with both the full server address and an unredeemed code can spend that
one-time capability. Share both only with the intended recipient, use HTTPS
outside a trusted private network, and revoke an unused invite if it may have
leaked. The complete API and operator contract is in `server/FRIENDS.md`.

### 1.2 The macOS sandbox (and what it means for optional network features)

On macOS the App Sandbox is the backstop. The app ships with a minimal entitlement set
(`Strand/Resources/Strand.entitlements`):

```xml
<key>com.apple.security.app-sandbox</key>                       <true/>
<key>com.apple.security.device.bluetooth</key>                  <true/>
<key>com.apple.security.files.user-selected.read-write</key>    <true/>
<key>com.apple.security.network.client</key>                    <true/>
```

That is the entire entitlement file. Four keys:

- **`app-sandbox`** — the process runs inside the macOS App Sandbox container.
- **`device.bluetooth`** — permits BLE access to talk to the strap. The matching
  `NSBluetoothAlwaysUsageDescription` string (declared in `project.yml`) states
  plainly: *"NOOP connects directly to your WHOOP strap over Bluetooth to read heart
  rate, R-R intervals, battery, and sensor data locally. Data leaves only if you
  explicitly enable your own self-hosted server."*
- **`files.user-selected.read-write`** — lets the app read import files the user
  explicitly picks (and write the database in its own container).
- **`network.client`** — outbound socket access. Used by the explicit AI Coach,
  Oura, Self-hosted Sync, and Friends opt-ins on a
  signed/sandboxed build, where the sandbox otherwise refuses any socket the app tries
  to open (#128); the Oura history import (§1.1b) now relies on the same entitlement. The
  ad-hoc distributed build applies **no** entitlements at all (unsigned build + ad-hoc
  re-sign), so this key only matters for a signed/sandboxed build. The entitlement only
  permits the socket the sandbox would otherwise refuse — it doesn't make either feature
  call out on its own; every destination remains gated by its own user action.

Notably **absent**:

- `com.apple.security.network.server` — no inbound listener.
- No `files.downloads`, `files.documents`, or any broad filesystem entitlement —
  the app cannot wander the disk; it sees only what the user hands it through the
  open panel, plus its own sandbox container.

This is the structural guarantee behind "local by default" on macOS: the sandbox
permits outbound access required by the deliberate opt-ins above, while app logic gates
each request — no
undeclared entitlement could smuggle out a connection the user didn't ask for. The
property is enforced by the OS, not merely by convention.

> **Note on Hardened Runtime.** `project.yml` currently sets
> `ENABLE_HARDENED_RUNTIME: NO` for local development builds. Distributable /
> notarized builds should enable the Hardened Runtime; it composes with, and does
> not weaken, the sandbox entitlements above.

### 1.3 iOS Apple Health export ("Export for Shortcuts") — on-device, user-initiated, one-way

On iOS NOOP can hand your metrics to **Apple Health**. This is the one path where data leaves
NOOP's own store — but it never leaves your **device**, and never touches the network.

- **You initiate it; NOOP writes only what you enable.** Nothing is exported automatically. You
  choose which metrics to push, and NOOP writes only those, only when you trigger the export. There
  is no background sync.
- **On-device, not a network upload.** The export is a local hand-off to Apple Health on the same
  phone. No NOOP server, no cloud, no telemetry is involved — consistent with §1.
- **HealthKit-free option.** The **"Export for Shortcuts"** path produces data for the Apple
  Shortcuts app rather than writing through HealthKit directly, so you can route it with a Shortcut
  you control. Where it does write to Apple Health, it does so through Apple's permission-gated APIs:
  you grant access per data type, and you can revoke it in iOS Settings at any time.
- **Once it's in Apple Health, it's yours and Apple's, not NOOP's.** NOOP cannot read back, manage,
  or delete what you exported; that store, its backups (e.g. iCloud Health if *you* enabled it), and
  its sharing settings are governed by Apple and by your choices. **You are responsible for the data
  you push into Apple Health and for anything you or your Shortcuts then do with it.** See
  `DISCLAIMER.md` §5.3 and `TERMS.md` §5.

---

## 2. Data at rest

### 2.1 Where the data lives

All durable data is stored in a single GRDB/SQLite database. The Swift apps (macOS and
iOS, which share the `WhoopStore` package) open it at (`Strand/Collect/StorePaths.swift`):

```
<Application Support>/OpenWhoop/whoop.sqlite
```

Because the app is sandboxed, `<Application Support>` resolves **inside the app's
sandbox container**, not the user's global `~/Library/Application Support`. Other
apps cannot read it through normal filesystem access. (On Android the equivalent store
is a Room/SQLite database in the app's private storage; the rest of this section
describes the GRDB/SQLite store shared by the macOS and iOS apps.)

The schema is defined by a versioned `DatabaseMigrator` in
`Packages/WhoopStore/Sources/WhoopStore/Database.swift` (currently through migration
`v30-remote-sync-pending-indexes`).
It holds exactly the kinds of data you would expect from the features:

- **Decoded biometric streams** (durable): `hrSample`, `rrInterval`, `spo2Sample`,
  `skinTempSample`, `respSample`, `gravitySample`, `battery`, `event`.
- **Derived/cached metrics**: `sleepSession`, `dailyMetric`, `workout`, `journal`,
  `appleDaily`, and the generic long-format `metricSeries`.
- **Your own entries and imports**: daily **mood check-ins** (the Mind feature) and imported
  **nutrition** figures (from a Cronometer / MacroFactor CSV) are stored locally in this
  database. Those `metricSeries` sources are outside the v1 self-hosted-sync subset. Native
  journal answers are a separate table and are uploaded when Self-hosted Sync is enabled.
  They are self-tracking notes, not clinical records (see `DISCLAIMER.md` §5).
- **A transient raw outbox** (`rawBatch`): compressed raw BLE frames, **prunable**.
- **Device records** (`device`): strap id, MAC, name, first/last-seen timestamps.

The database is opened in WAL journal mode with `synchronous = NORMAL` and a busy
timeout, tuned for bulk import/backfill writes
(`Packages/WhoopStore/Sources/WhoopStore/WhoopStore.swift`). WAL means you will also
see `whoop.sqlite-wal` and `whoop.sqlite-shm` sidecar files alongside the main
database — they live in the same container.

### 2.2 Encryption

The SQLite file is **not encrypted at rest by NOOP itself.** Confidentiality of the
data on disk relies on the platform:

- **FileVault** (full-disk encryption, on by default on modern Macs) protects the
  database whenever the disk is at rest / the machine is powered off. On iOS and
  Android the equivalent is the platform's on-by-default device encryption / data
  protection, which guards the file while the device is locked.
- The **sandbox container** (app container on macOS/iOS, private app storage on
  Android) keeps other user-space apps from reading the file directly.

What this does **not** protect against: an attacker with your unlocked, logged-in
session, or a backup/Time Machine copy of the container made while FileVault is
unlocked. The data is plaintext SQLite once the volume is mounted.

> **Option: SQLCipher.** GRDB supports SQLCipher (an encrypted SQLite build) as a
> drop-in. Wiring NOOP's `DatabaseQueue` to a SQLCipher build with a
> Keychain-derived key would give at-rest encryption independent of FileVault. This
> is not enabled in the current build, but the persistence layer is small and
> centralized (one `WhoopStore.init(path:)`), so it is a contained change.

### 2.3 Data minimization & pruning

The raw-frame outbox (`rawBatch`) is treated as transient, not as the system of
record — the decoded streams are durable, the raw frames are a compressed,
**prunable** buffer. The prune policy in
`Packages/WhoopStore/Sources/WhoopStore/RawOutbox.swift` deletes old batches:

```sql
DELETE FROM rawBatch WHERE syncedAt IS NOT NULL AND syncedAt < ?
```

So raw captures do not accumulate forever. The compressed `rawBatch` frames themselves
are never sent by Self-hosted Sync; only supported decoded rows use the separate durable
delivery flags. The raw buffer remains a local replay/recovery aid.

### 2.4 Diagnostics: the strap connection log

When a strap won't connect or behaves oddly, the single most useful thing a user can
send is the connection log. NOOP keeps one so it can be shared **without** needing
`adb` or a developer setup (this is what made issues #17/#18 reportable), and the same
log doubles as the primary tool for **debugging and protocol development** (see
`ANDROID.md` → "Debugging the strap connection").

**What it is.** The BLE client (`android/.../ble/WhoopBleClient.kt`,
`Strand/BLE/BLEManager.swift` on the Swift side — macOS and iOS) keeps an **in-memory
ring buffer** — the last
2000 log lines on Android — of the connection's control flow: scan results (strap
advertised name + RSSI), the bond/handshake state machine, command names with their
outbound payload **hex**, and offload progress (trim cursors, chunk acks). It is held
in RAM only; the "Share strap log" button writes it to a private app-cache file at
share time and hands that file to the OS share sheet. Nothing is uploaded by NOOP.

**What it does *not* contain.** No account credentials (there is no account), no
decoded biometric *values* (heart-rate numbers, R-R intervals, SpO₂, skin-temp are not
written to the log — only control-plane command names and frame-routing), and no
hello-token or serial hex (the handshake lines log *that* a step happened, not its
secret payload). The one mild identifier is the strap's advertised name (e.g.
`WHOOP 5AG…`), which the user chooses to include when they tap Share.

**logcat is opt-in (debug mode), off by default.** By default the log is mirrored
**only** to the in-app buffer — it is *not* written to Android's system log
(`Log.d`/logcat). A user has no reason to emit the connection log to the device-wide
log, so they don't. Developers who want to watch a session live over
`adb logcat -s WhoopBleClient` turn on **Settings → Strap → "Debug logging"**
(persisted as `NoopPrefs.KEY_DEBUG_LOGGING`, default `false`); the flag drives
`WhoopBleClient.debugLogcat`, which gates the single `Log.d` call. The in-app buffer
and the "Share strap log" export work the same whether or not debug logging is on, so
the diagnostic path is always available without ever defaulting users into logcat.

### 2.5 Wrist alerts: the Android notification listener

Android wrist alerts (buzz the strap when chosen apps notify you) need a
`NotificationListenerService` — that's the only way to register in the OS's
**Notification Access** list and be told a notification was posted. Notification
access is a powerful permission, so for a privacy-first app it's worth being precise
about what NOOP does and does not do with it:

- **Off by default, double opt-in.** The service does nothing until you both grant
  Notification Access in system settings *and* turn on **Wrist alerts** in NOOP, then
  enable specific apps (each app is off by default).
- **It reads only the posting package name — never content.** On a posted
  notification NOOP looks at *which app* posted (and skips ongoing / foreground-service /
  group-summary noise), checks your settings (master toggle, that app's opt-in, quiet
  hours, only-when-worn), and if all pass, sends a haptic-pattern command to the strap.
  The notification's title, text, sender, and extras are never read, stored, logged, or
  transmitted.
- **Nothing from a notification leaves the device.** The optional self-hosted
  server is not involved; the only output is a Bluetooth buzz to your own strap.
  (`android/.../notif/NoopNotificationListener.kt`.)

---

## 3. Threat model

NOOP parses three classes of **untrusted input**: bytes arriving over Bluetooth,
files chosen for import, and responses/capabilities from user-configured network
destinations. They are treated as hostile and validated before they can update
trusted app state. Apple Health and WHOOP files in particular can be very large
(multi-hundred-MB to multi-GB), so resource exhaustion is part of the model.

What is explicitly **out of scope**: NOOP cannot defend the data against an attacker
who already controls your unlocked user session (see §2.2), and it makes no claim of
cryptographic authentication of the strap — BLE pairing/bonding security is provided
by the OS Bluetooth stack and the device, not by NOOP.

### 3.1 Threat A: a malicious or malfunctioning BLE peer

A device advertising as a strap (or a glitching real strap) could send malformed,
truncated, oversized, or adversarial frames. The protocol core
(`Packages/WhoopProtocol/`) is the reverse-engineering layer and is the first line of
defense.

**CRC-gated parsing.** Every frame is checked against its checksums before it is
allowed to drive any application state. `Framing.swift` implements three checksums
verbatim from the wire formats:

- `crc8` (poly 0x07) over the length header,
- `crc32` (zlib/reflected) over the inner payload,
- `crc16Modbus` for the WHOOP 5.0 header (ported from the `goose` work).

`verifyFrame(_:)` (and the family-aware `verifyFrame(_:family:)`) only return
`ok == true` when the header CRC **and** the payload CRC32 both validate:

```swift
let ok = crc8OK && (crc32OK ?? false)
```

The live BLE path then refuses anything that fails. In
`Strand/BLE/FrameRouter.swift`:

```swift
let parsed = parseFrame(frame)
guard parsed.ok else { return }
// Reject frames that failed their checksum — never let bad bytes drive state.
if parsed.crcOK == false { return }
```

The same gate guards clock correlation (`Strand/Collect/ClockCorrelation.swift`
requires `parsed.ok, parsed.crcOK != false`), so a corrupt frame can neither update
the displayed metrics nor poison the device-clock model.

**Bounds-checked decoding.** Field reads never index past the end of the buffer. The
low-level readers in `Interpreter.swift` return `nil` instead of trapping when a read
would run off the end of the frame:

```swift
@inline(__always) private func readU16(_ f: [UInt8], _ off: Int) -> Int? {
    off + 2 <= f.count ? Int(f[off]) | (Int(f[off + 1]) << 8) : nil
}
```

Schema-driven field extraction skips any field whose offset is out of range
(`guard let val = readDType(frame, fld.off, dtype) else { continue }`), and the
`FieldBuilder` clamps every slice to the real buffer length
(`let end = min(off + length, frame.count)`). The WHOOP 5.0 path adds explicit
minimum-length and `payloadEnd <= frame.count` guards before slicing the payload or
trailer. A short or lying length field therefore yields a partial parse, never an
out-of-bounds read.

**Sane-value gating at the application edge.** Even a CRC-valid frame is range-checked
before it updates the UI/state. The realtime handler discards implausible heart rates
(`hr >= 30, hr <= 220`) and only overwrites R-R intervals when the frame actually
carries them — so a single bad-but-valid packet can't wipe good state.

**Reassembly is bounded by the declared length.** The `Reassembler` resynchronizes on
the `0xAA` start-of-frame byte, discards leading garbage, and only emits a frame once
`length + 4` bytes are present — it does not unboundedly buffer arbitrary data.

### 3.2 Threat B: a malicious import file (zip bombs, XML bombs, huge exports)

Both importers live in `Packages/StrandImport/` and assume the file is hostile.

**Apple Health (`AppleHealthImporter.swift`).** Apple Health exports routinely exceed
1 GB, and a malicious one could be far worse.

- **Streaming SAX parse, never DOM.** The importer parses with `XMLParser` /
  `XMLParserDelegate` over an `InputStream` opened directly on the file. It explicitly
  does **not** use `XMLParser(contentsOf:)`, which would load the whole multi-hundred-
  MB document into memory first. Element handling runs inside a per-element
  `autoreleasepool` so temporaries from tens of millions of elements drain instead of
  accumulating — peak memory stays bounded regardless of file size.
- **Zip-bomb cap on decompression.** When the input is a `.zip`, `export.xml` is
  extracted to a temp file in fixed-size chunks with a running budget; the moment the
  decompressed total crosses the ceiling, extraction aborts:

  ```swift
  var written = 0
  let cap = 8 << 30   // 8 GB decompressed ceiling — zip-bomb guard
  _ = try archive.extract(entry, bufferSize: 1 << 20) { chunk in
      written += chunk.count
      if written > cap { throw ImportError.xmlParseFailed("export.xml too large") }
      try handle.write(contentsOf: chunk)
  }
  ```

  Chunks go straight to disk, so a bomb cannot inflate RAM. This deliberately replaced
  an earlier pipe-fed parser that could deadlock or crash on a malformed export.
- **Robust error handling.** Parse failures are surfaced as typed `ImportError`s; the
  delegate distinguishes a genuinely malformed document from a benign empty/EOF
  condition rather than crashing.
- **Temp files are cleaned up** via `defer { try? FileManager.default.removeItem(at: tmp) }`.

**WHOOP CSV export (`WhoopExportImporter.swift`).** The WHOOP data export is a small
bundle of CSV files, but the same defensive posture applies.

- **Per-entry size ceiling.** Each CSV is capped at 256 MB
  (`maxEntryBytes = 256 << 20`). Folder imports skip any file larger than the cap;
  zip imports reject entries whose *declared* uncompressed size exceeds it **and**
  enforce a running byte budget during extraction, so a ZIP64 header that lies about
  its size is still stopped mid-stream:

  ```swift
  let declared = Int(exactly: entry.uncompressedSize) ?? Int.max
  if declared > Self.maxEntryBytes { continue }
  ...
  if written > Self.maxEntryBytes { throw CancellationError() }
  ```

- **CRC32 verification on extraction.** `archive.extract()` verifies each entry's
  CRC32 (ZIPFoundation's `skipCRC32` defaults to `false`) and throws on a mismatch or
  truncation. A corrupt/truncated/oversized entry is skipped entirely rather than
  partially imported — no half-rows reach the database.
- **Filename allow-list.** Only four known CSV names
  (`physiological_cycles.csv`, `sleeps.csv`, `workouts.csv`, `journal_entries.csv`)
  are ever read; everything else in the archive is ignored. Matching is by filename,
  case-insensitively, so the parser never executes or interprets arbitrary archive
  members.
- **Tolerant, header-name-driven parsing.** Columns are matched by normalized header
  name (not position), every column is optional, BOMs are stripped, and rows with no
  usable timestamp are dropped. Malformed input degrades to fewer rows, not a crash.

**Nutrition CSV (`NutritionCsvImport.swift`).** The nutrition importer (Cronometer /
MacroFactor daily-summary exports) reuses the same shared CSV reader (`CSVParsing.swift`)
and the same tolerant posture: headers are matched case-insensitively by name (date /
calories / protein / carbs / fat / weight), every column is optional, non-`yyyy-MM-dd`
dates and value-less rows are **skipped and counted, never fatal**, and only the
recognised numeric fields are read — no archive member or cell is ever executed or
interpreted. The result is projected into the long-format `metricSeries` store under the
dedicated source id `nutrition-csv`, alongside your other metrics and entirely on-device.

### 3.3 Threat C: malicious Friends invitation details or server

NOOP does not register a capability-bearing custom URL. An invitation is the
full server address and one-time code in plain text, and the recipient manually
reviews and enters both. This avoids custom-scheme interception, but it does not
make the code secret: anyone who obtains both values before redemption can spend
the capability. Use a trusted sharing channel and revoke a suspected leak.

Before any request, the client applies the same endpoint validator as
Self-hosted Sync: public destinations require HTTPS; URL credentials, query
configuration, fragments, and unsafe cleartext hosts are rejected. The join
sheet displays the full destination and the default/optional/never-shared
categories before the request. If a member profile already exists, the invite
must have the same normalized endpoint; the app refuses to migrate the stored
member credential to another origin.

For first enrollment, the client creates and Keychain-saves a 256-bit member
token plus an enrollment UUID before sending the request. A lost response can
therefore retry the same enrollment safely: the server returns the original
result for that enrollment, while a different enrollment cannot claim the
already consumed invite. Server-side transactional redemption prevents a raced
or invalid join from leaving an orphan profile. Responses are decoded into fixed
models, cross-origin/downgrade redirects are rejected by the shared client, and
server error text is redacted for both administrator and member credentials.

The server remains a trust boundary. Friends is not end-to-end encrypted, so a
malicious or compromised operator can inspect the social graph and the summary
field union uploaded for accepted friends. Other members are restricted to
their directional projections from the friendship acceptance date, and even a
valid member credential can access only daily-summary and social routes in
§1.1d; raw-data authorization is enforced again by the server rather than by UI
visibility alone.

---

## 4. What NOOP does *not* collect or transmit

- **No Noop-operated account or login.** Core use requires no identity. An
  optional self-hosted Friends profile uses a local scoped member credential
  (§1.1d)—server-issued for owner bootstrap or client-generated for an invited
  first join. It is not a Noop account and is never sent to a Noop-operated service.
  Separately, Oura history import (§1.1b) has *you* sign into *your own* Oura
  account, at Oura's login page, over OAuth—NOOP never sees your password, only
  the resulting tokens kept in Keychain.
- **No telemetry / analytics / crash reporting.** No third-party SDKs of that kind.
- **No Noop-operated cloud.** Self-hosted Sync and Friends (§1.1c–d) use only the
  endpoint you configure; both are optional. Oura history import is inbound-only.
- **No advertising identifiers, no tracking.**
- **No WHOOP account or API credentials.** NOOP talks only to the strap over local
  BLE; it does not authenticate against, or pull from, any WHOOP server. (Oura is the
  one account-based exception — see above and §1.1b.)

---

## 5. Hardening summary

| Surface | Risk | Mitigation | Where |
|---------|------|------------|-------|
| Process | Data exfiltration / network egress | Three explicit destinations: AI Coach (your provider/key and text summary — §1.1a), Oura import (your OAuth app, inbound-only — §1.1b), and your self-hosted server (Sync plus optional Friends — §1.1c–d). No telemetry or project-operated cloud. | `Strand/AI/`, `Strand/Oura/`, `Packages/NoopRemoteSync`, `Strand/Data/RemoteSyncService.swift`, `Strand/Data/FriendsService.swift`, Android remote-sync client |
| Self-hosted sync | Token leak, cleartext egress, redirect exfiltration, lost backfill | Token in Keychain/encrypted preferences; HTTPS required except validated local/private literals; URL credentials/query/fragment rejected; redirects cannot cross origin or downgrade transport; error reflection redacted; per-row acknowledgement only after a matching accepted response; resumable, bounded replay on destination change. Local deletions require a separate authenticated server delete. | `Packages/NoopRemoteSync`, `Packages/WhoopStore/.../RemoteSyncStore.swift`, `server/` |
| Private Friends | Invite theft, retry races, over-broad access, operator visibility, unwanted continued sharing | Plain-text server address + one-time code with manual review and no custom capability URL; hashed codes/tokens; client-generated Keychain token plus idempotent enrollment UUID; no biometric summary values before acceptance; empty replacement maps clear stale shares; accepted-friend field union limited to six range-checked keys; dedicated `*-noop-friends` producer; per-friend projection only from acceptance date; explicit not-E2E/operator-trust disclosure; remove/block/token rotation and Leave & delete controls; foreground catch-up is best effort, not guaranteed background delivery. | `Strand/Data/FriendsService.swift`, `Strand/Screens/FriendsView.swift`, `Packages/NoopRemoteSync`, `server/FRIENDS.md`, `server/migrations/003_friends.sql` |
| Oura history import | OAuth token / scope leakage, cross-account data mixing | Compiled out by default (`OURA_CLOUD_IMPORT`, §1.1b); tokens Keychain-only (`kSecAttrAccessibleAfterFirstUnlock`, never UserDefaults/plist); fixed OAuth scopes set at build time; raw + normalized rows partitioned under `deviceId = "oura-api"`; Oura's own scores kept reference-only (`ref_*`/`oura_*` metricSeries keys, never NOOP's Charge/Effort/Rest); `.cloudImport` is structurally priority-2 so it never seizes a WHOOP day; Forget Oura access purges tokens + every `oura-api` row incl. the raw archive | `Strand/Oura/OuraTokenStore.swift`, `Strand/Oura/OuraConnectModel.swift`, `Packages/WhoopStore/Sources/WhoopStore/OuraRawStore.swift` |
| Filesystem | Broad disk access | Only `files.user-selected.read-write`; data stays in the sandbox container | `Strand.entitlements`, `Strand/Collect/StorePaths.swift` |
| BLE frames | Malformed / adversarial packets | CRC8 + CRC32 (+ CRC16 for v5) gating; reject on failure | `WhoopProtocol/Framing.swift`, `Strand/BLE/FrameRouter.swift` |
| BLE frames | Out-of-bounds reads from short/lying length | `nil`-returning bounds-checked readers; slice clamping; min-length guards | `WhoopProtocol/Interpreter.swift` |
| BLE frames | Garbage / partial fragments | SOF-resync reassembler bounded by declared length | `WhoopProtocol/Framing.swift` (`Reassembler`) |
| App state | Implausible-but-valid values | Range gates (e.g. HR 30–220) at the state edge | `Strand/BLE/FrameRouter.swift` |
| Health import | XML bomb / multi-GB DOM blowup | Streaming SAX over `InputStream`; per-element autorelease pool | `StrandImport/AppleHealthImporter.swift` |
| Health import | Zip bomb | 8 GB decompressed ceiling, chunked to disk, hard abort | `StrandImport/AppleHealthImporter.swift` |
| CSV import | Zip bomb / oversized entries | 256 MB per-entry cap (declared + running budget); CRC32 verify | `StrandImport/WhoopExportImporter.swift` |
| CSV import | Arbitrary archive members | Filename allow-list; tolerant optional-column parsing | `StrandImport/WhoopExportImporter.swift` |
| Data at rest | Disk theft / offline access | Relies on FileVault + sandbox container; SQLCipher available as an option | `WhoopStore/WhoopStore.swift` |
| Diagnostics log | Leaking the strap log to the device-wide system log | In-app ring buffer only; logcat mirroring is **opt-in** (Settings → Strap → "Debug logging", default off); no biometric values / tokens logged (§2.4) | `android/.../ble/WhoopBleClient.kt` (`debugLogcat`), `android/.../ui/MainActivity.kt` (`NoopPrefs`) |

---

## 6. Reporting a security issue

NOOP is a hobbyist, non-commercial interoperability and research project provided
**as-is, with no warranty**, for personal and educational use only (see
`DISCLAIMER.md`). If you find a security or privacy issue, please open a GitHub issue
describing the problem and a reproduction; sensitive reports can be coordinated
privately via the contact on the project's GitHub profile. Issues will be reviewed in
good faith.

---

## 7. Credits

The protocol and persistence work NOOP builds on is community reverse-engineering of
hardware the user owns, used for interoperability:

- **`johnmiddleton12/my-whoop`** — the WHOOP 4.0 BLE framing/command/decode work and
  the collection logic the `WhoopProtocol` / `WhoopStore` packages and the app's
  collection layer are adapted from.
- **`b-nnett/goose`** — published observed WHOOP 5.0 protocol facts (the
  `fd4b0001-…` service family, the CRC16-Modbus header, and the "puffin" packet
  types). Its repository has no explicit software license; this fork copies none
  of its source or assets.
- **`groue/GRDB.swift`** — the SQLite persistence layer.
- **`weichsel/ZIPFoundation`** — the archive reader used by the importers.

See `ATTRIBUTION.md` and `DISCLAIMER.md` for the full attribution and good-faith
notice. NOOP contains no WHOOP proprietary code, firmware, binaries, logos, or
assets, and performs no DRM circumvention.
