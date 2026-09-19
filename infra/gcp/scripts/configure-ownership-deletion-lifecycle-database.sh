#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_DIR="$(cd "${INFRA_DIR}/../.." && pwd)"

for command in cloud-sql-proxy gcloud tofu; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "${command}" >&2
    exit 1
  fi
done

python="${REPO_DIR}/server/.venv/bin/python"
if [[ ! -x "${python}" ]]; then
  python="$(command -v python3)"
fi
if ! "${python}" -c 'import asyncpg' >/dev/null 2>&1; then
  printf 'Install the pinned server dependencies before provisioning.\n' >&2
  exit 1
fi

project_id="$(tofu -chdir="${INFRA_DIR}" output -raw project_id)"
region="$(tofu -chdir="${INFRA_DIR}" output -raw region)"
instance="$(tofu -chdir="${INFRA_DIR}" output -raw database_instance)"
connection_name="$(
  tofu -chdir="${INFRA_DIR}" output -raw database_connection_name
)"
managed_lifecycle="$(tofu -chdir="${INFRA_DIR}" output -json managed_lifecycle_job)"

if [[ -z "${instance}" || -z "${connection_name}" ]]; then
  printf 'Managed database is disabled; apply that stage first.\n' >&2
  exit 1
fi
if [[ "${managed_lifecycle}" != "null" ]]; then
  printf 'Disable the managed runtime before creating or rotating the ownership lifecycle role.\n' >&2
  exit 1
fi

"${python}" "${SCRIPT_DIR}/configure-ownership-database.py" \
  --role-kind="deletion-lifecycle" \
  --project="${project_id}" \
  --region="${region}" \
  --instance="${instance}" \
  --connection-name="${connection_name}" \
  --database="noop" \
  --user="noop_ownership_lifecycle" \
  --bootstrap-secret="noop-staging-database-url" \
  --secret="noop-staging-ownership-lifecycle-database-url" \
  --proxy-binary="$(command -v cloud-sql-proxy)" \
  --confirm-runtime-disabled
