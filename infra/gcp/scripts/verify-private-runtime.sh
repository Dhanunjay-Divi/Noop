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

project_id="$(tofu -chdir="${INFRA_DIR}" output -raw project_id)"
region="$(tofu -chdir="${INFRA_DIR}" output -raw region)"
instance="$(tofu -chdir="${INFRA_DIR}" output -raw database_instance)"
service_name="$(tofu -chdir="${INFRA_DIR}" output -raw private_api_name)"
migration_job="$(tofu -chdir="${INFRA_DIR}" output -raw migration_job)"
migration_marker="$(
  tofu -chdir="${INFRA_DIR}" output -raw migration_release_marker
)"
managed_api_output="$(tofu -chdir="${INFRA_DIR}" output -json managed_api)"
managed_service_name="$(
  python3 -c '
import json
import sys

value = json.load(sys.stdin)
if value is None:
    print("")
elif (
    isinstance(value, dict)
    and value.get("public") is False
    and isinstance(value.get("name"), str)
):
    print(value["name"])
else:
    raise SystemExit(1)
' <<<"${managed_api_output}"
)"

if [[ -z "${service_name}" ]]; then
  printf 'Private API is disabled.\n' >&2
  exit 1
fi
if [[ -z "${migration_job}" || -z "${migration_marker}" ]]; then
  printf 'Migration workload is disabled.\n' >&2
  exit 1
fi

service="$(
  gcloud run services describe "${service_name}" \
    --project="${project_id}" \
    --region="${region}" \
    --format=json
)"
if ! python3 -c '
import json
import re
import sys

service = json.load(sys.stdin)
annotations = service.get("metadata", {}).get("annotations", {})
conditions = service.get("status", {}).get("conditions", [])
template = service.get("spec", {}).get("template", {})
template_annotations = template.get("metadata", {}).get("annotations", {})
containers = template.get("spec", {}).get("containers", [])
image = containers[0].get("image", "") if containers else ""
checks = {
    "internal ingress": annotations.get("run.googleapis.com/ingress") == "internal",
    "Ready condition": any(
        item.get("type") == "Ready" and item.get("status") == "True"
        for item in conditions
    ),
    "scale to zero": template_annotations.get("autoscaling.knative.dev/minScale")
    == "0",
    "two-instance ceiling": template_annotations.get(
        "autoscaling.knative.dev/maxScale"
    )
    == "2",
    "digest-pinned image": re.search(r"@sha256:[0-9a-f]{64}$", image) is not None,
}
failed = [name for name, passed in checks.items() if not passed]
if failed:
    print("Private API checks failed: " + ", ".join(failed), file=sys.stderr)
    raise SystemExit(1)
' <<<"${service}"; then
  exit 1
fi

policy="$(
  gcloud run services get-iam-policy "${service_name}" \
    --project="${project_id}" \
    --region="${region}" \
    --format=json
)"
if ! python3 -c '
import json
import sys

policy = json.load(sys.stdin)
members = {
    member
    for binding in policy.get("bindings", [])
    for member in binding.get("members", [])
}
if {"allUsers", "allAuthenticatedUsers"} & members:
    raise SystemExit(1)
' <<<"${policy}"; then
  printf 'Private API has a broad invoker grant.\n' >&2
  exit 1
fi

if [[ -n "${managed_service_name}" ]]; then
  managed_service="$(
    gcloud run services describe "${managed_service_name}" \
      --project="${project_id}" \
      --region="${region}" \
      --format=json
  )"
  if ! python3 -c '
import json
import re
import sys

service = json.load(sys.stdin)
conditions = service.get("status", {}).get("conditions", [])
containers = service.get("spec", {}).get("template", {}).get("spec", {}).get(
    "containers",
    [],
)
image = containers[0].get("image", "") if containers else ""
checks = {
    "managed API Ready condition": any(
        item.get("type") == "Ready" and item.get("status") == "True"
        for item in conditions
    ),
    "managed API digest-pinned image": (
        re.search(r"@sha256:[0-9a-f]{64}$", image) is not None
    ),
}
failed = [name for name, passed in checks.items() if not passed]
if failed:
    print("Managed API checks failed: " + ", ".join(failed), file=sys.stderr)
    raise SystemExit(1)
' <<<"${managed_service}"; then
    exit 1
  fi

  managed_policy="$(
    gcloud run services get-iam-policy "${managed_service_name}" \
      --project="${project_id}" \
      --region="${region}" \
      --format=json
  )"
  if ! python3 -c '
import json
import sys

policy = json.load(sys.stdin)
members = {
    member
    for binding in policy.get("bindings", [])
    for member in binding.get("members", [])
}
if {"allUsers", "allAuthenticatedUsers"} & members:
    raise SystemExit(1)
' <<<"${managed_policy}"; then
    printf 'Managed API has a broad invoker grant.\n' >&2
    exit 1
  fi
fi

migration="$(
  gcloud run jobs describe "${migration_job}" \
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
latest = job.get("status", {}).get("latestCreatedExecution", {})
if len(containers) != 1:
    raise SystemExit(1)
container = containers[0]
image = str(container.get("image") or "")
environment = {
    item.get("name"): item.get("value")
    for item in container.get("env", [])
    if isinstance(item, dict) and item.get("value") is not None
}
checks = {
    "digest-pinned migration image": (
        re.search(r"@sha256:[0-9a-f]{64}$", image) is not None
    ),
    "migration image marker": (
        hashlib.sha256(image.encode("utf-8")).hexdigest()[:16] == expected
        and environment.get("NOOP_RUNTIME_RELEASE") == expected
    ),
    "successful migration execution": (
        latest.get("completionStatus") == "EXECUTION_SUCCEEDED"
    ),
}
failed = [name for name, passed in checks.items() if not passed]
if failed:
    print("Migration checks failed: " + ", ".join(failed), file=sys.stderr)
    raise SystemExit(1)
' "${migration_marker}" <<<"${migration}"; then
  exit 1
fi

point_in_time_recovery="$(
  gcloud sql instances describe "${instance}" \
    --project="${project_id}" \
    --format='value(settings.backupConfiguration.pointInTimeRecoveryEnabled)'
)"
if [[ "${point_in_time_recovery}" != "True" ]]; then
  printf 'Cloud SQL point-in-time recovery is disabled.\n' >&2
  exit 1
fi
deletion_protection="$(
  gcloud sql instances describe "${instance}" \
    --project="${project_id}" \
    --format='value(settings.deletionProtectionEnabled)'
)"
if [[ "${deletion_protection}" != "True" ]]; then
  printf 'Cloud SQL API deletion protection is disabled.\n' >&2
  exit 1
fi

printf 'Private runtime checks passed.\n'
