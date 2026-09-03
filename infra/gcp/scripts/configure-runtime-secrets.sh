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

printf 'Runtime secret versions are configured; no secret value was printed.\n'
