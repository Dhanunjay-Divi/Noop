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
ownership_runtime="$(tofu -chdir="${INFRA_DIR}" output -json ownership_api)"

if [[ -z "${instance}" || -z "${connection_name}" ]]; then
  printf 'Managed database is disabled; apply that stage first.\n' >&2
  exit 1
fi
if [[ "${ownership_runtime}" != "null" ]]; then
  printf 'Disable the ownership runtime before creating or rotating its database role.\n' >&2
  exit 1
fi

"${python}" "${SCRIPT_DIR}/configure-ownership-database.py" \
  --project="${project_id}" \
  --region="${region}" \
  --instance="${instance}" \
  --connection-name="${connection_name}" \
  --database="noop" \
  --user="noop_ownership" \
  --bootstrap-secret="noop-staging-database-url" \
  --secret="noop-staging-ownership-database-url" \
  --proxy-binary="$(command -v cloud-sql-proxy)" \
  --confirm-runtime-disabled
