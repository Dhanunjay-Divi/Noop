#!/bin/sh
# Xcode Archive guard for NOOP's temporary launch-access verifier. Never print verifier values.
set -eu

# Ordinary Debug/Release builds remain usable for development. App Store archives use ACTION=install.
if [ "${ACTION:-}" != "install" ] || [ "${NOOP_LAUNCH_GATE_REQUIRED:-NO}" != "YES" ]; then
    exit 0
fi

fail() {
    printf '%s\n' "error: Release archive requires a valid ignored launch-gate verifier config." >&2
    printf '%s\n' "error: Run Tools/generate-launch-gate-verifier.py interactively, then archive again." >&2
    exit 1
}

version=${NOOP_LAUNCH_GATE_VERSION:-}
salt=${NOOP_LAUNCH_GATE_SALT_HEX:-}
verifier=${NOOP_LAUNCH_GATE_VERIFIER_HEX:-}
iterations=${NOOP_LAUNCH_GATE_ITERATIONS:-}

[ -n "$version" ] || fail
[ "${#version}" -le 128 ] || fail
case "$version" in [!A-Za-z0-9]*|*'$('*|*[!A-Za-z0-9._-]*) fail ;; esac
[ "${#salt}" -eq 32 ] || fail
[ "${#verifier}" -eq 64 ] || fail
case "$salt$verifier" in *[!0-9A-Fa-f]*) fail ;; esac
case "$iterations" in ''|*[!0-9]*) fail ;; esac
[ "$iterations" -ge 100000 ] 2>/dev/null || fail
[ "$iterations" -le 2000000 ] 2>/dev/null || fail

exit 0
