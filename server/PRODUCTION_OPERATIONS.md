# Production operations and 10,000-user capacity gate

This document is the deployment contract for the self-hosted server and Safety
paging worker. It is not evidence that a deployment can serve 10,000 users.
Capacity is established only after the load, failover, restore, and real-carrier
gates below pass against the intended production topology.

## Shared tenancy boundary and remaining identity gate

`NOOP_AUTH_MODE` now makes the deployment posture explicit:

- `single_owner` keeps backward compatibility for one trusted self-hosted
  installation. The administrator token can use biometric routes.
- `NOOP_AUTH_MODE=shared` keeps the administrator token administrative. Biometric sync,
  reads, exports, and deletion require a versioned per-installation
  `noop_install_...` installation credential. Device ownership is exclusive and its native
  identifier must contain the exact installation namespace. Cross-tenant reads
  return `404`, and installation erasure covers biometric, Friends, Safety, and
  credential rows.

This is an application authorization and storage-ownership boundary, not a
complete consumer identity product. Installation enrollment is still an
administrator action. There is no public signup, account recovery, verified
email/phone identity, lost-device credential recovery, support-access workflow,
external penetration-test evidence, or managed per-tenant key hierarchy.
Application checks also remain the primary isolation control rather than
database row-level security.

A private or pre-provisioned shared deployment can test this mode now. A public
NOOP-operated launch for 10,000 unrelated consumers remains blocked until the
identity/enrollment/recovery flow, abuse controls, support and audit policy,
privacy/compliance review, independent isolation assessment, and breach
response process are selected and validated. The operator credential must never
be distributed to clients.

## Reference production topology

For a single trusted deployment or after the multi-tenant work above:

- A managed Layer 7 load balancer or API gateway terminates TLS and applies the
  authoritative distributed rate limit.
- Run at least three stateless API replicas across two or more failure zones.
- Run at least two independently scalable `python -m app.safety_worker`
  processes across failure zones.
- Give each worker a termination grace period longer than the provider request
  timeout plus database completion headroom. The included Compose reference
  defaults to 45 seconds and drains the active submission wave on `SIGTERM`.
- Run `python -m app.migrate` as one pre-deploy job using a direct database
  connection. Runtime API and worker processes set `NOOP_RUN_MIGRATIONS=false`.
- Use managed PostgreSQL/TimescaleDB with multi-zone failover, point-in-time
  recovery, encryption at rest, and tested storage/connection alarms.
- Put PgBouncer between runtime processes and PostgreSQL when connection count
  requires it. For transaction pooling set
  `NOOP_DB_STATEMENT_CACHE_SIZE=0`. The migration job must bypass transaction
  pooling because migration coordination uses a session advisory lock.
- Keep database, Twilio credentials, API tokens, callback secret, responder
  signing secret, and backup key in a managed secret store. Rotate them through
  a rehearsed procedure, not by editing a running container.
- Send encrypted backups to a separate account/region with object versioning
  and retention lock. A volume on the database host is only a staging copy.

The included Compose stack now separates `migrate`, `api`, and
`safety-worker`. It is a secure single-host reference, not a high-availability
orchestrator.

### GCP synthetic staging

The checked-in `infra/gcp/` stack is the selected India-first staging path. It
uses Mumbai, OpenTofu remote state, a regional Artifact Registry, regional KMS,
Secret Manager containers, a CMEK raw-object bucket, Pub/Sub, and separate
build/API/processor/migration identities. Its optional runtime is deliberately
gated:

1. Standard PostgreSQL integration tests must pass.
2. Provision the deletion-protected PostgreSQL 16 Cloud SQL instance.
3. Create database credentials and secret versions outside OpenTofu state.
4. Build from a clean commit and select the immutable image digest.
5. Execute the one-shot Cloud Run migration job.
6. Only then enable the internal-ingress, IAM-protected API. Its startup probe
   calls `/readyz`, runtime migration is disabled, minimum instances are zero,
   and no broad invoker binding is created.

This is synthetic staging, not the production topology above. The shared-core
database is single-zone, the API has no public ingress, the Safety worker is
disabled, and the mobile clients are disconnected. See
`../docs/CLOUD_ARCHITECTURE.md` and `../infra/gcp/README.md`.

