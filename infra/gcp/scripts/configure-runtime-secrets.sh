#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

for command in gcloud openssl tofu; do
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
  [[ -n "$(
    gcloud secrets versions list "${1}" \
      --project="${project_id}" \
      --filter='state=ENABLED' \
      --limit=1 \
      --format='value(name)'
  )" ]]
}

if ! has_enabled_version "${database_secret}"; then
  database_password="$(openssl rand -hex 32)"
  existing_user="$(
    gcloud sql users list \
      --project="${project_id}" \
      --instance="${instance}" \
      --filter="name=${database_user}" \
      --format='value(name)' \
      --limit=1
  )"
  if [[ -n "${existing_user}" ]]; then
    gcloud sql users set-password "${database_user}" \
      --project="${project_id}" \
      --instance="${instance}" \
      --password="${database_password}" \
      --quiet
  else
    gcloud sql users create "${database_user}" \
      --project="${project_id}" \
      --instance="${instance}" \
      --password="${database_password}" \
      --quiet
  fi

  database_url="postgresql://${database_user}:${database_password}@/noop?host=%2Fcloudsql%2F${connection_name}"
  printf '%s' "${database_url}" | gcloud secrets versions add "${database_secret}" \
    --project="${project_id}" \
    --data-file=-
  unset database_password database_url
fi

if ! has_enabled_version "${admin_secret}"; then
  admin_token="$(openssl rand -hex 32)"
  printf '%s' "${admin_token}" | gcloud secrets versions add "${admin_secret}" \
    --project="${project_id}" \
    --data-file=-
  unset admin_token
fi

printf 'Runtime secret versions are configured; no secret value was printed.\n'
