#!/usr/bin/env bash
#
# Dispatch the canonical production release workflow from an exact, reviewed
# main commit. Artifact construction, signing checks, publication, and the
# AltStore channel remain owned by GitHub Actions.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPOSITORY="${NOOP_RELEASE_GITHUB_REPO:-Dhanunjay-Divi/Noop}"
VERSION="${1:-}"
PUBLISH_HOMEBREW=false

if [ "$#" -ne 1 ] || [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: Tools/release.sh <version>" >&2
  exit 2
fi
case "${NOOP_RELEASE_HOMEBREW:-0}" in
  0 | "")
    ;;
  1)
    PUBLISH_HOMEBREW=true
    ;;
  *)
    echo "NOOP_RELEASE_HOMEBREW must be 0 or 1" >&2
    exit 2
    ;;
esac

command -v gh >/dev/null 2>&1 || {
  echo "gh CLI is required" >&2
  exit 1
}
cd "$ROOT"

BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
if [ "$BRANCH" != "main" ]; then
  echo "release dispatch requires the local main branch" >&2
  exit 1
fi
if [ -n "$(git status --porcelain=v1 --untracked-files=normal)" ] ||
   ! git diff --quiet ||
   ! git diff --cached --quiet; then
  echo "release dispatch requires a clean worktree" >&2
  exit 1
fi

git fetch --quiet origin main --tags
SOURCE_SHA="$(git rev-parse HEAD)"
REMOTE_SHA="$(git rev-parse origin/main)"
if [ "$SOURCE_SHA" != "$REMOTE_SHA" ]; then
  echo "local main must exactly match origin/main" >&2
  exit 1
fi

ANDROID_VERSION="$(
  sed -n 's/.*versionName = "\([^"]*\)".*/\1/p' \
    android/app/build.gradle.kts | head -1
)"
APPLE_VERSION="$(
  sed -n 's/.*MARKETING_VERSION: "\([^"]*\)".*/\1/p' \
    project.yml | head -1
)"
if [ "$ANDROID_VERSION" != "$VERSION" ] || [ "$APPLE_VERSION" != "$VERSION" ]; then
  echo "requested version does not match reviewed Apple and Android source" >&2
  exit 1
fi

python3 Tools/release-control-gate.py check
TOKEN="${GH_TOKEN:-$(gh auth token)}"
GH_TOKEN="$TOKEN" python3 Tools/required-ci-gate.py verify-github \
  --repository "$REPOSITORY" \
  --sha "$SOURCE_SHA"

if [ "${ALLOW_RAPID_RELEASE:-0}" != "1" ]; then
  RELEASES="$(mktemp)"
  trap 'rm -f "$RELEASES"' EXIT
  GH_TOKEN="$TOKEN" gh api \
    "repos/${REPOSITORY}/releases?per_page=20" > "$RELEASES"
  read -r RELEASES_TODAY MINUTES_SINCE_LAST < <(
    python3 - "$RELEASES" <<'PY'
import datetime as dt
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    releases = json.load(handle)
now = dt.datetime.now(dt.timezone.utc)
published = []
for release in releases:
    if release.get("draft"):
        continue
    value = release.get("published_at") or release.get("created_at")
    if not isinstance(value, str):
        continue
    published.append(dt.datetime.fromisoformat(value.replace("Z", "+00:00")))
count_today = sum(item.date() == now.date() for item in published)
minutes = (
    int((now - max(published)).total_seconds() // 60)
    if published
    else 99999
)
print(count_today, minutes)
PY
  )
  if [ "$RELEASES_TODAY" -ge "${CADENCE_LIMIT:-3}" ] ||
     [ "$MINUTES_SINCE_LAST" -lt "${CADENCE_MIN_GAP_MIN:-20}" ]; then
    echo "release cadence guard blocked this dispatch" >&2
    echo "set ALLOW_RAPID_RELEASE=1 only for a deliberate urgent release" >&2
    exit 2
  fi
fi

GH_TOKEN="$TOKEN" gh workflow run release.yml \
  --repo "$REPOSITORY" \
  --ref main \
  --field "version=$VERSION" \
  --field "release_sha=$SOURCE_SHA" \
  --field "publish_homebrew=$PUBLISH_HOMEBREW"

echo "Dispatched the protected production release for v${VERSION} at ${SOURCE_SHA}."