### Database roles

The Compose defaults retain one `noop` database owner for local operation.
Production must set `NOOP_MIGRATION_DATABASE_URL`, `NOOP_API_DATABASE_URL`, and
`NOOP_SAFETY_WORKER_DATABASE_URL` to distinct managed-secret values:

- the migration role owns the schema and is used only by the pre-deploy job;
- the API role has required DML rights but no DDL or role administration;
- the Safety worker role reads the migration manifest, profiles, contacts,
  incidents, and controls, and modifies only Safety delivery state;
- the backup role is read-only and has no restore, database-create, or
  role-create rights.

Grant `CONNECT` on the database and `USAGE` on `public` explicitly. Grant
sequence usage only where inserts need it, revoke default `PUBLIC` schema-create
rights, and keep restore credentials separate and offline. Verify exact grants
in staging by running API, worker, migration, backup, and restore checks under
their production roles. Code cannot prove cloud IAM or managed-database grants.

### Deployment ordering

Runtime processes refuse a database whose immutable migration manifest differs
from the image. Drain old Safety workers before the migration job so an older
worker cannot bypass a newly introduced runtime control. Apply migrations once,
deploy matching workers, then deploy matching API replicas and wait for
`/readyz` plus a fresh worker heartbeat. This strict contract favors a short
maintenance window over unsafe mixed-version paging. A future zero-downtime
rollout requires an explicitly backward-compatible expand/contract migration,
not bypassing readiness.

## Capacity model and acceptance gate

Use an explicit workload rather than the phrase "10k users":

- 10,000 enrolled users.
- 10 percent active concurrently.
- One sync per active device every five minutes: about 33 writes/second.
- A three-times reconnect/background burst: test at 100 writes/second.
- Read traffic at the measured client ratio, not an invented ratio.
- Paging tested separately because carrier throughput, not API CPU, is usually
  the limiting resource.

`load/k6-sync.js` remains the isolated sync-write benchmark. In `single_owner`
mode it can use `NOOP_LOAD_API_TOKEN`; in `shared` mode it reads a private JSON
credential file generated against a disposable target. It does not establish
consumer identity, read capacity, paging throughput, or mixed-workload
capacity.

`load/k6-mixed-adversarial.js` adds a production-shaped route mix and a parallel
shared-tenancy attack scenario. The mixed scenario performs sync, owned-device
list, installation, latest, range, daily, and bounded-export operations. The
adversarial scenario repeatedly attempts a foreign latest read, export, delete,
and forged-namespace sync. Its `isolation_violations` threshold is exactly zero.
The harness still does not test account enrollment/recovery, carrier paging, or
mobile background delivery.

Provision 10,000 disposable shared-mode installation rows, then use at least one
credential per maximum concurrent VU:

```sh
NOOP_LOAD_ALLOW_ENROLLMENT=I_UNDERSTAND_THIS_CREATES_DISPOSABLE_CREDENTIALS \
python load/provision-shared.py \
  --base-url https://load.noop.example \
  --admin-token "$LOAD_ADMIN_TOKEN" \
  --count 10000 \
  --output /secure/tmp/noop-load-installations.json
```

The script defaults to 60 HR rows per sync instead of a one-row toy payload.
Before running it, raise both application and edge limits on the disposable
target above the requested aggregate rate. At 100 requests/second, each must
allow more than 6,000 requests/minute plus headroom. Never weaken production
limits for a test.

Run the write-path test for at least 15 minutes against a disposable
production-like database, then run a 60-minute soak and a failover test:

```sh
NOOP_LOAD_BASE_URL=https://load.noop.example \
NOOP_LOAD_CREDENTIALS_FILE=/secure/tmp/noop-load-installations.json \
NOOP_LOAD_ALLOW_WRITES=I_UNDERSTAND_THIS_IS_DESTRUCTIVE \
NOOP_LOAD_RATE_LIMITS_RAISED=I_CONFIGURED_TEST_LIMITS \
NOOP_LOAD_RPS=100 \
NOOP_LOAD_SAMPLES_PER_SYNC=60 \
NOOP_LOAD_DURATION=15m \
k6 run load/k6-sync.js
```

