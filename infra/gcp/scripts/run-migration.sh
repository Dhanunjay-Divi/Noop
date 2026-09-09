#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

for command in gcloud python3 tofu; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "${command}" >&2
    exit 1
  fi
done

project_id="$(
  printf '%s' "${NOOP_MIGRATION_PROJECT_ID:-$(
    tofu -chdir="${INFRA_DIR}" output -raw project_id
  )}"
)"
region="$(
  printf '%s' "${NOOP_MIGRATION_REGION:-$(
    tofu -chdir="${INFRA_DIR}" output -raw region
  )}"
)"
job="$(
  printf '%s' "${NOOP_MIGRATION_JOB:-$(
    tofu -chdir="${INFRA_DIR}" output -raw migration_job
  )}"
)"

if [[ -z "${job}" ]]; then
  printf 'Migration job is disabled; set a digest-pinned migration_image or runtime_image first.\n' >&2
  exit 1
fi

expected_marker="$(
  printf '%s' "${NOOP_MIGRATION_RELEASE_MARKER:-$(
    tofu -chdir="${INFRA_DIR}" output -raw migration_release_marker
  )}"
)"
job_configuration="$(
  gcloud run jobs describe "${job}" \
    --project="${project_id}" \
    --region="${region}" \
    --format=json
)"
if ! python3 -c '
import hashlib
import json
import re
import sys

expected = sys.argv[1]
job = json.load(sys.stdin)
template = (
    job.get("spec", {})
    .get("template", {})
    .get("spec", {})
    .get("template", {})
    .get("spec", {})
)
containers = template.get("containers", [])
if len(containers) != 1:
    raise SystemExit(1)
container = containers[0]
image = str(container.get("image") or "")
environment = {
    item.get("name"): item.get("value")
    for item in container.get("env", [])
    if isinstance(item, dict) and item.get("value") is not None
}
if (
    re.search(r"@sha256:[0-9a-f]{64}$", image) is None
    or hashlib.sha256(image.encode("utf-8")).hexdigest()[:16] != expected
    or environment.get("NOOP_RUNTIME_RELEASE") != expected
):
    raise SystemExit(1)
' "${expected_marker}" <<<"${job_configuration}"; then
  printf 'Migration job image does not match the configured release marker.\n' >&2
  exit 1
fi

gcloud run jobs execute "${job}" \
  --project="${project_id}" \
  --region="${region}" \
  --wait
