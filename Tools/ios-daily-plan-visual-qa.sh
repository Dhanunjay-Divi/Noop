#!/bin/zsh
set -euo pipefail

emulate -L zsh
setopt pipe_fail

usage() {
    print -r -- "Usage: ${0:t} --app /absolute/path/to/NOOP.app [--output DIR] [--keep-simulator]"
}

repo_root="${0:A:h:h}"
app_path=""
output_dir="$repo_root/noop_WIP/screenshots/ios/round28-daily-plan"
keep_simulator=0

while (( $# > 0 )); do
    case "$1" in
        --app)
            app_path="$2"
            shift 2
            ;;
        --output)
            output_dir="$2"
            shift 2
            ;;
        --keep-simulator)
            keep_simulator=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            print -u2 -r -- "Unknown option: $1"
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -z "$app_path" || ! -d "$app_path" ]]; then
    print -u2 -r -- "A valid --app bundle is required."
    exit 2
fi

app_path="${app_path:A}"
output_dir="${output_dir:A}"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Info.plist")
runtime_id=$(
    xcrun simctl list runtimes available |
        awk '/^iOS / { candidate=$NF } END { print candidate }'
)
device_type="com.apple.CoreSimulator.SimDeviceType.iPhone-17e"
udid=""

cleanup() {
    if [[ -z "$udid" ]]; then
        return
    fi
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
    if (( keep_simulator == 0 )); then
        xcrun simctl delete "$udid" >/dev/null 2>&1 || true
    else
        print -r -- "Kept simulator: $udid"
    fi
}
trap cleanup EXIT INT TERM

validate_capture() {
    local screenshot="$1"
    local bytes
    local width
    local height
    local stats
    local ymin
    local ymax
    bytes=$(stat -f '%z' "$screenshot")
    width=$(sips -g pixelWidth "$screenshot" 2>/dev/null | awk '/pixelWidth:/ { print $2 }')
    height=$(sips -g pixelHeight "$screenshot" 2>/dev/null | awk '/pixelHeight:/ { print $2 }')
    if (( bytes < 200000 || width < 1000 || height < 2000 )); then
        print -u2 -r -- "Invalid screenshot: $screenshot ($bytes bytes, ${width}x${height})"
        return 1
    fi
    if command -v ffmpeg >/dev/null 2>&1; then
        stats=$(
            ffmpeg -v error -i "$screenshot" \
                -vf 'crop=iw*0.8:ih*0.7:iw*0.1:ih*0.15,signalstats,metadata=print:file=-' \
                -frames:v 1 -f null - 2>&1
        )
        ymin=$(print -r -- "$stats" | awk -F= '/lavfi.signalstats.YMIN=/ { print $2; exit }')
        ymax=$(print -r -- "$stats" | awk -F= '/lavfi.signalstats.YMAX=/ { print $2; exit }')
        if [[ -z "$ymin" || -z "$ymax" ]] || (( ymax - ymin < 24 )); then
            print -u2 -r -- "Blank screenshot content: $screenshot (Y range ${ymin:-?}-${ymax:-?})"
            return 1
        fi
    fi
}

assert_log_state() {
    local log="$1"
    local expected="$2"
    local planned_workout="$3"
    local expected_planned="false"
    if (( planned_workout == 1 )); then
        expected_planned="true"
    fi
    grep -Fq "Daily Plan QA availability=$expected" "$log" || {
        print -u2 -r -- "Expected availability=$expected in ${log:t}"
        tail -n 30 "$log" >&2
        return 1
    }
    grep -Fq "plannedWorkout=$expected_planned" "$log" || {
        print -u2 -r -- "Expected plannedWorkout=$expected_planned in ${log:t}"
        tail -n 30 "$log" >&2
        return 1
    }
}

warm_up_seed() {
    local stdout_log="$output_dir/warmup.stdout.log"
    local stderr_log="$output_dir/warmup.stderr.log"
    local result
    local pid
    local seeded=0

    : > "$stdout_log"
    : > "$stderr_log"
    result=$(
        xcrun simctl launch \
            --terminate-running-process \
            --stdout="$stdout_log" \
            --stderr="$stderr_log" \
            "$udid" \
            "$bundle_id" \
            --demo-seed \
            --demo-tab today
    )
    pid="${result##*: }"
    for _ in {1..30}; do
        if grep -Fq "AppleDemoSeeder: seeded" "$stderr_log"; then
            seeded=1
            break
        fi
        kill -0 "$pid" >/dev/null
        sleep 1
    done
    if (( seeded == 0 )); then
        print -u2 -r -- "Demo seed did not finish during simulator warm-up."
        tail -n 30 "$stderr_log" >&2
        return 1
    fi
    sleep 2
    xcrun simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
}

capture() {
    local name="$1"
    local check_in="$2"
    local appearance="$3"
    local content_size="$4"
    local contrast="$5"
    local expected="$6"
    local planned_workout="${7:-0}"
    local screenshot="$output_dir/$name.png"
    local stdout_log="$output_dir/$name.stdout.log"
    local stderr_log="$output_dir/$name.stderr.log"
    local result
    local pid
    local -a launch_args

    xcrun simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
    xcrun simctl ui "$udid" appearance "$appearance"
    xcrun simctl ui "$udid" content_size "$content_size"
    xcrun simctl ui "$udid" increase_contrast "$contrast"
    : > "$stdout_log"
    : > "$stderr_log"
    launch_args=(
        --demo-seed
        --demo-tab today
        --demo-daily-plan
        --demo-daily-plan-check-in "$check_in"
    )
    if (( planned_workout == 1 )); then
        launch_args+=(--demo-planned-workout)
    fi
    result=$(
        xcrun simctl launch \
            --terminate-running-process \
            --stdout="$stdout_log" \
            --stderr="$stderr_log" \
            "$udid" \
            "$bundle_id" \
            "${launch_args[@]}"
    )
    pid="${result##*: }"
    sleep 5
    kill -0 "$pid" >/dev/null
    xcrun simctl io "$udid" screenshot "$screenshot" >/dev/null
    validate_capture "$screenshot"
    assert_log_state "$stderr_log" "$expected" "$planned_workout"
    if grep -Eiq 'fatal error|uncaught exception|terminating app due|segmentation fault' "$stderr_log"; then
        print -u2 -r -- "Crash signature found in ${stderr_log:t}"
        return 1
    fi
    print -r -- "Captured $name ($check_in -> $expected)"
}

mkdir -p "$output_dir"
rm -f "$output_dir"/*.png "$output_dir"/*.stdout.log "$output_dir"/*.stderr.log

udid=$(
    xcrun simctl create \
        "NOOP Daily Plan QA" \
        "$device_type" \
        "$runtime_id"
)
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b
xcrun simctl status_bar "$udid" override \
    --time '9:41' \
    --dataNetwork wifi \
    --wifiMode active \
    --wifiBars 3 \
    --batteryState charged \
    --batteryLevel 100
xcrun simctl install "$udid" "$app_path"
warm_up_seed

capture check-in-needed unanswered light large disabled checkInNeeded
capture as-usual asUsual light large disabled ready
capture recovery-shift belowUsual light large disabled recoveryShift
capture stop painOrUnwell light large disabled stop
capture accessibility-stop painOrUnwell light accessibility-large disabled stop
capture dark-contrast-ready asUsual dark large enabled ready
capture planned-workout asUsual light large disabled ready 1

if cmp -s "$output_dir/check-in-needed.png" "$output_dir/stop.png"; then
    print -u2 -r -- "Distinct planner states produced identical captures."
    exit 1
fi

print -r -- "Daily Plan visual matrix complete: $output_dir"
