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
# Creates tag v<version> at FORGE_TARGET_COMMITISH plus a draft, uploads and
# verifies every asset, then publishes. Token comes from NOOP_FORGEJO_TOKEN in
# automation or ~/.config/noop/forge_token for a deliberate local run.
# Idempotent on assets.
# FORGE_DOMAIN/FORGE_ORG/FORGE_REPO must be supplied explicitly. There are no
# historical-upstream defaults, so running this script from a fork cannot publish
# to somebody else's forge by accident. No secret appears on any command line.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOMAIN="${FORGE_DOMAIN:-}"
ORG="${FORGE_ORG:-}"
REPO="${FORGE_REPO:-}"
TARGET_COMMITISH="${FORGE_TARGET_COMMITISH:-}"
[ -n "$DOMAIN" ] && [ -n "$ORG" ] && [ -n "$REPO" ] || {
  echo "set FORGE_DOMAIN, FORGE_ORG, and FORGE_REPO explicitly" >&2
  exit 1
}

VER="${1:?usage: forgejo-release.sh <version> <asset...> [-- notes]}"; shift
TAG="v$VER"; NOTES="NOOP $TAG — see CHANGELOG.md."
SAFE_DOMAIN='^[A-Za-z0-9][A-Za-z0-9.-]*([:][0-9]{1,5})?$'
SAFE_COMPONENT='^[A-Za-z0-9][A-Za-z0-9_.-]*$'
[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "invalid Forgejo release version" >&2
  exit 2
}
[[ "$DOMAIN" =~ $SAFE_DOMAIN ]] &&
  [[ "$ORG" =~ $SAFE_COMPONENT ]] &&
  [[ "$REPO" =~ $SAFE_COMPONENT ]] || {
  echo "invalid Forgejo repository coordinate" >&2
  exit 2
}
[[ "$TARGET_COMMITISH" =~ ^[0-9a-f]{40}$ ]] || {
  echo "FORGE_TARGET_COMMITISH must be an exact lowercase commit SHA" >&2
  exit 2
}
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
if [ -n "${NOOP_FORGEJO_TOKEN:-}" ]; then
  TOKEN="$NOOP_FORGEJO_TOKEN"
elif [ -f "$TOKEN_FILE" ]; then
  TOKEN="$(cat "$TOKEN_FILE")"
else
  echo "missing Forgejo release token" >&2
  exit 1
fi
[[ "$TOKEN" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "invalid Forgejo release token format" >&2
  exit 2
}
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

AUTH_CONFIG="$(mktemp)"
REL_JSON_FILE="$(mktemp)"
trap 'rm -f "$AUTH_CONFIG" "$REL_JSON_FILE"' EXIT
chmod 600 "$AUTH_CONFIG"
printf 'header = "Authorization: token %s"\n' "$TOKEN" > "$AUTH_CONFIG"
unset TOKEN NOOP_FORGEJO_TOKEN

API="https://$DOMAIN/api/v1"
api(){
  curl --config "$AUTH_CONFIG" --connect-timeout 10 --max-time 30 -fsS \
    -H 'Content-Type: application/json' "$@"
}

RELEASE_HISTORY='[]'
for page in $(seq 1 10); do
  PAGE_JSON="$(api \
    "$API/repos/$ORG/$REPO/releases?limit=50&page=$page")"
  PAGE_COUNT="$(jq -er 'if type == "array" then length else error("invalid") end' \
    <<<"$PAGE_JSON")" || {
    echo "Forgejo release history response is invalid" >&2
    exit 1
  }
  RELEASE_HISTORY="$(
    jq -cn --argjson history "$RELEASE_HISTORY" --argjson page "$PAGE_JSON" \
      '$history + $page'
  )"
  if [ "$PAGE_COUNT" -lt 50 ]; then
    break
  fi
  if [ "$page" -eq 10 ]; then
    echo "Forgejo release history exceeded the bounded page limit" >&2
    exit 1
  fi
