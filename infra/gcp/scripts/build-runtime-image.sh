#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${INFRA_DIR}/../.." && pwd)"

for command in gcloud git tofu; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "${command}" >&2
    exit 1
  fi
done

if [[ -n "$(git -C "${REPO_ROOT}" status --porcelain --untracked-files=normal)" ]]; then
  printf 'Refusing to build from a dirty worktree. Commit the reviewed source first.\n' >&2
  exit 1
fi

project_id="$(tofu -chdir="${INFRA_DIR}" output -raw project_id)"
region="$(tofu -chdir="${INFRA_DIR}" output -raw region)"
source_bucket="$(tofu -chdir="${INFRA_DIR}" output -raw build_source_bucket)"
builder="$(tofu -chdir="${INFRA_DIR}" output -raw builder_service_account)"
commit="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
tag="git-${commit:0:12}"
tag_uri="${region}-docker.pkg.dev/${project_id}/noop-staging/api:${tag}"

existing_digest="$(
  gcloud artifacts docker images describe "${tag_uri}" \
    --project="${project_id}" \
    --format='value(image_summary.digest)' 2>/dev/null || true
)"
if [[ -z "${existing_digest}" ]]; then
  gcloud builds submit "${REPO_ROOT}/server" \
    --project="${project_id}" \
    --region="${region}" \
    --service-account="projects/${project_id}/serviceAccounts/${builder}" \
    --gcs-source-staging-dir="gs://${source_bucket}/source" \
    --gcs-log-dir="gs://${source_bucket}/logs" \
    --tag="${tag_uri}"
  existing_digest="$(
    gcloud artifacts docker images describe "${tag_uri}" \
      --project="${project_id}" \
      --format='value(image_summary.digest)'
  )"
fi

if [[ ! "${existing_digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  printf 'Artifact Registry did not return a valid image digest.\n' >&2
  exit 1
fi

printf '%s@%s\n' "${tag_uri%:*}" "${existing_digest}"
