#!/usr/bin/env bash
#
# update-homebrew-cask.sh <version> [zip] — refresh a fork-owned Homebrew cask
# after a macOS release. The tap owner must be supplied explicitly with
# NOOP_HOMEBREW_TAP_ORG; this checkout deliberately has no upstream default.
# The generated cask downloads from Dhanunjay-Divi/Noop unless the release owner
# and repository are deliberately overridden with NOOP_RELEASE_GITHUB_*.
#
# Users install/update with:
#     brew tap <tap-owner>/noop
#     brew install --cask noop   /   brew upgrade --cask noop
#
# Tokens are read from ~/.config/noop/ and supplied via a transient git credential
# helper — never on a command line, URL, or in output.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAP_ORG="${NOOP_HOMEBREW_TAP_ORG:-}"
APP_ORG="${NOOP_RELEASE_GITHUB_OWNER:-Dhanunjay-Divi}"
APP_REPO="${NOOP_RELEASE_GITHUB_NAME:-Noop}"
AUTHOR_NAME="${NOOP_RELEASE_GIT_NAME:-Dhanunjay-Divi}"
AUTHOR_EMAIL="${NOOP_RELEASE_GIT_EMAIL:-Dhanunjay-Divi@users.noreply.github.com}"
[ -n "$TAP_ORG" ] || {
  echo "set NOOP_HOMEBREW_TAP_ORG to a fork-owned GitHub organization/user" >&2
  exit 1
}

VER="${1:?usage: $0 <version e.g. 4.7.0> [zip path]}"
ZIP="${2:-$HOME/Downloads/NOOP-macos-v${VER}.zip}"
SAFE_COMPONENT='^[A-Za-z0-9][A-Za-z0-9_.-]*$'
[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "invalid Homebrew release version" >&2
  exit 2
}
for coordinate in "$TAP_ORG" "$APP_ORG" "$APP_REPO"; do
  [[ "$coordinate" =~ $SAFE_COMPONENT ]] || {
    echo "invalid Homebrew repository coordinate" >&2
    exit 2
  }
done
GH_TOKEN_FILE="$HOME/.config/noop/gh_token"        # canonical tap host (github.com)
[ -f "$ZIP" ] || { echo "missing release zip: $ZIP" >&2; exit 1; }
GIT_TIMEOUT_SECONDS="${NOOP_HOMEBREW_GIT_TIMEOUT_SECONDS:-300}"
[[ "$GIT_TIMEOUT_SECONDS" =~ ^[1-9][0-9]{0,2}$ ]] &&
  [ "$GIT_TIMEOUT_SECONDS" -le 300 ] || {
  echo "invalid Homebrew Git timeout" >&2
  exit 2
}
unset NOOP_HOMEBREW_GIT_TIMEOUT_SECONDS

run_git_bounded() {
  python3 - "$GIT_TIMEOUT_SECONDS" "$@" <<'PY'
import os
import signal
import subprocess
import sys

timeout_seconds = int(sys.argv[1])
command = sys.argv[2:]
process = subprocess.Popen(command, start_new_session=True)
try:
    return_code = process.wait(timeout=timeout_seconds)
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
    print("Homebrew Git transport exceeded its deadline.", file=sys.stderr)
    raise SystemExit(124)
raise SystemExit(return_code)
PY
}

GIT_HTTP_ARGS=(
  -c http.lowSpeedLimit=1024
  -c http.lowSpeedTime=30
)

if [ -n "${NOOP_HOMEBREW_GITHUB_TOKEN:-}" ]; then
  GH_TOKEN="$NOOP_HOMEBREW_GITHUB_TOKEN"
elif [ -f "$GH_TOKEN_FILE" ]; then
  GH_TOKEN="$(cat "$GH_TOKEN_FILE")"
else
  echo "missing Homebrew tap GitHub token" >&2
  exit 1
fi
unset NOOP_HOMEBREW_GITHUB_TOKEN
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
GH_TAP_URL="https://github.com/$TAP_ORG/homebrew-noop.git"

