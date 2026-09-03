#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

project_id="$(tofu -chdir="${INFRA_DIR}" output -raw project_id)"
region="$(tofu -chdir="${INFRA_DIR}" output -raw region)"
instance="$(tofu -chdir="${INFRA_DIR}" output -raw database_instance)"
service_name="$(tofu -chdir="${INFRA_DIR}" output -raw private_api_name)"

if [[ -z "${service_name}" ]]; then
  printf 'Private API is disabled.\n' >&2
  exit 1
fi

ingress="$(
  gcloud run services describe "${service_name}" \
    --project="${project_id}" \
    --region="${region}" \
    --format='value(metadata.annotations.run.googleapis.com/ingress)'
)"
if [[ "${ingress}" != "internal" ]]; then
  printf 'Private API ingress is not internal-only.\n' >&2
  exit 1
fi
ready="$(
  gcloud run services describe "${service_name}" \
    --project="${project_id}" \
    --region="${region}" \
    --format='value(status.conditions[0].status)'
)"
if [[ "${ready}" != "True" ]]; then
  printf 'Private API is not Ready.\n' >&2
  exit 1
fi

policy="$(
  gcloud run services get-iam-policy "${service_name}" \
    --project="${project_id}" \
    --region="${region}" \
    --format='value(bindings.members)'
)"
if [[ "${policy}" == *'allUsers'* || "${policy}" == *'allAuthenticatedUsers'* ]]; then
  printf 'Private API has a broad invoker grant.\n' >&2
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
