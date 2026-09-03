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

if [[ "$#" -ne 1 ]]; then
  printf 'Usage: %s <digest-pinned-runtime-image>\n' "$0" >&2
  exit 2
fi

image="$1"
project_id="$(tofu -chdir="${INFRA_DIR}" output -raw project_id)"
region="$(tofu -chdir="${INFRA_DIR}" output -raw region)"
expected_prefix="${region}-docker.pkg.dev/${project_id}/noop-staging/api@sha256:"
digest="${image#"${expected_prefix}"}"

if [[ "${image}" != "${expected_prefix}"* || ! "${digest}" =~ ^[0-9a-f]{64}$ ]]; then
  printf 'Image must be a digest in the managed NOOP staging repository.\n' >&2
  exit 1
fi

case "${region}" in
  asia-*) scan_location="asia" ;;
  europe-*) scan_location="europe" ;;
  *) scan_location="us" ;;
esac

operation="$(
  gcloud artifacts docker images scan "${image}" \
    --project="${project_id}" \
    --remote \
    --location="${scan_location}" \
    --async \
    --format='value(name)' \
    --quiet
)"
if [[ -z "${operation}" ]]; then
  printf 'On-demand scanning did not return an operation.\n' >&2
  exit 1
fi

scan=""
for _attempt in {1..150}; do
  done_value="$(
    gcloud artifacts docker images get-operation "${operation}" \
      --project="${project_id}" \
      --location="${scan_location}" \
      --format='value(done)'
  )"
  if [[ "${done_value}" == "True" ]]; then
    scan="$(
      gcloud artifacts docker images get-operation "${operation}" \
        --project="${project_id}" \
        --location="${scan_location}" \
        --format='value(response.scan)'
    )"
    break
  fi
  sleep 2
done

if [[ -z "${scan}" ]]; then
  error_message="$(
    gcloud artifacts docker images get-operation "${operation}" \
      --project="${project_id}" \
      --location="${scan_location}" \
      --format='value(error.message)'
  )"
  if [[ -n "${error_message}" ]]; then
    printf 'On-demand scan failed: %s\n' "${error_message}" >&2
  else
    printf 'On-demand scan did not complete within five minutes.\n' >&2
  fi
  exit 1
fi

gcloud artifacts docker images list-vulnerabilities "${scan}" \
  --project="${project_id}" \
  --location="${scan_location}" \
  --format=json |
  python3 -c '
import collections
import json
import sys

rows = [row for row in json.load(sys.stdin) if row]
counts = collections.Counter(
    row.get("vulnerability", {}).get("effectiveSeverity") or "UNSPECIFIED"
    for row in rows
)
order = ("CRITICAL", "HIGH", "MEDIUM", "LOW", "MINIMAL", "UNSPECIFIED")
summary = ", ".join(f"{severity}={counts[severity]}" for severity in order)
print(f"Vulnerability scan: {len(rows)} total; {summary}")

material = []
for row in rows:
    vulnerability = row.get("vulnerability", {})
    severity = vulnerability.get("effectiveSeverity") or "UNSPECIFIED"
    if severity not in {"CRITICAL", "HIGH"}:
        continue
    identifier = (
        vulnerability.get("shortDescription")
        or row.get("noteName", "").rsplit("/", maxsplit=1)[-1]
        or "unknown"
    )
    issues = vulnerability.get("packageIssue") or [{}]
    for issue in issues:
        material.append(
            (
                severity,
                identifier,
                issue.get("affectedPackage") or "unknown-package",
            )
        )

for severity, identifier, package in sorted(set(material)):
    print(f"{severity}: {identifier} ({package})", file=sys.stderr)
if material:
    raise SystemExit(1)
'
