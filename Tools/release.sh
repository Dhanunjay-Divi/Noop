#!/usr/bin/env bash
#
# Build the canonical production release from an exact reviewed main commit,
# wait for that exact hosted run, then publish its verified draft with the
# owner-authenticated token that can inspect repository release policy.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPOSITORY="${NOOP_RELEASE_GITHUB_REPO:-Dhanunjay-Divi/Noop}"
VERSION="${1:-}"
PUBLISH_HOMEBREW=false
PUBLISH_HOMEBREW_FORGEJO=false
PUBLISH_FORGEJO=false

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
case "${NOOP_HOMEBREW_FORGE:-0}" in
  0 | "")
    ;;
  1)
    if [ "$PUBLISH_HOMEBREW" != "true" ]; then
      echo "NOOP_HOMEBREW_FORGE=1 requires NOOP_RELEASE_HOMEBREW=1" >&2
      exit 2
    fi
    PUBLISH_HOMEBREW_FORGEJO=true
    ;;
  *)
    echo "NOOP_HOMEBREW_FORGE must be 0 or 1" >&2
    exit 2
    ;;
esac
case "${NOOP_RELEASE_FORGE:-0}" in
  0 | "")
    ;;
  1)
    PUBLISH_FORGEJO=true
    ;;
  *)
    echo "NOOP_RELEASE_FORGE must be 0 or 1" >&2
    exit 2
    ;;
esac

command -v gh >/dev/null 2>&1 || {
  echo "gh CLI is required" >&2
  exit 1
}
cd "$ROOT"
TEMP_DIR="$(mktemp -d)"
SOURCE_TREE=""
cleanup() {
  if [ -n "$SOURCE_TREE" ] && [ -e "$SOURCE_TREE/.git" ]; then
    git -C "$ROOT" worktree remove --force "$SOURCE_TREE" >/dev/null 2>&1 || true
  fi
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

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
SOURCE_TREE="$TEMP_DIR/reviewed-source"
git worktree add --quiet --detach "$SOURCE_TREE" "$SOURCE_SHA"
test "$(git -C "$SOURCE_TREE" rev-parse HEAD)" = "$SOURCE_SHA"

ANDROID_VERSION="$(
  sed -n 's/.*versionName = "\([^"]*\)".*/\1/p' \
    "$SOURCE_TREE/android/app/build.gradle.kts" | head -1
)"
APPLE_VERSION="$(
  sed -n 's/.*MARKETING_VERSION: "\([^"]*\)".*/\1/p' \
    "$SOURCE_TREE/project.yml" | head -1
)"
if [ "$ANDROID_VERSION" != "$VERSION" ] || [ "$APPLE_VERSION" != "$VERSION" ]; then
  echo "requested version does not match reviewed Apple and Android source" >&2
  exit 1
fi

python3 "$SOURCE_TREE/Tools/release-control-gate.py" check
python3 "$SOURCE_TREE/Tools/required-ci-gate.py" \
  --config "$SOURCE_TREE/release/required-ci.json" \
  check --root "$SOURCE_TREE"
TOKEN="${GH_TOKEN:-$(gh auth token)}"
GH_TOKEN="$TOKEN" python3 "$SOURCE_TREE/Tools/github-release-publish.py" \
  --repository "$REPOSITORY" \
  --check-policy-only \
  --protected-main-sha "$SOURCE_SHA"
GH_TOKEN="$TOKEN" python3 "$SOURCE_TREE/Tools/required-ci-gate.py" \
  --config "$SOURCE_TREE/release/required-ci.json" \
  verify-github \
  --repository "$REPOSITORY" \
  --sha "$SOURCE_SHA"

if [ "${ALLOW_RAPID_RELEASE:-0}" != "1" ]; then
  RELEASES="$TEMP_DIR/releases.json"
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

RUN_TITLE="NOOP release candidate v${VERSION} @ ${SOURCE_SHA}"
DISPATCH_STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
GH_TOKEN="$TOKEN" gh workflow run release.yml \
  --repo "$REPOSITORY" \
  --ref main \
  --field "version=$VERSION" \
  --field "release_sha=$SOURCE_SHA"

RUN_ID=""
RUNS="$TEMP_DIR/runs.json"
for _ in {1..30}; do
  GH_TOKEN="$TOKEN" gh api \
    "repos/${REPOSITORY}/actions/workflows/release.yml/runs?event=workflow_dispatch&branch=main&per_page=30" \
    > "$RUNS"
  MATCH_LINE="$(
    python3 - "$RUNS" "$RUN_TITLE" "$SOURCE_SHA" "$DISPATCH_STARTED" <<'PY'
import datetime as dt
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
title, sha, started_text = sys.argv[2:]
started = dt.datetime.fromisoformat(started_text.replace("Z", "+00:00"))
matches = []
for run in payload.get("workflow_runs", []):
    created_text = run.get("created_at")
    try:
        created = dt.datetime.fromisoformat(
            created_text.replace("Z", "+00:00")
        )
    except (AttributeError, ValueError):
        continue
    if (
        run.get("display_title") == title
        and run.get("head_sha") == sha
        and run.get("head_branch") == "main"
        and run.get("event") == "workflow_dispatch"
        and run.get("path") == ".github/workflows/release.yml"
        and created >= started
        and isinstance(run.get("id"), int)
    ):
        matches.append(run["id"])
