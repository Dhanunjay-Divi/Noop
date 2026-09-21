#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

for command in cloud-sql-proxy gcloud openssl python3 tofu; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "${command}" >&2
    exit 1
  fi
done

database_phase="${1:-}"
case "${database_phase}" in
  migration|runtime) ;;
  *)
    printf 'Usage: %s migration|runtime\n' "$0" >&2
    exit 2
    ;;
esac

project_id="$(tofu -chdir="${INFRA_DIR}" output -raw project_id)"
region="$(tofu -chdir="${INFRA_DIR}" output -raw region)"
instance="$(tofu -chdir="${INFRA_DIR}" output -raw database_instance)"
connection_name="$(
  tofu -chdir="${INFRA_DIR}" output -raw database_connection_name
)"
migration_database_secret="noop-staging-database-url"
runtime_database_secret="noop-staging-runtime-database-url"
managed_api_database_secret="noop-staging-managed-api-database-url"
managed_processor_database_secret="noop-staging-managed-processor-database-url"
managed_lifecycle_database_secret="noop-staging-managed-lifecycle-database-url"
feedback_lifecycle_database_secret="noop-staging-feedback-lifecycle-database-url"
admin_secret="noop-staging-bootstrap-admin-token"
managed_replay_secret="noop-staging-managed-replay-secret"
feedback_capability_secret="noop-staging-feedback-capability-secret"
feedback_capability_previous_secret="noop-staging-feedback-capability-previous-secret"
managed_push_token_secret="noop-staging-managed-push-token-secret"
managed_push_token_previous_secret="noop-staging-managed-push-token-previous-secret"
migration_database_user="noop_migration"
runtime_database_user="noop_app_runtime"
managed_api_database_user="noop_managed_api"
managed_processor_database_user="noop_managed_processor"
managed_lifecycle_database_user="noop_managed_lifecycle"
feedback_lifecycle_database_user="noop_feedback_lifecycle"

if [[ -z "${instance}" || -z "${connection_name}" ]]; then
  printf 'Managed database is disabled; apply that stage first.\n' >&2
  exit 1
fi

assert_outputs_disabled() {
  local phase="$1"
  local outputs
  local state_json
  outputs="$(
    if [[ "${phase}" == "migration" ]]; then
      printf '%s\n' \
        migration_job \
        private_api \
        managed_api \
        managed_processor \
        managed_lifecycle_job \
        feedback_lifecycle_job \
        ownership_api
    else
      printf '%s\n' \
        private_api \
        managed_api \
        managed_processor \
        managed_lifecycle_job \
        feedback_lifecycle_job \
        ownership_api
    fi
  )"
  state_json="$(tofu -chdir="${INFRA_DIR}" output -json)"
  NOOP_REQUIRED_NULL_OUTPUTS="${outputs}" \
    python3 -c '
import json
import os
import sys

state = json.load(sys.stdin)
required = os.environ["NOOP_REQUIRED_NULL_OUTPUTS"].splitlines()
missing = [name for name in required if name not in state]
active = [
    name
    for name in required
    if name in state and state[name].get("value") is not None
]
if missing or active:
    raise SystemExit(1)
' <<<"${state_json}"
}

assert_live_workloads_disabled() {
  local live_services
  local live_jobs
  local resource
  live_services="$(
    gcloud run services list \
      --project="${project_id}" \
      --region="${region}" \
      --format='value(metadata.name)'
  )"
  live_jobs="$(
    gcloud run jobs list \
      --project="${project_id}" \
      --region="${region}" \
      --format='value(metadata.name)'
  )"
  for resource in \
    noop-staging-api \
    noop-staging-managed-api \
    noop-staging-managed-processor \
    noop-staging-ownership-api
  do
    if grep -Fxq "${resource}" <<<"${live_services}"; then
      printf 'Live Cloud Run service must be removed before database credential provisioning: %s\n' \
        "${resource}" >&2
      return 1
    fi
  done
  for resource in \
    noop-staging-migrate \
    noop-staging-managed-lifecycle \
    noop-staging-feedback-lifecycle
  do
    if grep -Fxq "${resource}" <<<"${live_jobs}"; then
      printf 'Live Cloud Run job must be removed before database credential provisioning: %s\n' \
        "${resource}" >&2
      return 1
    fi
  done
}

if ! assert_outputs_disabled "${database_phase}"; then
  printf '%s database provisioning requires the applicable migration, API, processor, lifecycle, feedback, and ownership workloads to be disabled in the applied state.\n' \
    "${database_phase}" >&2
  exit 1
fi
assert_live_workloads_disabled