Run the mixed and isolation gate only against a disposable shared-mode target.
A delete probe would destroy the victim canary if an isolation defect exists:

```sh
NOOP_LOAD_BASE_URL=https://load.noop.example \
NOOP_LOAD_CREDENTIALS_FILE=/secure/tmp/noop-load-installations.json \
NOOP_LOAD_TARGET_IS_DISPOSABLE=I_CONFIRMED_THIS_TARGET_IS_DISPOSABLE \
NOOP_LOAD_ALLOW_WRITES=I_UNDERSTAND_THIS_IS_DESTRUCTIVE \
NOOP_LOAD_ALLOW_ADVERSARIAL=I_UNDERSTAND_CROSS_TENANT_DELETE_PROBES_CAN_DESTROY_A_BROKEN_TARGET \
NOOP_LOAD_RATE_LIMITS_RAISED=I_CONFIGURED_TEST_LIMITS \
NOOP_LOAD_MIN_CREDENTIALS=1000 \
NOOP_LOAD_MIXED_ITERATIONS_PER_SECOND=100 \
NOOP_LOAD_ADVERSARIAL_ITERATIONS_PER_SECOND=5 \
NOOP_LOAD_DURATION=15m \
k6 run load/k6-mixed-adversarial.js
```

Rates in this command are iterations per second, not HTTP requests per second;
each adversarial iteration makes four requests. Use at least one credential per
maximum concurrent VU for release evidence. The script refuses a non-HTTPS
target except loopback, fewer than two unique shared credentials, missing
acknowledgements, failed readiness, or a non-installation auth scope.

Both harnesses gate at less than 0.1 percent request/contract failures, p95 below
500 ms, p99 below 1 second, and zero dropped iterations. The mixed harness also
requires zero accepted cross-tenant operations. Those are initial test
thresholds, not a capacity claim. Before making a 10,000-user claim, run the
15-minute, 60-minute soak, rolling restart, and database-failover matrix against
the intended deployed topology, using a traffic ratio measured from clients and
including realistic reconnect backfills and sleep/workout bodies. Also require:

- no database connection exhaustion, lock pile-up, replica lag, or storage
  saturation;
- queue age below 5 seconds when the provider is healthy;
- zero stale paging leases;
- no duplicate incident caused by client retries;
- zero accepted cross-installation read, export, delete, or forged-namespace
  requests during a parallel adversarial isolation run;
- API and worker rolling restart without a lost job;
- database primary failover with bounded recovery and no manual data repair;
- a successful restore drill from the resulting backup.

Do not run either write harness against production. Preserve the k6 summary,
exact command/environment minus secrets, deployment revision, database class,
replica counts, pool sizes, and graphs as release evidence. No run has been
performed or measured by this repository, so it makes no 10,000-user capacity
claim.

## Paging throughput and carrier gate

Worker concurrency is bounded by:

- `NOOP_SAFETY_WORKER_BATCH_SIZE` (default 20);
- `NOOP_SAFETY_WORKER_MAX_CONCURRENCY` (default 6 and smaller than the worker
  database pool);
- the number of worker replicas.

`NOOP_SAFETY_PROVIDER_MAX_REQUESTS_PER_SECOND` reserves sender slots in
PostgreSQL, so all worker replicas share one submission rate. Incident pages
are claimed before invitations. This protects the configured sender rate; it
does not increase Twilio message throughput or voice concurrency. Obtain a
Twilio throughput plan for the launch countries, complete US A2P 10DLC or the
applicable sender registration, configure geographic permissions, and size
sender pools without evading carrier policy.

Before enabling paging:

1. Use controlled numbers on at least two carriers in every launch country.
2. Exercise invitation, acceptance, SMS, voice fallback, DTMF, responder link,
   cancellation, expiry, explicit provider rejection/retry, ambiguous timeout
   or 5xx handling, callback delay, and worker restart.
3. Capture provider SIDs and timestamps. Publish median and p95 time to carrier
   delivery, plus unknown and failed receipt rates.
4. Test blocked sender, phone off, roaming, Focus/DND, changed number, and
   revoked consent.