print(len(matches), matches[0] if len(matches) == 1 else "")
PY
  )"
  read -r MATCH_COUNT MATCH_ID <<<"$MATCH_LINE"
  if [ "$MATCH_COUNT" -gt 1 ]; then
    echo "multiple matching release runs appeared; refusing ambiguous publication" >&2
    exit 1
  fi
  if [ "$MATCH_COUNT" -eq 1 ]; then
    RUN_ID="$MATCH_ID"
    break
  fi
  sleep 2
done
if [ -z "$RUN_ID" ]; then
  echo "the dispatched release run did not become visible in time" >&2
  exit 1
fi

GH_TOKEN="$TOKEN" gh run watch "$RUN_ID" \
  --repo "$REPOSITORY" --exit-status --interval 10
RUN="$TEMP_DIR/run.json"
GH_TOKEN="$TOKEN" gh api \
  "repos/${REPOSITORY}/actions/runs/${RUN_ID}" > "$RUN"
RUN_ATTEMPT="$(
  python3 - "$RUN" "$RUN_ID" "$RUN_TITLE" "$SOURCE_SHA" "$REPOSITORY" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    run = json.load(handle)
run_id = int(sys.argv[2])
title, sha, repository = sys.argv[3:]
if not (
    run.get("id") == run_id
    and run.get("display_title") == title
    and run.get("head_sha") == sha
    and run.get("head_branch") == "main"
    and run.get("head_repository", {}).get("full_name") == repository
    and run.get("event") == "workflow_dispatch"
    and run.get("path") == ".github/workflows/release.yml"
    and run.get("status") == "completed"
    and run.get("conclusion") == "success"
    and isinstance(run.get("run_attempt"), int)
    and run["run_attempt"] > 0
    and re.fullmatch(r"[0-9a-f]{40}", sha)
):
    raise SystemExit("release workflow identity or result is invalid")
print(run["run_attempt"])
PY
)"

git fetch --quiet origin main --tags
LATEST_MAIN="$(git rev-parse origin/main)"
if [ "$LATEST_MAIN" != "$SOURCE_SHA" ]; then
  echo "protected main advanced after the release build; review and rebuild the latest commit" >&2
  exit 1
fi
test "$(git -C "$SOURCE_TREE" rev-parse HEAD)" = "$SOURCE_SHA"
python3 "$SOURCE_TREE/Tools/required-ci-gate.py" \
  --config "$SOURCE_TREE/release/required-ci.json" \
  check --root "$SOURCE_TREE"
GH_TOKEN="$TOKEN" python3 "$SOURCE_TREE/Tools/github-release-publish.py" \
  --repository "$REPOSITORY" \
  --check-policy-only \
  --protected-main-sha "$SOURCE_SHA"
GH_TOKEN="$TOKEN" python3 "$SOURCE_TREE/Tools/required-ci-gate.py" \
  --config "$SOURCE_TREE/release/required-ci.json" \
  verify-github \
  --repository "$REPOSITORY" \
  --sha "$SOURCE_SHA"
MANIFEST_DIR="$TEMP_DIR/candidate-manifest"
mkdir -p "$MANIFEST_DIR"
GH_TOKEN="$TOKEN" gh run download "$RUN_ID" \
  --repo "$REPOSITORY" \
  --name "production-release-candidate-${RUN_ID}-${RUN_ATTEMPT}" \
  --dir "$MANIFEST_DIR"
MANIFEST="$MANIFEST_DIR/release-candidate.json"
if [ ! -f "$MANIFEST" ] || [ -L "$MANIFEST" ]; then
  echo "the exact release candidate manifest is unavailable" >&2
  exit 1
fi
GH_TOKEN="$TOKEN" python3 "$SOURCE_TREE/Tools/github-release-publish.py" \
  --repository "$REPOSITORY" \
  --tag "v${VERSION}" \
  --version "$VERSION" \
  --expected-sha "$SOURCE_SHA" \
  --manifest "$MANIFEST" \
  --run-id "$RUN_ID" \
  --run-attempt "$RUN_ATTEMPT" \
  --protected-main-sha "$SOURCE_SHA"

if [ "$PUBLISH_HOMEBREW" = "true" ]; then
  GH_TOKEN="$TOKEN" gh workflow run homebrew-cask.yml \
    --repo "$REPOSITORY" \
    --ref main \
    --field "version=$VERSION" \
    --field "publish_forgejo=$PUBLISH_HOMEBREW_FORGEJO"
fi
if [ "$PUBLISH_FORGEJO" = "true" ]; then
  GH_TOKEN="$TOKEN" gh workflow run forgejo-release.yml \
    --repo "$REPOSITORY" \
    --ref main \
    --field "version=$VERSION"
fi

echo "Published immutable production release v${VERSION} from ${SOURCE_SHA}."
