#!/bin/zsh
set -euo pipefail

emulate -L zsh
setopt pipe_fail

script_name="${0:t}"

usage() {
    print -r -- "Usage: $script_name --app /absolute/path/to/NOOP.app [options]"
    print -r -- "       $script_name --validate-only [--output DIR] [options]"
    print -r -- ""
    print -r -- "Options:"
    print -r -- "  --output DIR       Screenshot/log directory (default: noop_WIP/screenshots/ios/tab-shell-matrix)"
    print -r -- "  --runtime ID       iOS simulator runtime (default: newest installed iOS runtime)"
    print -r -- "  --device-type ID   Override default devices; repeat for multiple device types"
    print -r -- "  --keep-simulators  Keep disposable simulators after the run"
    print -r -- "  --validate-only    Validate an existing output directory without launching simulators"
}

repo_root="${0:A:h:h}"
app_path=""
output_dir="$repo_root/noop_WIP/screenshots/ios/tab-shell-matrix"
runtime_id=""
keep_simulators=0
validate_only=0
typeset -a requested_device_types
requested_device_types=()

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
        --runtime)
            runtime_id="$2"
            shift 2
            ;;
        --device-type)
            requested_device_types+=("$2")
            shift 2
            ;;
        --keep-simulators)
            keep_simulators=1
            shift
            ;;
        --validate-only)
            validate_only=1
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

if (( validate_only == 0 )) && [[ -z "$app_path" ]]; then
    print -u2 -r -- "--app is required."
    usage >&2
    exit 2
fi

output_dir="${output_dir:A}"
bundle_id=""
if [[ -n "$app_path" ]]; then
    app_path="${app_path:A}"
    if [[ ! -d "$app_path" ]]; then
        print -u2 -r -- "App bundle not found: $app_path"
        exit 2
    fi

    bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Info.plist")
    if [[ -z "$bundle_id" ]]; then
        print -u2 -r -- "Could not read CFBundleIdentifier from $app_path"
        exit 2
    fi
fi

if (( validate_only == 0 )) && [[ -z "$runtime_id" ]]; then
    runtime_id=$(
        xcrun simctl list runtimes available |
            awk '/^iOS / { candidate=$NF } END { print candidate }'
    )
fi
if (( validate_only == 0 )) && [[ -z "$runtime_id" ]]; then
    print -u2 -r -- "No available iOS simulator runtime found."
    exit 2
fi

