#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

project_id="$(tofu -chdir="${INFRA_DIR}" output -raw project_id)"
region="$(tofu -chdir="${INFRA_DIR}" output -raw region)"
job="$(tofu -chdir="${INFRA_DIR}" output -raw migration_job)"

if [[ -z "${job}" ]]; then
  printf 'Migration job is disabled; set a digest-pinned runtime_image first.\n' >&2
  exit 1
fi

gcloud run jobs execute "${job}" \
  --project="${project_id}" \
  --region="${region}" \
  --wait
