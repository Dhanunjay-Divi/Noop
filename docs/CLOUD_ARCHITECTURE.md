# NOOP cloud architecture

**Status:** synthetic staging foundation; mobile clients disconnected
**Primary staging region:** Google Cloud Mumbai (`asia-south1`)

## Product boundary

NOOP remains local-first:

- BLE collection, local SQLite history, scoring, export, and device control work
  without an account or network.
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

The private API uses a digest-pinned image, IAM, Secret Manager, the Cloud SQL
connector, scale-to-zero, and `/readyz` as its startup gate. It has no public
invoker. The Safety worker is disabled. No real health data belongs in this
environment.

## Target data plane

The current server accepts row-oriented v1 sync. That is useful for self-hosting
and contract tests, but it must not become the high-frequency managed ingestion
format for a large subscriber base.

The managed path should use:

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

Raw backup and server-readable sync are different products. A true private
backup should use client-side encryption with a user-recoverable key, making its
objects opaque to NOOP. Server-side trends, Friends, and coaching require a
separately disclosed server-readable subset. Do not describe one as the other.

## Identity and authorization

The staging APIs for Identity Platform are enabled, but no provider is selected.
Public rollout remains blocked until enrollment proof, account recovery,
lost-device handling, reauthentication, support access, revocation, and erasure
are designed together.

Identity Provider authentication is only the first boundary. Every database row,
object manifest, signed upload capability, export, and delete operation must
also carry and enforce an internal tenant identifier. App Check or device
attestation may reduce abuse but cannot replace authorization.

## Retention and deletion

Retention must be explicit by data class and tier. A viable product policy can
offer a bounded local window and longer NOOP+ history, but local deletion cannot
be introduced merely to force payment. Before such a policy ships it needs:

- an in-app disclosure before enablement;
- export before expiry;
- storage-pressure behavior that never blocks BLE collection;
- server export and account erasure;
- object, database, cache, replica, and backup deletion timelines;
- retained non-biometric tombstones only where replay protection requires them.

The current synthetic raw bucket deletes objects after 30 days. That is a
staging cleanup control, not the final subscriber retention policy.

## Scaling path

Use measured thresholds rather than starting with Kubernetes:

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

Mobile connection remains blocked until all of these pass:

- public identity, recovery, consent, and support-access review;
- immutable chunk upload and processor implementation;
- tenant-isolation and cross-tenant adversarial tests;
- synthetic upload, duplicate, reconnect-burst, export, erasure, and retention
  tests;
- Cloud SQL restore, point-in-time recovery, zone-failure, and secret-rotation
  drills;
- cost/load tests using measured device cadence and chunk sizes;
- privacy/legal review for India and every launch market;
- physical iOS and Android background/foreground catch-up tests.

Infrastructure readiness is not metric-accuracy evidence, medical validation,
or permission to upload a user's data.