# A Forge mirror is a separate, explicit opt-in. Require every coordinate so no
# stale local deployment file can redirect a release.
FORGE_TAP_URL=""
FORGE_TOKEN=""
if [ "${NOOP_HOMEBREW_FORGE:-0}" = "1" ]; then
  DOMAIN="${FORGE_DOMAIN:-}"
  FORGE_ORG="${FORGE_ORG:-}"
  FORGE_TOKEN_FILE="$HOME/.config/noop/forge_token"
  [ -n "$DOMAIN" ] && [ -n "$FORGE_ORG" ] || {
    echo "set FORGE_DOMAIN and FORGE_ORG when NOOP_HOMEBREW_FORGE=1" >&2
    exit 1
  }
  [[ "$DOMAIN" =~ $SAFE_COMPONENT ]] &&
    [[ "$FORGE_ORG" =~ $SAFE_COMPONENT ]] || {
    echo "invalid Forge repository coordinate" >&2
    exit 2
  }
  if [ -n "${NOOP_HOMEBREW_FORGE_TOKEN:-}" ]; then
    FORGE_TOKEN="$NOOP_HOMEBREW_FORGE_TOKEN"
  elif [ -f "$FORGE_TOKEN_FILE" ]; then
    FORGE_TOKEN="$(cat "$FORGE_TOKEN_FILE")"
  else
    echo "missing Homebrew Forgejo mirror token" >&2
    exit 1
  fi
  unset NOOP_HOMEBREW_FORGE_TOKEN
  FORGE_TAP_URL="https://$DOMAIN/$FORGE_ORG/homebrew-noop.git"
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
if ! run_git_bounded git "${GIT_HTTP_ARGS[@]}" clone --quiet \
  "$GH_TAP_URL" "$TMP/tap"; then
  echo "Homebrew tap clone failed or exceeded its deadline." >&2
  exit 1
fi

mkdir -p "$TMP/tap/Casks"
python3 "$ROOT/Tools/homebrew-version-gate.py" \
  --target "$VER" \
  --cask "$TMP/tap/Casks/noop.rb"
cat > "$TMP/tap/Casks/noop.rb" <<EOF
cask "noop" do
  version "${VER}"
  sha256 "${SHA}"

  url "https://github.com/${APP_ORG}/${APP_REPO}/releases/download/v#{version}/NOOP-macos-v#{version}.zip"
  name "NOOP"
  desc "Local-first wellness companion for compatible bands with optional self-hosted sync"
  homepage "https://github.com/${APP_ORG}/${APP_REPO}"

  app "NOOP.app"

  caveats "NOOP ships anonymously and is unsigned (no Apple Developer ID), so on first launch macOS Gatekeeper will block it. On macOS 15 Sequoia and later: try to open NOOP once, then go to System Settings > Privacy & Security, scroll down, and click 'Open Anyway' next to NOOP. (On macOS 14 and earlier you can right-click NOOP in /Applications and choose Open.) Update later with: brew upgrade --cask noop."
end
EOF

cd "$TMP/tap"
git -c user.name="$AUTHOR_NAME" -c user.email="$AUTHOR_EMAIL" add Casks/noop.rb
HOME_BREW_CHANGED=1
if git rev-parse HEAD >/dev/null 2>&1 && git diff --cached --quiet; then
  HOME_BREW_CHANGED=0
  echo "Homebrew cask already current for ${VER} on GitHub."
else
  git -c user.name="$AUTHOR_NAME" -c user.email="$AUTHOR_EMAIL" \
    commit --quiet -m "noop ${VER}"
fi

# Push to the explicitly configured GitHub tap (required).
if [ "$HOME_BREW_CHANGED" = "1" ]; then
  # shellcheck disable=SC2016 # The nested credential-helper shell expands these exported values.
  GH_TOKEN="$GH_TOKEN" TAP_ORG="$TAP_ORG" \
    run_git_bounded git "${GIT_HTTP_ARGS[@]}" \
      -c credential.helper='!f() { echo "username=$TAP_ORG"; echo "password=$GH_TOKEN"; }; f' \
      push --quiet "$GH_TAP_URL" HEAD:main
  echo "✓ Homebrew cask updated to ${VER} on GitHub (sha256 ${SHA:0:12}…)"
fi
unset GH_TOKEN

if [ -n "$FORGE_TAP_URL" ]; then
  # shellcheck disable=SC2016 # The nested credential-helper shell expands these exported values.
  FORGE_TOKEN="$FORGE_TOKEN" FORGE_ORG="$FORGE_ORG" \
    run_git_bounded git "${GIT_HTTP_ARGS[@]}" \
      -c credential.helper='!f() { echo "username=$FORGE_ORG"; echo "password=$FORGE_TOKEN"; }; f' \
      push --quiet "$FORGE_TAP_URL" HEAD:main || {
    echo "Forge mirror push failed; the canonical GitHub tap is current." >&2
    exit 1
  }
  unset FORGE_TOKEN
  echo "✓ Mirrored cask to the configured Forge host."
else
  echo "Forge mirror disabled (set NOOP_HOMEBREW_FORGE=1 plus FORGE_* to enable)."
fi