done
printf '%s' "$RELEASE_HISTORY" |
  python3 "$ROOT/Tools/forgejo-version-gate.py" --target "$VER"

echo "→ mirror verified release $TAG"
REL_STATUS="$(
  curl --config "$AUTH_CONFIG" --connect-timeout 10 --max-time 30 \
    --silent --show-error --output "$REL_JSON_FILE" --write-out '%{http_code}' \
    "$API/repos/$ORG/$REPO/releases/tags/$TAG"
)" || {
  echo "Forgejo release lookup failed" >&2
  exit 1
}
case "$REL_STATUS" in
  200)
    REL_JSON="$(cat "$REL_JSON_FILE")"
    ;;
  404)
    REL_JSON='{}'
    ;;
  *)
    echo "Forgejo release lookup returned an unexpected status" >&2
    exit 1
    ;;
esac
REL_ID="$(printf '%s' "$REL_JSON" | jq -r '.id // empty')"
if [ -z "$REL_ID" ]; then
  REL_ID="$(api -X POST "$API/repos/$ORG/$REPO/releases" \
    -d "$(jq -n --arg t "$TAG" --arg n "NOOP $TAG" --arg b "$NOTES" \
          --arg c "$TARGET_COMMITISH" \
          '{tag_name:$t,target_commitish:$c,name:$n,body:$b,draft:true,prerelease:false}')" | jq -r '.id')"
  echo "  created draft release"
else
  REMOTE_TARGET="$(printf '%s' "$REL_JSON" | jq -r '.target_commitish // empty')"
  [ "$REMOTE_TARGET" = "$TARGET_COMMITISH" ] || {
    echo "existing Forgejo release does not target the verified commit" >&2
    exit 1
  }
  echo "  release exists — returning it to draft while assets refresh"
  api -X PATCH "$API/repos/$ORG/$REPO/releases/$REL_ID" \
    -d "$(jq -n --arg n "NOOP $TAG" --arg b "$NOTES" \
          '{name:$n,body:$b,draft:true,prerelease:false}')" >/dev/null
fi

for f in "${ASSETS[@]}"; do
  name="$(basename "$f")"
  existing="$(api "$API/repos/$ORG/$REPO/releases/$REL_ID/assets" | jq -r --arg n "$name" '.[]|select(.name==$n).id')"
  [ -n "$existing" ] && api -X DELETE "$API/repos/$ORG/$REPO/releases/$REL_ID/assets/$existing" >/dev/null
  curl --config "$AUTH_CONFIG" -fsS \
       -F "attachment=@$f;type=application/octet-stream" \
       "$API/repos/$ORG/$REPO/releases/$REL_ID/assets?name=$name" >/dev/null
  echo "  ↑ $name"
done

REMOTE_ASSETS="$(api "$API/repos/$ORG/$REPO/releases/$REL_ID/assets")"
for f in "${ASSETS[@]}"; do
  expected="$(basename "$f")"
  count="$(jq --arg n "$expected" '[.[] | select(.name == $n)] | length' <<<"$REMOTE_ASSETS")"
  [ "$count" = "1" ] || {
    echo "uploaded release is missing $expected; release remains draft" >&2
    exit 1
  }
  remote_size="$(jq -r --arg n "$expected" '.[] | select(.name == $n) | .size' <<<"$REMOTE_ASSETS")"
  local_size="$(wc -c < "$f" | tr -d '[:space:]')"
  [ "$remote_size" = "$local_size" ] || {
    echo "uploaded release has an invalid $expected size; release remains draft" >&2
    exit 1
  }
done

api -X PATCH "$API/repos/$ORG/$REPO/releases/$REL_ID" \
  -d '{"draft":false,"prerelease":false}' >/dev/null
echo "✓ $TAG published: https://$DOMAIN/$ORG/$REPO/releases/tag/$TAG"