has_enabled_version() {
  gcloud secrets versions list "${1}" \
    --project="${project_id}" \
    --format='value(state)' \
    | grep -qx 'ENABLED'
}

if [[ "${database_phase}" == "migration" ]]; then
  python3 "${SCRIPT_DIR}/configure-database-secret.py" \
    --role-kind="migration" \
    --project="${project_id}" \
    --region="${region}" \
    --instance="${instance}" \
    --connection-name="${connection_name}" \
    --database="noop" \
    --user="${migration_database_user}" \
    --secret="${migration_database_secret}" \
    --confirm-runtime-disabled
else
  for runtime_profile in \
    private-api \
    managed-api \
    managed-processor \
    managed-lifecycle \
    feedback-lifecycle
  do
    case "${runtime_profile}" in
      private-api)
        database_user="${runtime_database_user}"
        database_secret="${runtime_database_secret}"
        ;;
      managed-api)
        database_user="${managed_api_database_user}"
        database_secret="${managed_api_database_secret}"
        ;;
      managed-processor)
        database_user="${managed_processor_database_user}"
        database_secret="${managed_processor_database_secret}"
        ;;
      managed-lifecycle)
        database_user="${managed_lifecycle_database_user}"
        database_secret="${managed_lifecycle_database_secret}"
        ;;
      feedback-lifecycle)
        database_user="${feedback_lifecycle_database_user}"
        database_secret="${feedback_lifecycle_database_secret}"
        ;;
    esac
    python3 "${SCRIPT_DIR}/configure-database-secret.py" \
      --role-kind="runtime" \
      --runtime-profile="${runtime_profile}" \
      --project="${project_id}" \
      --region="${region}" \
      --instance="${instance}" \
      --connection-name="${connection_name}" \
      --database="noop" \
      --migration-user="${migration_database_user}" \
      --bootstrap-secret="${migration_database_secret}" \
      --user="${database_user}" \
      --secret="${database_secret}" \
      --confirm-runtime-disabled \
      --confirm-migrations-complete
  done
fi

if ! has_enabled_version "${admin_secret}"; then
  admin_token="$(openssl rand -hex 32)"
  printf '%s' "${admin_token}" | gcloud secrets versions add "${admin_secret}" \
    --project="${project_id}" \
    --data-file=-
  unset admin_token
fi

if ! has_enabled_version "${managed_replay_secret}"; then
  replay_secret="$(openssl rand -hex 32)"
  printf '%s' "${replay_secret}" | gcloud secrets versions add "${managed_replay_secret}" \
    --project="${project_id}" \
    --data-file=-
  unset replay_secret
fi

if ! has_enabled_version "${feedback_capability_secret}"; then
  capability_secret="$(openssl rand -hex 32)"
  printf '%s' "${capability_secret}" | gcloud secrets versions add \
    "${feedback_capability_secret}" \
    --project="${project_id}" \
    --data-file=-
  unset capability_secret
fi

if ! has_enabled_version "${feedback_capability_previous_secret}"; then
  # Inactive bootstrap key. Rotation is intentionally staged:
  # 1. Pin both key versions and deploy every instance while still writing the
  #    old or legacy format.
  # 2. Change only the explicit write version after the first rollout settles.
  # 3. Retain the prior verification key for the full maximum report retention
  #    period after the last capability issued with it, plus rollout overlap.
  # Never use Secret Manager "latest" for either runtime key reference.
  previous_capability_secret="$(openssl rand -hex 32)"
  printf '%s' "${previous_capability_secret}" | gcloud secrets versions add \
    "${feedback_capability_previous_secret}" \
    --project="${project_id}" \
    --data-file=-
  unset previous_capability_secret
fi

if ! has_enabled_version "${managed_push_token_secret}"; then
  push_token_secret="$(openssl rand -hex 32)"
  printf '%s' "${push_token_secret}" | gcloud secrets versions add \
    "${managed_push_token_secret}" \
    --project="${project_id}" \
    --data-file=-
  unset push_token_secret
fi

if ! has_enabled_version "${managed_push_token_previous_secret}"; then
  # This is an inactive bootstrap key. A zero-downtime rotation is two-phase:
  # first place the next key here and fully deploy; then swap current=next and
  # previous=old before the second deployment. Both revisions can then read
  # envelopes written by the other while old rows are resealed.
  previous_push_token_secret="$(openssl rand -hex 32)"
  printf '%s' "${previous_push_token_secret}" | gcloud secrets versions add \
    "${managed_push_token_previous_secret}" \
    --project="${project_id}" \
    --data-file=-
  unset previous_push_token_secret
fi

printf '%s database and shared runtime secret versions are configured; no secret value was printed.\n' \
  "${database_phase}"