5. Define staffed ownership for a provider outage and a carrier filtering event.

The app now reports a deduplicated contact count backed by either an actual
response or provider-confirmed delivery, not SMS/voice row counts or a claim
that a carrier receipt proves human receipt. If every channel explicitly fails
for every contact, the incident becomes terminal `failed` and the client must
direct the owner to call local emergency services. An `unknown` provider receipt
remains unknown and must never be described as a confirmed failure or confirmed
delivery.

## Paging kill switch

The database-backed switch blocks new invitations and incidents, stops queue
claims, and releases a job leased just before the switch without spending a
retry. Provider callbacks and responder links remain active so existing state
can settle. Each write requires the revision returned by the preceding read;
stale writes receive HTTP 409, and accepted changes are appended to
`safety_runtime_control_audit` with the required `X-Noop-Operator` identity and
a server-generated request ID. Migration 009 disables an untouched
revision-one control, so a new production database starts fail-closed.

Inspect:

```sh
curl -fsS \
  -H "Authorization: Bearer $NOOP_API_TOKEN" \
  https://noop.example.com/v1/safety/operations/paging-control
```

Disable:

```sh
# Replace 7 with the revision returned by the inspect call.
curl -fsS -X PUT \
  -H "Authorization: Bearer $NOOP_API_TOKEN" \
  -H "X-Noop-Operator: oncall@example.com" \
  -H "Content-Type: application/json" \
  --data '{"enabled":false,"reason":"Twilio carrier incident INC-123","expected_revision":7}' \
  https://noop.example.com/v1/safety/operations/paging-control
```

Re-enable only after a controlled end-to-end page succeeds:

```sh
# Fetch the control again and replace 8 with its current revision.
curl -fsS -X PUT \
  -H "Authorization: Bearer $NOOP_API_TOKEN" \
  -H "X-Noop-Operator: oncall@example.com" \
  -H "Content-Type: application/json" \
  --data '{"enabled":true,"reason":"INC-123 recovery verified","expected_revision":8}' \
  https://noop.example.com/v1/safety/operations/paging-control
```

A disable takes the exclusive control lock and does not return until
database-backed permits for already-started provider calls drain. The switch
cannot recall a request already accepted by the provider.

## Required alerts

Scrape the authenticated `/v1/safety/operations` response without logging
credentials or response bodies containing future sensitive fields. Page the
operator on:

| Signal | Initial threshold |
| --- | --- |
| Active workers | `0` for 30 seconds while paging is enabled |
| Oldest due job | over 5 seconds for 2 minutes |
| Stale leases | any |
| Explicit delivery failures | any burst, or rate above the tested baseline |
| Unknown receipts | any sustained increase or over 1 percent |
| Provider delivery p95 | above the country/carrier release SLO |
| Open overdue incidents | any |
| Database readiness | two consecutive failures |
| Backup age | interval plus one hour |
| Restore drill | missed monthly drill or any failed drill |

Also collect API request count/latency/status by route, database pool wait time,
query latency, deadlocks, CPU, memory, disk, WAL/replica lag, worker restarts,
Twilio API latency/status, and callback lag. Metrics and logs must exclude phone
numbers, names, responder URLs, tokens, Authorization headers, and provider
payload bodies. The included container disables raw Uvicorn access logs because
responder and callback capabilities are query parameters. Any proxy or gateway
must apply equivalent query-string redaction.

## Distributed edge controls

The in-process limiter is a bounded defense for one process. A multi-replica
deployment requires a shared limit in the trusted API gateway/WAF. Apply:

- a strict budget for repeated 401/403 responses by validated client address;
- per-credential and per-route budgets after authentication;
- tighter limits on enrollment, contact invitation, and incident creation;
- request-body limits at the edge and in the application;
- bot/DDoS protection that cannot bypass the Safety responder callbacks.

Twilio callbacks use a separate high pre-auth origin budget and a bounded
post-signature application budget. Configure an equivalent provider-aware edge
policy that permits legitimate callback bursts while bounding invalid traffic.
Do not place callbacks inside the ordinary app credential budget.

