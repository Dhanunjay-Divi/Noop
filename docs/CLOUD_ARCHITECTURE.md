# NOOP cloud architecture

**Status:** synthetic IAM-only staging deployed; mobile clients disconnected
**Primary staging region:** Google Cloud Mumbai (`asia-south1`)

Firebase Identity Platform, App Check, Cloud SQL, managed API, processor,
lifecycle scheduler, KMS, Pub/Sub, and object storage are deployed for
synthetic testing. The managed API has no public invoker, no released mobile
configuration points to it, and no real health data is permitted in staging.

## Product boundary

NOOP remains local-first:

- The current compatible-device path and app exploration/import path work
  without an account.
- A first-party NOOP Band release requires one network-backed ownership claim.
  After activation, BLE collection, local SQLite history, scoring, export, and
  supported local device control work without NOOP+, payment, subscription, or
  continuous network.
- Existing users are never silently enrolled or uploaded.
- Core metrics are not a subscription entitlement.
- Self-hosted Sync remains available for a destination the user controls.
- NOOP+ is a separate, explicit managed-sync consent and trust boundary.

Cloud does not fix a suspended phone process or a dropped BLE link. It reduces
long-term phone storage, makes off-device backup and multi-device sync possible,
and gives foreground catch-up somewhere durable to land. iOS and Android
background execution remain best effort, so both clients still need bounded
local buffering, resumable transfer, visible freshness, and foreground catch-up.

## Current staging

OpenTofu in `infra/gcp/` manages:

- protected remote state and a USD 50 monthly budget alert;
- a regional immutable Artifact Registry and dedicated build identity;
- regional KMS keys and a CMEK raw-chunk bucket with 30-day staging retention;
- Storage finalize events through regional Pub/Sub;
- separate API, processor, and migration service accounts;
- empty regional Secret Manager containers;
- an empty regional BigQuery dataset reserved for reviewed derived analytics;
- an optional deletion-protected PostgreSQL 16 Cloud SQL instance;
- a one-shot Cloud Run migration job and an internal-ingress private API.

The private and managed APIs use a digest-pinned image, IAM, Secret Manager, the
Cloud SQL connector, scale-to-zero, and `/readyz` as the startup gate. Neither
has a public invoker. The Safety worker is disabled. The managed processor,
lifecycle job, scheduler, phone identity, and enforced Authentication App Check
are deployed. No real health data belongs in this environment.

## Target data plane

The current server still accepts row-oriented v1 sync for self-hosting. The
separate managed implementation now uses:

1. The phone writes measurements locally first and computes all user-facing
   metrics locally.
2. A durable mobile outbox groups bounded time windows into compressed,
   checksummed chunks with schema version, source provenance, event-time range,
   and an idempotency identifier.
3. After NOOP+ identity and consent, the API issues a short-lived upload
   capability scoped to exactly one opaque object key and size/content contract.
4. Cloud Storage stores immutable raw chunks. Object paths must not contain an
   email, name, phone number, wearable serial, or readable health label.
5. Pub/Sub queues finalize events. An idempotent processor validates checksum,
   decompression limits, schema, tenant ownership, and provenance before writing
   only indexes and derived/queryable rows to PostgreSQL.
6. PostgreSQL stores identity/control state, object manifests, sync cursors,
   daily aggregates, sleep/workout summaries, deletion state, and social
   projections. It should not duplicate every high-rate raw sample indefinitely.
7. BigQuery receives nothing until a separate purpose, minimization, consent,
   retention, and deletion review approves a derived dataset.

The Swift, Kotlin, FastAPI, PostgreSQL, Cloud Storage, processor, restore,
export, erasure, and lifecycle code for this path is implemented and locally
tested. Native Apple and Android clients can use the restore snapshot as a
consistent export anchor, page every retained managed data class and current
personal record, verify object digests plus snapshot totals, and write a
manifest-backed ZIP that includes cloud-only history. This path is distinct
from `/exports`, which stores a client-produced encrypted archive. Neither path
is a production claim until the live synthetic and physical gates pass.