typeset -a device_types
if (( ${#requested_device_types[@]} > 0 )); then
    device_types=("${requested_device_types[@]}")
else
    device_types=(
        "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max"
        "com.apple.CoreSimulator.SimDeviceType.iPhone-17e"
    )
fi

typeset -a scenario_names
scenario_names=(
    nutrition-expanded
    nutrition-bottom
    today-top
    today-alert
    today-bottom
    trends-bottom
    workouts-bottom
    workouts-accessibility
    sleep-bottom
    alarm-top
    alarm-bottom
    more-bottom
    more-compact
    more-accessibility
    friends-bottom
    nutrition-dark-contrast
    keyboard-visible
    keyboard-restored
    safety
    quick-actions
)

manifest="$output_dir/manifest.tsv"
launch_log_dir="$repo_root/noop_WIP/screenshots/ios/.tab-shell-launch-logs-$$"
if (( validate_only == 0 )); then
    mkdir -p "$output_dir"
    mkdir -p "$launch_log_dir"
    print -r -- $'device\tscenario\tappearance\tcontent_size\tcontrast\tscreenshot\targuments' > "$manifest"
fi

current_udid=""
current_device_dir=""

cleanup_current_device() {
    if [[ -z "$current_udid" ]]; then
        return
    fi

    xcrun simctl shutdown "$current_udid" >/dev/null 2>&1 || true
    if (( keep_simulators == 0 )); then
        xcrun simctl delete "$current_udid" >/dev/null 2>&1 || true
    else
        print -r -- "Kept simulator: $current_udid"
    fi
    current_udid=""
}

cleanup() {
    cleanup_current_device
    if (( validate_only == 0 )); then
        rmdir "$launch_log_dir" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

device_slug() {
    print -r -- "$1" |
        sed -E 's/^com\.apple\.CoreSimulator\.SimDeviceType\.//' |
        tr '[:upper:]' '[:lower:]'
}

validate_capture() {
    local screenshot="$1"
    local bytes
    local format
    local width
    local height

    if [[ ! -s "$screenshot" ]]; then
        print -u2 -r -- "Missing or empty screenshot: $screenshot"
        return 1
    fi

    bytes=$(stat -f '%z' "$screenshot")
    format=$(sips -g format "$screenshot" 2>/dev/null | awk '/format:/ { print $2 }')
    width=$(sips -g pixelWidth "$screenshot" 2>/dev/null | awk '/pixelWidth:/ { print $2 }')
    height=$(sips -g pixelHeight "$screenshot" 2>/dev/null | awk '/pixelHeight:/ { print $2 }')

    if [[ "$format" != "png" ]] || (( bytes < 10000 || width < 1000 || height < 2000 )); then
        print -u2 -r -- \
            "Invalid screenshot: $screenshot (format=$format bytes=$bytes size=${width}x${height})"
        return 1
    fi
}

validate_device_artifacts() {
    local device_dir="$1"
    local scenario
    local stderr_log
    local stdout_log

    if [[ ! -d "$device_dir" ]]; then
        print -u2 -r -- "Missing device evidence directory: $device_dir"
        return 1
    fi

    for scenario in "${scenario_names[@]}"; do
        validate_capture "$device_dir/$scenario.png"
        stderr_log="$device_dir/$scenario.stderr.log"
        stdout_log="$device_dir/$scenario.stdout.log"
        if [[ ! -f "$stderr_log" || ! -f "$stdout_log" ]]; then
            print -u2 -r -- "Missing launch logs for $device_dir/$scenario"
            return 1
        fi
    done

    if grep -Eiq \
        'fatal error|uncaught exception|terminating app due|segmentation fault|signal (6|11)' \
        "$device_dir"/*.stderr.log; then
        print -u2 -r -- "Crash signature found in $device_dir launch logs."
        return 1
    fi

    grep -Fq 'mixed=true' "$device_dir/nutrition-expanded.stderr.log" || {
        print -u2 -r -- "Nutrition fixture did not report the expected mixed-source state."
        return 1
    }
    grep -Fq 'Tab shell keyboard QA focused mode=visible' \
        "$device_dir/keyboard-visible.stderr.log" || {
        print -u2 -r -- "Keyboard-visible route did not focus its real text field."
        return 1
    }
    grep -Fq 'Tab shell keyboard QA focused mode=restored' \
        "$device_dir/keyboard-restored.stderr.log" || {
        print -u2 -r -- "Keyboard-restored route did not focus its real text field."
        return 1
    }
    grep -Fq 'Tab shell keyboard QA dismissed mode=restored' \
        "$device_dir/keyboard-restored.stderr.log" || {
        print -u2 -r -- "Keyboard-restored route did not dismiss its real text field."
        return 1
    }
    if cmp -s "$device_dir/keyboard-visible.png" "$device_dir/keyboard-restored.png"; then
        print -u2 -r -- "Keyboard-visible and keyboard-restored captures are identical."
        return 1
    fi

    print -r -- "Validated ${device_dir:t}: ${#scenario_names[@]} scenarios"
}

validate_manifest() {
    local expected_rows=$(( ${#device_types[@]} * ${#scenario_names[@]} ))
    local actual_rows
    local unique_rows

    if [[ ! -f "$manifest" ]]; then
        print -u2 -r -- "Missing matrix manifest: $manifest"
        return 1
    fi

    actual_rows=$(awk 'END { if (NR > 0) print NR - 1; else print 0 }' "$manifest")
    unique_rows=$(
        awk -F '\t' '
            NR > 1 { seen[$1 FS $2] = 1 }
            END { print length(seen) }
        ' "$manifest"
    )
    if (( actual_rows != expected_rows || unique_rows != expected_rows )); then
        print -u2 -r -- \
            "Manifest coverage mismatch: expected=$expected_rows rows=$actual_rows unique=$unique_rows"
        return 1
    fi

    print -r -- "Validated manifest: $actual_rows unique device/scenario rows"
}

wait_for_app_settle() {
    local seconds="$1"
    local pid="$2"
    local tenths=$(( seconds * 10 ))
    local index

    for (( index = 0; index < tenths; index++ )); do
        if ! kill -0 "$pid" >/dev/null 2>&1; then
            print -u2 -r -- "App process $pid exited before capture."
            return 1
        fi
        sleep 0.1
    done
}

capture_scenario() {
    local scenario="$1"
    local appearance="$2"
    local content_size="$3"
    local contrast="$4"
    local settle_seconds="$5"
    shift 5
    local -a app_arguments
    app_arguments=("$@")

    local screenshot="$current_device_dir/$scenario.png"
    local stdout_log="$current_device_dir/$scenario.stdout.log"
    local stderr_log="$current_device_dir/$scenario.stderr.log"
    local redirected_stdout="$launch_log_dir/${current_device_dir:t}-$scenario.stdout.log"
    local redirected_stderr="$launch_log_dir/${current_device_dir:t}-$scenario.stderr.log"
    local launch_result
    local app_pid
    local attempt

    xcrun simctl terminate "$current_udid" "$bundle_id" >/dev/null 2>&1 || true
    xcrun simctl ui "$current_udid" appearance "$appearance"
    xcrun simctl ui "$current_udid" content_size "$content_size"
    xcrun simctl ui "$current_udid" increase_contrast "$contrast"

    # CoreSimulator 26 silently drops app redirects under /private/tmp. Capture from the workspace,
    # then move the flushed evidence beside the screenshot so arbitrary --output paths remain valid.
    : > "$redirected_stdout"
    : > "$redirected_stderr"
    launch_result=""
    for attempt in 1 2 3; do
        if launch_result=$(
            xcrun simctl launch \
                --terminate-running-process \
                --stdout="$redirected_stdout" \
                --stderr="$redirected_stderr" \
                "$current_udid" \
                "$bundle_id" \
                --demo-seed \
                "${app_arguments[@]}"
        ); then
            break
        fi
        print -u2 -r -- "Launch attempt $attempt failed for $scenario; retrying."
        sleep 0.75
    done
    if [[ -z "$launch_result" ]]; then
        print -u2 -r -- "Could not launch $bundle_id for $scenario."
        return 1
    fi
    app_pid="${launch_result##*: }"
    wait_for_app_settle "$settle_seconds" "$app_pid"
    xcrun simctl io "$current_udid" screenshot "$screenshot" >/dev/null
    xcrun simctl terminate "$current_udid" "$bundle_id" >/dev/null 2>&1 || true
    mv -f "$redirected_stdout" "$stdout_log"
    mv -f "$redirected_stderr" "$stderr_log"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${current_device_dir:t}" \
        "$scenario" \
        "$appearance" \
        "$content_size" \
        "$contrast" \
        "${screenshot:t}" \
        "${(j: :)app_arguments}" \
        >> "$manifest"
    print -r -- "Captured ${current_device_dir:t}/$scenario"
}

run_device_matrix() {
    local device_type="$1"
    local slug
    slug=$(device_slug "$device_type")
    current_device_dir="$output_dir/$slug"
    mkdir -p "$current_device_dir"

    current_udid=$(
        xcrun simctl create \
            "NOOP Tab Shell QA $slug" \
            "$device_type" \
            "$runtime_id"
    )
    print -r -- "Booting $slug ($current_udid)"
    xcrun simctl boot "$current_udid"
    xcrun simctl bootstatus "$current_udid" -b
    xcrun simctl status_bar "$current_udid" override \
        --time '9:41' \
        --dataNetwork wifi \
        --wifiMode active \
        --wifiBars 3 \
        --batteryState charged \
        --batteryLevel 100
    # A connected hardware keyboard suppresses the software keyboard and invalidates the shell test.
    xcrun simctl spawn "$current_udid" defaults write \
        com.apple.Preferences ConnectHardwareKeyboard -bool false
    xcrun simctl install "$current_udid" "$app_path"
    sleep 1

    capture_scenario nutrition-expanded light large disabled 4 \
        --demo-nutrition --demo-more-route nutrition
    capture_scenario nutrition-bottom light large disabled 4 \
        --demo-nutrition --demo-more-route nutrition --demo-scroll-bottom
    capture_scenario today-top dark large disabled 5 \
        --demo-tab today
    capture_scenario today-alert dark large disabled 5 \
        --demo-tab today --demo-daily-signal alert
    capture_scenario today-bottom light large disabled 5 \
        --demo-tab today --demo-scroll-bottom
    capture_scenario trends-bottom light large disabled 4 \
        --demo-tab trends --demo-scroll-bottom
    capture_scenario workouts-bottom light large disabled 4 \
        --demo-tab workouts --demo-scroll-bottom
    capture_scenario workouts-accessibility light accessibility-large disabled 4 \
        --demo-tab workouts --demo-compact-tab-bar
    capture_scenario sleep-bottom light large disabled 4 \
        --demo-tab sleep --demo-scroll-bottom
    capture_scenario alarm-top dark large disabled 4 \
        --demo-more-route alarms
    capture_scenario alarm-bottom dark large disabled 4 \
        --demo-more-route alarms --demo-scroll-bottom --demo-compact-tab-bar
    capture_scenario more-bottom light large disabled 4 \
        --demo-tab more --demo-scroll-bottom
    capture_scenario more-compact light large disabled 3 \
        --demo-tab more --demo-compact-tab-bar
    capture_scenario more-accessibility light accessibility-large disabled 4 \
        --demo-tab more --demo-compact-tab-bar
    capture_scenario friends-bottom light large disabled 4 \
        --demo-more-route friends --demo-scroll-bottom
    capture_scenario nutrition-dark-contrast dark large enabled 4 \
        --demo-nutrition --demo-more-route nutrition
    capture_scenario keyboard-visible light large disabled 4 \
        --demo-more-route coach --demo-shell-keyboard-visible
    capture_scenario keyboard-restored light large disabled 5 \
        --demo-more-route coach --demo-shell-keyboard-restored
    capture_scenario safety light large disabled 4 \
        --demo-more-route safety
    capture_scenario quick-actions light large disabled 4 \
        --demo-tab today --demo-quick-actions

    validate_device_artifacts "$current_device_dir" || return 1
    cleanup_current_device
}

if (( validate_only == 1 )); then
    for device_type in "${device_types[@]}"; do
        validate_device_artifacts "$output_dir/$(device_slug "$device_type")" || exit 1
    done
    validate_manifest || exit 1
    print -r -- "Existing tab-shell visual matrix is valid: $output_dir"
    exit 0
fi

for device_type in "${device_types[@]}"; do
    run_device_matrix "$device_type" || exit 1
done

validate_manifest || exit 1
print -r -- "Tab-shell visual matrix complete: $output_dir"
