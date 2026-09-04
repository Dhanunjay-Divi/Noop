#!/usr/bin/env bash
#
# Verify that an installed iOS NOOP build is durably advancing its HR frontier.
# This reports counts/timestamps only; it never prints biometric values.
#
# Usage:
#   bash Tools/verify-ios-band-collection.sh \
#     --device <UDID> --bundle-id <bundle-id> [--wait 660] [--output DIR]
#
# With --wait, the first snapshot is taken while the phone is unlocked. Lock the
# phone when prompted; the second snapshot proves whether collection continued.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  verify-ios-band-collection.sh --device UDID --bundle-id BUNDLE_ID [options]

Options:
  --wait SECONDS  Compare a second snapshot after this interval (default: 0).
  --output DIR    Keep the small TSV summaries here.
  --help          Show this help.

The phone must be connected by USB, unlocked for the first snapshot, and trusted.
The database copy can take several minutes for a large local library; progress and
errors remain visible.
EOF
}

device=""
bundle_id=""
wait_seconds=0
output_dir=""

while (( $# > 0 )); do
  case "$1" in
    --device)
      device="${2:-}"
      shift 2
      ;;
    --bundle-id)
      bundle_id="${2:-}"
      shift 2
      ;;
    --wait)
      wait_seconds="${2:-}"
      shift 2
      ;;
    --output)
      output_dir="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'error: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$device" || -z "$bundle_id" ]]; then
  printf 'error: --device and --bundle-id are required.\n' >&2
  usage >&2
  exit 2
fi
if [[ ! "$wait_seconds" =~ ^[0-9]+$ ]]; then
  printf 'error: --wait must be a non-negative integer.\n' >&2
  exit 2
fi

for tool in xcrun sqlite3 find awk; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'error: required tool is unavailable: %s\n' "$tool" >&2
    exit 2
  fi
done

stamp=$(date -u +%Y%m%dT%H%M%SZ)
if [[ -z "$output_dir" ]]; then
  output_dir="$HOME/Documents/noop/collection-verification-$stamp"
fi
mkdir -p "$output_dir"

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/noop-band-verification.XXXXXX")
# shellcheck disable=SC2329  # Invoked indirectly by the trap below.
cleanup() {
  if [[ -n "${temporary_root:-}" &&
        "$temporary_root" == *"/noop-band-verification."* &&
        -d "$temporary_root" ]]; then
    rm -rf -- "$temporary_root"
  fi
}
trap cleanup EXIT INT TERM

printf '1/4 Checking CoreDevice for %s...\n' "$device"
device_list="$output_dir/devices.txt"
if ! xcrun devicectl list devices --timeout 15 >"$device_list" 2>&1; then
  printf 'FAIL: CoreDevice could not list devices. Details: %s\n' "$device_list" >&2
  exit 1
fi
if ! grep -Fq "$device" "$device_list"; then
  printf 'FAIL: iPhone %s is not visible to CoreDevice.\n' "$device" >&2
  printf 'Connect it by USB, unlock it, accept Trust, then retry. Device list: %s\n' \
    "$device_list" >&2
  exit 1
fi
printf 'PASS: iPhone is visible.\n'

snapshot_hr_rows=0
snapshot_latest_hr=0

table_exists() {
  local database="$1"
  local table="$2"
  sqlite3 -readonly "$database" \
    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='$table';"
}