Raw backup and server-readable sync are different products. A true private
backup should use client-side encryption with a user-recoverable key, making its
objects opaque to NOOP. Server-side trends, Friends, and coaching require a
separately disclosed server-readable subset. Do not describe one as the other.

## Identity and authorization

Private synthetic staging currently uses phone OTP, restricted to reviewed SMS
regions. The first-party release target changes the base ownership account to
verified email/password with an optional linked phone verified by OTP. Passwords
remain inside the managed identity provider; NOOP applications and services
must never receive or store plaintext credentials. App Attest on iOS and Play
Integrity on Android remain the selected App Check providers. The apps
initialize Firebase only when every ignored environment value is present.

Band ownership identity and NOOP+ health-data consent are separate. A verified
ownership account can claim only after fresh app attestation and
cryptographically authenticated proof from the selected pairing-mode band.
Claiming a band uploads no health history and grants no NOOP+ entitlement. A
NOOP+ upload still requires the versioned managed-storage policy and applicable
payment/entitlement state.

The source implements reauthentication for account erasure, per-installation
credentials, device revocation, a 24-hour deletion cooling-off/cancel path, and
account-scoped restore. Identity and App Check resources are deployed for
synthetic staging. Public rollout remains blocked until signed-device
attestation is proven and enrollment abuse, recovery, lost-device,
support-access, and erasure operations pass review.

Identity Provider authentication is only the first boundary. Every database row,
object manifest, signed upload capability, export, and delete operation must
also carry and enforce an internal tenant identifier. App Check or device
attestation may reduce abuse but cannot replace authorization.

The ownership control plane requires additive, tenant-isolated account, band,
claim, installation, possession-challenge, release, and ownership-event
records. It stores no sensor payloads. Claim is atomic and idempotent, returns
privacy-preserving conflict states, and recovers from partial provisioning.
Approved release revokes owner keys and removes personal band state before
another account can claim it. Return, RMA, account recovery, deletion, dispute,
and future eligible-upgrade paths remain launch gates.

## Terms and return control plane

The target terms service stores immutable content-addressed documents and a
signed locale/version manifest in NOOP-controlled object storage. Public terms
URLs are stable and unauthenticated. Claim clients fetch with an ephemeral
no-persistent-cache session, verify the manifest and digest, render sanitized
static content, and write no full terms document to app storage. The account
service records only the accepted document version/hash, locale, policy
version, and server time. Every accepted historical version remains available.

Terms publication needs integrity, version-race, rollback, availability,
latency, accessibility, localization, and retention controls. Content cannot
run arbitrary script or include third-party trackers, advertising,
fingerprinting, or credential capture. A terms outage blocks a new ownership
claim but cannot interrupt an already-activated band's local operation.

Return records remain separate from health data. The pending policy must select
14 or 30 calendar days and its start event, then encode eligibility, return
authorization, shipment, inspection grade, lawful disclosed refund deduction,
original-payment-rail refund, appeal, and terminal outcome. An accepted return
or RMA creates an operator-only release task that revokes owner credentials,
wipes personal band state, removes the account relationship, and quarantines
the unit for approved refurbishment, reprovisioning, or destruction.

## Managed Friends boundary

Managed Friends is an optional social projection inside NOOP+, not a public
social network and not a dependency of core NOOP or self-hosted Friends:

- Each enrolled account may separately create one managed Friends profile. The
  service assigns a random, rotatable exact-match NOOP ID; there is no browseable
  name directory, contact upload, suggested-profile graph, or follower count.
- A profile link carries only the exact-match alias. An invitation link carries
  a random, server-hashed capability that expires, can be revoked, and creates a
  pending request. Both currently use the registered `noop://` app scheme; a
  production HTTPS universal/app-link domain and fallback remain launch gates.
- Mutual acceptance precedes sharing. Each owner independently grants each
  friend access to any subset of Charge, Effort, Rest, sleep duration, HRV, and
  resting heart rate. Raw streams, locations, journals, stages, workouts,
  routes, and device identifiers are not part of the projection.
- Badges acknowledge connection or the presence of seven/30 projected days.
  They do not rank health values, compare users, or affect a wellness metric.
