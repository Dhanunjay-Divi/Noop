#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

for command in gcloud openssl python3 tofu; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "${command}" >&2
    exit 1
  fi
done

project_id="$(tofu -chdir="${INFRA_DIR}" output -raw project_id)"
instance="$(tofu -chdir="${INFRA_DIR}" output -raw database_instance)"
connection_name="$(
  tofu -chdir="${INFRA_DIR}" output -raw database_connection_name
)"
database_secret="noop-staging-database-url"
admin_secret="noop-staging-bootstrap-admin-token"
managed_replay_secret="noop-staging-managed-replay-secret"
feedback_capability_secret="noop-staging-feedback-capability-secret"
feedback_capability_previous_secret="noop-staging-feedback-capability-previous-secret"
managed_push_token_secret="noop-staging-managed-push-token-secret"
managed_push_token_previous_secret="noop-staging-managed-push-token-previous-secret"
database_user="noop_runtime"

if [[ -z "${instance}" || -z "${connection_name}" ]]; then
  printf 'Managed database is disabled; apply that stage first.\n' >&2
  exit 1
fi

has_enabled_version() {
  gcloud secrets versions list "${1}" \
    --project="${project_id}" \
    --format='value(state)' \
    | grep -qx 'ENABLED'
}

if ! has_enabled_version "${database_secret}"; then
  python3 "${SCRIPT_DIR}/configure-database-secret.py" \
    --project="${project_id}" \
    --instance="${instance}" \
    --connection-name="${connection_name}" \
    --database="noop" \
    --user="${database_user}" \
    --secret="${database_secret}"
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

printf 'Runtime secret versions are configured; no secret value was printed.\n'