capture_snapshot() {
  local label="$1"
  local destination="$temporary_root/$label"
  local transfer_log="$output_dir/$label-transfer.log"
  local summary="$output_dir/$label.tsv"
  local database
  local measured_rows=0
  local ppg_rows=0
  local latest_hr=0
  local battery_rows=0
  local latest_battery=0
  local now
  local age

  mkdir -p "$destination"
  printf '2/4 Copying the live SQLite store for %s...\n' "$label"
  printf '    Large stores can take several minutes. Timeout: 15 minutes.\n'
  if ! xcrun devicectl device copy from \
      --device "$device" \
      --domain-type appDataContainer \
      --domain-identifier "$bundle_id" \
      --user mobile \
      --source "Library/Application Support/OpenWhoop" \
      --destination "$destination" \
      --timeout 900 \
      --log-output "$transfer_log"; then
    printf 'FAIL: app-container copy failed. Details: %s\n' "$transfer_log" >&2
    exit 1
  fi

  database=$(find "$destination" -type f -name whoop.sqlite -print -quit)
  if [[ -z "$database" || ! -s "$database" ]]; then
    printf 'FAIL: whoop.sqlite was not present in the copied app container.\n' >&2
    printf 'Check the bundle id (%s). Transfer log: %s\n' "$bundle_id" "$transfer_log" >&2
    exit 1
  fi

  printf '3/4 Reading row counts and durable timestamps for %s...\n' "$label"
  if [[ "$(table_exists "$database" hrSample)" == "1" ]]; then
    measured_rows=$(sqlite3 -readonly "$database" \
      "SELECT COUNT(*) FROM hrSample;")
    latest_hr=$(sqlite3 -readonly "$database" \
      "SELECT COALESCE(MAX(ts), 0) FROM hrSample;")
  fi
  if [[ "$(table_exists "$database" ppgHrSample)" == "1" ]]; then
    ppg_rows=$(sqlite3 -readonly "$database" \
      "SELECT COUNT(*) FROM ppgHrSample;")
    latest_hr=$(sqlite3 -readonly "$database" \
      "SELECT MAX($latest_hr, COALESCE(MAX(ts), 0)) FROM ppgHrSample;")
  fi
  if [[ "$(table_exists "$database" battery)" == "1" ]]; then
    battery_rows=$(sqlite3 -readonly "$database" \
      "SELECT COUNT(*) FROM battery;")
    latest_battery=$(sqlite3 -readonly "$database" \
      "SELECT COALESCE(MAX(ts), 0) FROM battery;")
  fi

  now=$(date +%s)
  age=$((now - latest_hr))
  {
    printf 'snapshot\t%s\n' "$label"
    printf 'captured_at_unix\t%s\n' "$now"
    printf 'measured_hr_rows\t%s\n' "$measured_rows"
    printf 'ppg_hr_rows\t%s\n' "$ppg_rows"
    printf 'latest_hr_unix\t%s\n' "$latest_hr"
    printf 'latest_hr_local\t%s\n' \
      "$(date -r "$latest_hr" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || printf 'unavailable')"
    printf 'latest_hr_age_seconds\t%s\n' "$age"
    printf 'battery_rows\t%s\n' "$battery_rows"
    printf 'latest_battery_unix\t%s\n' "$latest_battery"
    printf 'latest_battery_local\t%s\n' \
      "$(date -r "$latest_battery" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || printf 'unavailable')"
  } >"$summary"

  snapshot_hr_rows=$((measured_rows + ppg_rows))
  snapshot_latest_hr=$latest_hr

  printf '    HR rows: %s (measured %s + PPG-derived %s)\n' \
    "$snapshot_hr_rows" "$measured_rows" "$ppg_rows"
  printf '    Latest durable HR: %s (age %ss)\n' \
    "$(awk -F '\t' '$1=="latest_hr_local" {print $2}' "$summary")" "$age"
  printf '    Latest battery: %s\n' \
    "$(awk -F '\t' '$1=="latest_battery_local" {print $2}' "$summary")"
  printf '    Summary: %s\n' "$summary"
}

capture_snapshot baseline
baseline_rows=$snapshot_hr_rows
baseline_latest=$snapshot_latest_hr

if (( wait_seconds == 0 )); then
  now=$(date +%s)
  age=$((now - baseline_latest))
  if (( baseline_latest > 0 && age >= -300 && age <= 180 )); then
    printf '4/4 PASS: persisted HR is current. Run with --wait 660 for a locked-phone test.\n'
    exit 0
  fi
  printf '4/4 FAIL: persisted HR is stale or missing (age %ss).\n' "$age" >&2
  exit 1
fi

printf '4/4 Lock the iPhone now and keep wearing the band. Waiting %ss...\n' "$wait_seconds"
remaining=$wait_seconds
while (( remaining > 0 )); do
  step=30
  if (( remaining < step )); then step=$remaining; fi
  sleep "$step"
  remaining=$((remaining - step))
  printf '    %ss remaining...\n' "$remaining"
done

capture_snapshot after-lock
after_rows=$snapshot_hr_rows
after_latest=$snapshot_latest_hr
now=$(date +%s)
after_age=$((now - after_latest))

printf 'Comparison: rows %+d, HR frontier %+ds, final age %ss.\n' \
  "$((after_rows - baseline_rows))" "$((after_latest - baseline_latest))" "$after_age"
if (( after_rows > baseline_rows &&
      after_latest > baseline_latest &&
      after_age >= -300 &&
      after_age <= 180 )); then
  printf 'PASS: durable HR collection advanced while the phone was locked.\n'
  exit 0
fi

printf 'FAIL: durable HR collection did not remain current while locked.\n' >&2
printf 'Shake the phone in NOOP and share the App report; it now includes latest_hr_unix.\n' >&2
exit 1