- Pokes require the recipient's global opt-in and per-friend permission, and
  enforce quiet hours, blocks, cooldowns, daily limits, expiry, leased claims,
  and idempotent acknowledgement. The current clients claim during best-effort
  background or foreground catch-up and then request a generic local
  notification and eligible worn-band haptic.
- There is no APNs/FCM remote delivery in the current implementation. A closed
  app therefore does not receive an immediate poke. Any future wake path must
  use a minimal opaque payload, avoid health/profile content, support token
  deletion and rotation, and pass privacy and physical-device review.

PostgreSQL holds this bounded control and six-field projection state. Expired
invites, requests, pokes, summaries, and revoked aliases are lifecycle-managed;
deleting a managed Friends profile cascades its social state without deleting
the NOOP+ backup account or on-device data.

## Retention and deletion

Retention is explicit by data class and tier. The optional
**Reduce phone storage after backup** setting keeps seven days of high-rate raw
optical, motion, and auxiliary streams plus 30 days of essential time series.
It prunes only an exact server-validated, clean, supersession-aware window and
retains summaries, user-authored records, dirty windows, and unvalidated data.
It is off by default.

Local deletion cannot be introduced merely to force payment. Before this policy
ships it still needs:

- an in-app disclosure before enablement;
- export before expiry;
- storage-pressure behavior that never blocks BLE collection;
- server export and account erasure;
- object, database, cache, replica, and backup deletion timelines;
- retained non-biometric tombstones only where replay protection requires them.

The current synthetic raw bucket deletes objects after 30 days. That is a
staging cleanup control, not the final subscriber retention policy.

## Scaling path

Use measured thresholds rather than starting with Kubernetes. The complete
regional-cell and customer-day design is in
[`PLATFORM_ARCHITECTURE.md`](PLATFORM_ARCHITECTURE.md).

1. **Synthetic staging:** shared-core single-zone Cloud SQL, Cloud Run
   scale-to-zero, no mobile clients.
2. **Private pilot:** production-sized Cloud SQL, HA/PITR, minimum instances,
   public HTTPS edge plus Identity Platform, processor service, restore and
   erasure drills, and explicit testers only.
3. **Early production:** multi-zone database, PgBouncer or bounded connector
   pools, distributed rate limits, queue backpressure, SLOs/on-call, off-region
   backups, and load/isolation evidence.
4. **Growth:** partition manifests/aggregates, separate ingestion and read
   services, add read replicas/caches only from observed bottlenecks, and move
   cold objects by lifecycle policy.

Standard PostgreSQL is intentional. It keeps the service portable across GCP,
AWS, Azure, or a later specialist provider. GCP is selected now because the
project exists, Mumbai provides India residency/latency, and Cloud Run, Cloud
SQL, Storage, Pub/Sub, KMS, and Identity Platform provide the smallest managed
operational surface. OpenTofu and digest-pinned containers reduce, but do not
eliminate, provider migration work.

## Launch gates

Mobile connection to a public managed endpoint remains blocked until all of
these pass:

- public identity, recovery, consent, and support-access review;
- email verification, optional phone linking, band possession proof, atomic
  single-owner claim, replacement-phone authorization, account deletion,
  controlled release, and India/USA transfer-policy review;
- immutable remote terms publication/acceptance plus approved return duration,
  inspection, lawful deduction, refund, appeal, and operator wipe/release;
- deployed immutable chunk upload and processor validation;
- tenant-isolation and cross-tenant adversarial tests;
- synthetic upload, duplicate, reconnect-burst, export, erasure, and retention
  tests;
- large-account export cancellation, snapshot-expiry, token-refresh, and
  archive-import tests;
- Cloud SQL restore, point-in-time recovery, zone-failure, and secret-rotation
  drills;
- cost/load tests using measured device cadence and compressed chunk sizes;
- privacy/legal review for India and every launch market;
- physical iOS and Android background/foreground catch-up tests;
- production HTTPS universal/app links, abuse reporting/support operations, and
  minimal remote poke wake delivery or an explicit non-immediate product
  disclosure.

Infrastructure readiness is not metric-accuracy evidence, medical validation,
or permission to upload a user's data.
