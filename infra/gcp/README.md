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

The guarded variables default to no Cloud SQL and no Cloud Run. Enabling them
can add a CMEK PostgreSQL 16 Cloud SQL instance, a one-shot Cloud Run migration
job, and an internal-ingress private API. The stack never creates public
ingress, broad invoker grants, Identity Platform providers, secret versions,
DNS, or client configuration.

## Prerequisites

Use a dedicated staging project with billing enabled. The operator needs
project Owner during bootstrap and Billing Administrator only for the separate
budget setup. Reduce those broad permissions after service accounts and an
administrative recovery path exist.

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

## Guarded runtime sequence

Do not combine these stages. Each successful step is evidence required by the
next:

1. Run the server suite and the standard-PostgreSQL integration matrix.
2. Commit the reviewed source. The image script refuses a dirty worktree.
3. Build once and record the immutable digest:

   ```sh
   ./scripts/build-runtime-image.sh
   ```

4. Set `enable_managed_database = true` in the ignored
   `staging.auto.tfvars`, leave `runtime_image = null` and
   `enable_private_api = false`, then review and apply. Cloud SQL has deletion
   protection, CMEK, encrypted connections, daily backups, and seven-day PITR.
5. Create the runtime database user and first secret versions without putting
   either value in OpenTofu state:

   ```sh
   ./scripts/configure-runtime-secrets.sh
   ```

6. Put the digest URI from step 3 in `runtime_image`, review, and apply. This
   creates the migration job but not the API.
7. Execute the matching migration exactly once:

   ```sh
   ./scripts/run-migration.sh
   ```

8. Set `enable_private_api = true`, review, and apply. The service has
   internal-only ingress, no public invoker, scale-to-zero, runtime migrations
   disabled, Safety delivery disabled, and a `/readyz` startup probe.
9. Verify the live controls:

   ```sh
   ./scripts/verify-private-runtime.sh
   tofu plan -detailed-exitcode
   ```

The database has a public IP only as a Cloud SQL connector endpoint. It has no
authorized source networks, requires encrypted transport, and Cloud Run access
also requires `roles/cloudsql.client` plus the database credential. Production
private networking remains a later measured topology decision.

## Cost boundary

These foundation resources are near-idle when empty, but they are not described
as free. Storage, KMS operations, Pub/Sub retention, image storage, BigQuery
queries, and build minutes can incur charges. The staging billing budget is a
notification guardrail, not an automatic spending cap.

Cloud SQL is the first material always-on cost. `db-f1-micro` is a synthetic
staging choice, not a production sizing claim. The USD 50 budget sends alerts
but does not stop resources automatically.

## Runtime gates

Before a mobile client can connect:

1. Support standard PostgreSQL without pretending it is TimescaleDB.
2. Store immutable compressed raw chunks in Cloud Storage and only indexed
   metadata/aggregates in PostgreSQL.
3. Select Identity Platform enrollment, recovery, deletion, and support-access
   contracts.
4. Deploy and validate the processor revision; only the migration job and
   private API are defined today.
5. Pass synthetic upload, idempotency, aggregation, export, erasure, restore,
   tenant-isolation, reconnect-burst, soak, and failover tests.
6. Complete privacy/legal review and only then run explicit-opt-in physical
   iOS and Android staging tests.

No production capacity or reliability claim follows from a successful
foundation apply.
