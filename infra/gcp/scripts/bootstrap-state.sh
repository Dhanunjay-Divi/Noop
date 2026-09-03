#!/bin/sh
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
    echo "usage: $0 PROJECT_ID [REGION] [BUCKET_NAME]" >&2
    exit 64
fi

project_id=$1
region=${2:-asia-south1}
bucket_name=${3:-"${project_id}-noop-tofu-state"}
bucket_uri="gs://${bucket_name}"

if ! command -v gcloud >/dev/null 2>&1; then
    echo "gcloud is required" >&2
    exit 69
fi

active_project=$(gcloud config get-value project 2>/dev/null || true)
if [ "$active_project" != "$project_id" ]; then
    echo "active gcloud project is '$active_project', expected '$project_id'" >&2
    exit 78
fi

billing_enabled=$(
    gcloud billing projects describe "$project_id" \
        --format='value(billingEnabled)'
)
if [ "$billing_enabled" != "True" ]; then
    echo "billing is not enabled for project '$project_id'" >&2
    exit 78
fi

if ! gcloud storage buckets describe "$bucket_uri" >/dev/null 2>&1; then
    gcloud storage buckets create "$bucket_uri" \
        --project="$project_id" \
        --location="$region" \
        --uniform-bucket-level-access \
        --public-access-prevention \
        --soft-delete-duration=0
fi

gcloud storage buckets update "$bucket_uri" \
    --versioning \
    --uniform-bucket-level-access \
    --public-access-prevention \
    --soft-delete-duration=0

cat <<EOF
Remote state bucket is ready.

Create infra/gcp/backend.hcl with:

bucket = "$bucket_name"
prefix = "noop/staging"
EOF
