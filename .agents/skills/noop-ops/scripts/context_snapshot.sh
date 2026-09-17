#!/usr/bin/env bash
set -euo pipefail

root="${1:-}"
if [[ -z "$root" ]]; then
  root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi
if [[ -z "$root" || ! -d "$root/.git" && ! -f "$root/.git" ]]; then
  echo "usage: context_snapshot.sh [noop-repo-root]" >&2
  exit 2
fi
root="$(cd "$root" && pwd -P)"

cd "$root"

echo "NOOP context snapshot"
echo "generated_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "repo=$(basename "$root")"
echo

echo "[branch]"
git status --short --branch
echo

echo "[worktrees]"
git worktree list
echo

echo "[recent commits]"
git log --oneline -8
echo

echo "[active operations record]"
if [[ -f docs/ops/ACTIVE.md ]]; then
  sed -n '1,120p' docs/ops/ACTIVE.md
else
  echo "missing docs/ops/ACTIVE.md"
fi
echo

echo "[newest round records]"
if [[ -d docs/ops/rounds ]]; then
  find docs/ops/rounds -maxdepth 1 -type f -name '*.md' \
    -exec basename {} \; | sort -r | head -8
else
  echo "missing docs/ops/rounds"
fi
echo

echo "[toolchain]"
printf 'xcode='
xcodebuild -version 2>/dev/null | paste -sd ' ' - || echo "unavailable"
printf 'java='
java -version 2>&1 | head -1 || echo "unavailable"
printf 'python='
python3 --version 2>/dev/null || echo "unavailable"
