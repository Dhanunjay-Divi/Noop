#!/usr/bin/env bash
#
# Publish one verified testing-build draft after proving the run and attempt
# encoded in its tag completed successfully.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPOSITORY="${NOOP_RELEASE_GITHUB_REPO:-Dhanunjay-Divi/Noop}"
TAG="${1:-}"
VERSION="${2:-}"

if [ "$#" -ne 2 ] ||
   [[ ! "$TAG" =~ ^testing-snapshot-([0-9]+)-([0-9]+)$ ]]; then
  echo "usage: Tools/publish-testing-snapshot.sh testing-snapshot-<run>-<attempt> <version>" >&2
  exit 2
fi
RUN_ID="${BASH_REMATCH[1]}"
RUN_ATTEMPT="${BASH_REMATCH[2]}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: Tools/publish-testing-snapshot.sh testing-snapshot-<run>-<attempt> <version>" >&2
  exit 2
fi

command -v gh >/dev/null 2>&1 || {
  echo "gh CLI is required" >&2
  exit 1
}
cd "$ROOT"
BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
if [ "$BRANCH" != "main" ]; then
  echo "testing publication requires the local main branch" >&2
  exit 1
fi
if [ -n "$(git status --porcelain=v1 --untracked-files=normal)" ] ||
   ! git diff --quiet ||
   ! git diff --cached --quiet; then
  echo "testing publication requires a clean worktree" >&2
  exit 1
fi
git fetch --quiet origin main --tags
TRUSTED_SHA="$(git rev-parse HEAD)"
if [ "$TRUSTED_SHA" != "$(git rev-parse origin/main)" ]; then
  echo "local main must exactly match origin/main" >&2
  exit 1
fi

TEMP_DIR="$(mktemp -d)"
SOURCE_TREE="$TEMP_DIR/trusted-source"
cleanup() {
  if [ -e "$SOURCE_TREE/.git" ]; then
    git -C "$ROOT" worktree remove --force "$SOURCE_TREE" >/dev/null 2>&1 || true
  fi
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT
git worktree add --quiet --detach "$SOURCE_TREE" "$TRUSTED_SHA"
test "$(git -C "$SOURCE_TREE" rev-parse HEAD)" = "$TRUSTED_SHA"
python3 "$SOURCE_TREE/Tools/release-control-gate.py" check
python3 "$SOURCE_TREE/Tools/required-ci-gate.py" \
  --config "$SOURCE_TREE/release/required-ci.json" \
  check --root "$SOURCE_TREE"

TOKEN="${GH_TOKEN:-$(gh auth token)}"
GH_TOKEN="$TOKEN" python3 "$SOURCE_TREE/Tools/required-ci-gate.py" \
  --config "$SOURCE_TREE/release/required-ci.json" \
  verify-github \
  --repository "$REPOSITORY" \
  --sha "$TRUSTED_SHA"
RUN_FILE="$TEMP_DIR/run.json"
GH_TOKEN="$TOKEN" gh api \
  "repos/${REPOSITORY}/actions/runs/${RUN_ID}/attempts/${RUN_ATTEMPT}" \
  > "$RUN_FILE"
SOURCE_SHA="$(
  python3 - "$RUN_FILE" "$RUN_ID" "$RUN_ATTEMPT" "$REPOSITORY" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    run = json.load(handle)
run_id = int(sys.argv[2])
attempt = int(sys.argv[3])
repository = sys.argv[4]
sha = run.get("head_sha")
if not (
    run.get("id") == run_id
    and run.get("run_attempt") == attempt
    and run.get("head_repository", {}).get("full_name") == repository
    and run.get("head_branch") == "main"
    and run.get("event") == "workflow_dispatch"
    and run.get("path") == ".github/workflows/testing-build.yml"
    and run.get("display_title") == f"NOOP testing candidate @ {sha}"
    and run.get("status") == "completed"
    and run.get("conclusion") == "success"
    and isinstance(sha, str)
    and re.fullmatch(r"[0-9a-f]{40}", sha)
):
    raise SystemExit("testing workflow identity or result is invalid")
print(sha)
PY
)"
if [ "$SOURCE_SHA" != "$TRUSTED_SHA" ]; then
  echo "testing publication requires the exact current protected-main source" >&2
  exit 1
fi

MANIFEST_DIR="$TEMP_DIR/candidate-manifest"
mkdir -p "$MANIFEST_DIR"
GH_TOKEN="$TOKEN" gh run download "$RUN_ID" \
  --repo "$REPOSITORY" \
  --name "testing-release-candidate-${RUN_ID}-${RUN_ATTEMPT}" \
  --dir "$MANIFEST_DIR"
MANIFEST="$MANIFEST_DIR/testing-release-candidate.json"
if [ ! -f "$MANIFEST" ] || [ -L "$MANIFEST" ]; then
  echo "the exact testing candidate manifest is unavailable" >&2
  exit 1
fi
git fetch --quiet origin main --tags
if [ "$(git rev-parse origin/main)" != "$TRUSTED_SHA" ]; then
  echo "protected main advanced; rerun with the latest reviewed publisher" >&2
  exit 1
fi
test "$(git -C "$SOURCE_TREE" rev-parse HEAD)" = "$TRUSTED_SHA"
python3 "$SOURCE_TREE/Tools/required-ci-gate.py" \
  --config "$SOURCE_TREE/release/required-ci.json" \
  check --root "$SOURCE_TREE"
GH_TOKEN="$TOKEN" python3 "$SOURCE_TREE/Tools/required-ci-gate.py" \
  --config "$SOURCE_TREE/release/required-ci.json" \
  verify-github \
  --repository "$REPOSITORY" \
  --sha "$TRUSTED_SHA"
GH_TOKEN="$TOKEN" python3 "$SOURCE_TREE/Tools/github-release-publish.py" \
  --repository "$REPOSITORY" \
  --check-policy-only \
  --testing-snapshot \
  --protected-main-sha "$TRUSTED_SHA"
GH_TOKEN="$TOKEN" python3 "$SOURCE_TREE/Tools/github-release-publish.py" \
  --repository "$REPOSITORY" \
  --tag "$TAG" \
  --version "$VERSION" \
  --expected-sha "$SOURCE_SHA" \
  --testing-snapshot \
  --manifest "$MANIFEST" \
  --run-id "$RUN_ID" \
  --run-attempt "$RUN_ATTEMPT" \
  --protected-main-sha "$TRUSTED_SHA"

echo "Published immutable testing snapshot $TAG from $SOURCE_SHA."