Trust forwarding headers only from the load balancer's exact addresses. Do not
log raw bearer credentials to implement a rate-limit key.

The container passes `NOOP_FORWARDED_ALLOW_IPS` to Uvicorn and startup rejects
`*`, `0.0.0.0/0`, `::/0`, malformed entries, and empty entries. Set it to the
exact API-gateway/load-balancer source IPs or narrow CIDRs. The trusted proxy
must overwrite inbound forwarding headers. If this remains at `127.0.0.1`
behind a remote load balancer, Uvicorn leaves the ASGI client as the load
balancer and every user shares one origin-rate budget. Do not fix that by
trusting arbitrary forwarded headers.

## Push delivery posture

Ordinary signed App Store and Play Store builds cannot safely use arbitrary
user-self-hosted APNs/FCM delivery. APNs credentials and app entitlements belong
to NOOP's signed bundle, and FCM sender credentials belong to NOOP's project.
Giving those provider credentials to users or accepting them in an untrusted
server would expose a product-wide send capability.

The practical product decision is:

- remain local-only, accepting the documented background scheduling ceiling; or
- offer an optional privacy-minimized NOOP-operated relay with explicit consent,
  short retention, per-device revocation, abuse controls, and deletion. The
  relay should receive only a push token, platform, opaque nudge type, expiry,
  and random idempotency identifier, never biometric values, contact data, or
  responder capabilities.

User-operated push is viable only for independently signed iOS builds using the
operator's own APNs entitlement/credentials, or expert Android alternatives
using a separately controlled application/project. It is not the architecture
for ordinary NOOP store builds. Safety contact paging remains the durable
SMS/voice pipeline and must not depend on best-effort mobile push.

## Backups and disaster recovery

For production, require managed point-in-time recovery plus encrypted logical
backups copied off-host. Run the repository restore drill monthly and after
PostgreSQL, TimescaleDB, schema, or backup-image changes. Record recovery point
objective, recovery time objective, archive name, elapsed time, restored row
counts, and application smoke-test result.

Exercise complete zone loss and secret loss scenarios. A backup without a
separately recoverable encryption key is not recoverable.

## Inputs the operator must choose

Infrastructure cannot be provisioned safely until the owner records:

- self-hosted installations or one shared multi-tenant service;
- identity provider, enrollment proof, account recovery, and support-access
  policy for a shared service;
- cloud provider, primary and recovery regions, domain, and launch countries;
- RPO, RTO, retention/deletion policy, and expected per-user sync frequency;
- Twilio account, sender type, country permissions, and expected incident burst;
- monitoring, paging/on-call vendor, staffed escalation owner, and error budget;
- APNs/FCM posture: local-only or an optional privacy-minimized NOOP relay for
  store builds; independently signed/expert builds may operate their own push;
- monthly infrastructure and carrier budget.

For synthetic India staging, GCP and Mumbai are selected and a USD 50 monthly
budget alert exists. A budget alert is not a hard spending cap. Production
region redundancy, RPO/RTO, identity/recovery, on-call, legal posture, and a
measured workload budget remain open.

## Remaining external launch gates

Code cannot complete these items:

- DNS, certificates, cloud account/region, container registry and deployment
  pipeline, WAF, managed database, secret store, monitoring vendor, on-call
  routing, and cost budget;
- shared-service identity/enrollment/recovery, managed key and support-access
  posture, abuse prevention, independent isolation evidence, and incident
  response if 10,000 unrelated users share one service;
- Twilio production account, sender registration, country permissions,
  controlled carrier numbers, and measured delivery evidence;
- Apple/Google push credentials and the product decision between local-only and
  an optional privacy-minimized NOOP relay for ordinary store builds;
- physical-device BLE/background/haptic/battery evidence;
- validated activity incident detector evidence (Fall Response stays inert);
- source-distribution rights, store signing, privacy disclosures, and regional
  legal/safety review.

No production launch should convert an unavailable medical or fall detector
into marketing copy. App SOS and repeated band gestures are explicit user
actions. The possible-fall request model remains hard-disabled because detector
attestation is absent; preparatory configuration cannot activate it. Wellness
and biometric estimates never page contacts, and NOOP does not contact
emergency services.
