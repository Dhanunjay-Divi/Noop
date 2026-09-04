# NOOP GCP staging

This directory manages the synthetic-only Google Cloud staging foundation for
the optional NOOP+ service. It does not change NOOP's local-first default, does
not enable mobile upload, and must not receive real health data until the
identity, privacy, isolation, restore, and physical-device gates are complete.

## What the default foundation creates

- required project APIs;
- a regional Artifact Registry Docker repository;
- a regional Cloud KMS key and encrypted raw-chunk bucket;
- a seven-day build-source/log bucket scoped to the build identity;
- a Pub/Sub raw-object topic and pull subscription;
- separate build, API, processor, and migration service accounts;
- empty regional Secret Manager containers;
- an empty regional BigQuery staging dataset.

The guarded variables default to no Cloud SQL, Firebase, or Cloud Run. Separate
flags can add:

- a CMEK PostgreSQL 16 Cloud SQL instance and migration job;
- Firebase phone identity, iOS/Android app registration, App Attest, Play
  Integrity, and enforced Authentication App Check;
- an IAM-only managed API plus processor, lifecycle, scheduler, and Pub/Sub push;
- a public Cloud Run invoker grant only through the final
  `enable_public_managed_api` gate.

The stack never writes secret versions, DNS, generated mobile configuration, or
real health data. Public Cloud Run invocation does not bypass Firebase identity,
App Check, per-installation credentials, or tenant authorization.

## Prerequisites

Use a dedicated staging project with billing enabled. The operator needs
project Owner during bootstrap and Billing Administrator only for the separate
budget setup. Reduce those broad permissions after service accounts and an
administrative recovery path exist.

Before enabling Firebase resources, sign in to
`https://console.firebase.google.com/` with the same account used by OpenTofu
and accept the Firebase terms. Google otherwise returns a generic 403 to the
provider even when `firebase.projects.update` is granted; Cloud Audit Logs
records the actual `Firebase Tos Not Accepted` reason.

```sh
gcloud auth login --update-adc
gcloud config set project YOUR_STAGING_PROJECT_ID
gcloud auth application-default set-quota-project YOUR_STAGING_PROJECT_ID
```

The default region is Mumbai (`asia-south1`). Region is a data-residency and
latency decision, not a billing-entity decision. Changing it after buckets and
keys exist requires a migration.

## Bootstrap remote state

The state bucket is intentionally bootstrapped outside its own state. It has
uniform access, public-access prevention, and object versioning.

```sh
./scripts/bootstrap-state.sh YOUR_STAGING_PROJECT_ID asia-south1
```

Create the ignored local backend file from the command's output:

```hcl
bucket = "YOUR_STAGING_PROJECT_ID-noop-tofu-state"
prefix = "noop/staging"
```

Save that as `backend.hcl` in this directory. Never commit state or backend
account details.

## Plan and apply

Create an ignored `staging.auto.tfvars` from
`staging.tfvars.example`, replacing only the project value. Review the plan
before apply:

```sh
tofu init -backend-config=backend.hcl
tofu fmt -check -recursive
tofu validate
tofu plan -out=foundation.tfplan
tofu apply foundation.tfplan
```

OpenTofu creates secret **containers**, not secret values. Add future values
through the guarded script below. Do not place a
password, API token, service-account key, or health payload in a `.tfvars`
file; plan files and state can preserve input values.

## Guarded deployment sequence

Do not combine these stages. Regenerate a plan after every source or variable
change. Each successful step is evidence required by the next:

1. Run the server suite and the standard-PostgreSQL integration matrix.
2. Set `enable_managed_identity = true` and
   `enable_managed_app_check = true`, keep managed runtime/public ingress off,
   configure `managed_test_phone_numbers` with only an untracked Firebase
   synthetic number/code, review a zero-destroy plan, and apply. Test codes are
   staging credentials: keep the local tfvars mode `0600` and never commit,
   log, or use a real person's number.
3. Generate ignored iOS/Android Firebase configuration from OpenTofu outputs and
   register only reviewed debug App Check tokens for synthetic testing. Never
   commit generated configuration or tokens.
4. Run Cloud SQL tests through the connector/proxy against a disposable
   database.
5. Commit the reviewed source. The image script refuses a dirty worktree.
6. Build once and record the immutable digest:

   ```sh
   ./scripts/build-runtime-image.sh
   ```

7. Run the metered on-demand scan against that exact digest. Do not deploy an
   image with an effective Critical or High finding:

   ```sh
   ./scripts/scan-runtime-image.sh "DIGEST_URI_FROM_STEP_3"
   ```

8. Set `enable_managed_database = true` in the ignored
   `staging.auto.tfvars`, leave `runtime_image = null` and
   all runtime flags false, then review and apply. Cloud SQL has deletion
   protection, CMEK, encrypted connections, daily backups, and seven-day PITR.
9. Create the runtime database user and first secret versions without putting
   either value in OpenTofu state:

   ```sh
   ./scripts/configure-runtime-secrets.sh
   ```

10. Put the verified digest URI from step 6 in `runtime_image`, review, and
    apply. This creates the migration job but not the managed runtime.
11. Execute migrations through the matching digest exactly once:

   ```sh
   ./scripts/run-migration.sh
   ```

12. Set `enable_managed_runtime = true`, keep
    `enable_public_managed_api = false`, review, and apply. This creates the
    IAM-only managed API, processor, lifecycle, scheduler, and authenticated
    Pub/Sub push. Runtime migrations and Safety delivery remain disabled.
13. Invoke the IAM-only services with synthetic credentials and run upload,
    duplicate, reconnect, restore, tenant-isolation, retention, export, and
    erasure tests.
14. Verify the live controls and a zero-drift plan:

   ```sh
   ./scripts/verify-private-runtime.sh
   tofu plan -detailed-exitcode
   ```

15. `enable_public_managed_api` remains false until signed physical clients,
    privacy/legal, abuse, security, recovery, load, and support gates pass.

The database has a public IP only as a Cloud SQL connector endpoint. It has no
authorized source networks, requires encrypted transport, and Cloud Run access
also requires `roles/cloudsql.client` plus the database credential. Production
private networking remains a later measured topology decision.

## Cost boundary

These foundation resources are near-idle when empty, but they are not described
as free. Storage, KMS operations, Pub/Sub retention, image storage, automatic
and on-demand vulnerability scanning, BigQuery queries, and build minutes can
incur charges. The staging billing budget is a notification guardrail, not an
automatic spending cap.

Cloud SQL is the first material always-on cost. `db-f1-micro` is a synthetic
staging choice, not a production sizing claim. The USD 50 budget sends alerts
but does not stop resources automatically.

## Runtime gates

Before a public mobile client can connect:

1. Deploy and prove phone identity, App Check, reauthentication, recovery,
   revocation, deletion, and support-access contracts.
2. Prove immutable compressed raw chunks in Cloud Storage and bounded
   metadata/aggregates in PostgreSQL.
3. Pass synthetic upload, idempotency, aggregation, export, erasure, restore,
   tenant-isolation, reconnect-burst, soak, and failover tests.
4. Restore Cloud SQL from PITR and prove generation-bound object recovery.
5. Measure compressed bytes/user-day, processor cost, pool pressure, and
   reconnect peaks before sizing.
6. Complete privacy/legal review and only then run explicit-opt-in physical
   iOS and Android staging tests.

No production capacity or reliability claim follows from a successful
foundation apply.
