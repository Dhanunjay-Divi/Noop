#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# forgejo-release.sh — cut a release on the self-hosted forge (replaces `gh release create`).
# Run from your Mac at release time, after the anonymized binaries are built.
#
#   release/forgejo-release.sh <version> <asset> [<asset> ...] [-- "release notes"]
#   e.g. Tools/forgejo-release.sh 4.7.0 \
#          dist/NOOP-macos-v4.7.0.zip dist/NOOP-ios-unsigned-v4.7.0.ipa \
#          dist/NOOP-android-v4.7.0.apk
#
# Creates tag v<version> (server-side, from the current default branch) + a draft,
# uploads and verifies every asset, then publishes. Token from
# ~/.config/noop/forge_token. Idempotent on assets.
# FORGE_DOMAIN/FORGE_ORG/FORGE_REPO must be supplied explicitly. There are no
# historical-upstream defaults, so running this script from a fork cannot publish
# to somebody else's forge by accident. No secret appears on any command line.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DOMAIN="${FORGE_DOMAIN:-}"
ORG="${FORGE_ORG:-}"
REPO="${FORGE_REPO:-}"
[ -n "$DOMAIN" ] && [ -n "$ORG" ] && [ -n "$REPO" ] || {
  echo "set FORGE_DOMAIN, FORGE_ORG, and FORGE_REPO explicitly" >&2
  exit 1
}

VER="${1:?usage: forgejo-release.sh <version> <asset...> [-- notes]}"; shift
TAG="v$VER"; NOTES="NOOP $TAG — see CHANGELOG.md."
ASSETS=()
while [ $# -gt 0 ]; do
  if [ "$1" = "--" ]; then shift; NOTES="${1:-$NOTES}"; break; fi
  ASSETS+=("$1"); shift
done

[ "${#ASSETS[@]}" -gt 0 ] || {
  echo "at least one release asset is required" >&2
  exit 1
}
for f in "${ASSETS[@]}"; do
  [ -f "$f" ] || {
    echo "missing asset: $f" >&2
    exit 1
  }
done

TOKEN_FILE="$HOME/.config/noop/forge_token"
[ -f "$TOKEN_FILE" ] || { echo "missing $TOKEN_FILE" >&2; exit 1; }
TOKEN="$(cat "$TOKEN_FILE")"
API="https://$DOMAIN/api/v1"
api(){ curl -fsS -H "Authorization: token $TOKEN" -H 'Content-Type: application/json' "$@"; }

echo "→ release $TAG on $ORG/$REPO ($DOMAIN)"
REL_JSON="$(api "$API/repos/$ORG/$REPO/releases/tags/$TAG" 2>/dev/null || true)"
REL_ID="$(printf '%s' "$REL_JSON" | jq -r '.id // empty')"
if [ -z "$REL_ID" ]; then
  REL_ID="$(api -X POST "$API/repos/$ORG/$REPO/releases" \
    -d "$(jq -n --arg t "$TAG" --arg n "NOOP $TAG" --arg b "$NOTES" \
          '{tag_name:$t,name:$n,body:$b,draft:true,prerelease:false}')" | jq -r '.id')"
  echo "  created draft release id=$REL_ID"
else
  echo "  release exists id=$REL_ID — returning it to draft while assets refresh"
  api -X PATCH "$API/repos/$ORG/$REPO/releases/$REL_ID" \
    -d "$(jq -n --arg n "NOOP $TAG" --arg b "$NOTES" \
          '{name:$n,body:$b,draft:true,prerelease:false}')" >/dev/null
fi

for f in "${ASSETS[@]}"; do
  name="$(basename "$f")"
  existing="$(api "$API/repos/$ORG/$REPO/releases/$REL_ID/assets" | jq -r --arg n "$name" '.[]|select(.name==$n).id')"
  [ -n "$existing" ] && api -X DELETE "$API/repos/$ORG/$REPO/releases/$REL_ID/assets/$existing" >/dev/null
  curl -fsS -H "Authorization: token $TOKEN" \
       -F "attachment=@$f;type=application/octet-stream" \
       "$API/repos/$ORG/$REPO/releases/$REL_ID/assets?name=$name" >/dev/null
  echo "  ↑ $name"
done

REMOTE_ASSETS="$(api "$API/repos/$ORG/$REPO/releases/$REL_ID/assets" | jq -r '.[].name')"
for f in "${ASSETS[@]}"; do
  expected="$(basename "$f")"
  grep -Fxq "$expected" <<<"$REMOTE_ASSETS" || {
    echo "uploaded release is missing $expected; release remains draft" >&2
    exit 1
  }
done

api -X PATCH "$API/repos/$ORG/$REPO/releases/$REL_ID" \
  -d '{"draft":false,"prerelease":false}' >/dev/null
echo "✓ $TAG published: https://$DOMAIN/$ORG/$REPO/releases/tag/$TAG"
