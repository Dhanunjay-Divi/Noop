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
  [[ "$(basename "$f")" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
    echo "invalid Forgejo release asset name" >&2
    exit 2
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
command -v cmp >/dev/null 2>&1 || { echo "cmp is required" >&2; exit 1; }

AUTH_CONFIG="$(mktemp)"
REL_JSON_FILE="$(mktemp)"
VERIFY_FILE="$(mktemp)"
trap 'rm -f "$AUTH_CONFIG" "$REL_JSON_FILE" "$VERIFY_FILE"' EXIT
chmod 600 "$AUTH_CONFIG"
printf 'header = "Authorization: token %s"\n' "$TOKEN" > "$AUTH_CONFIG"
unset TOKEN NOOP_FORGEJO_TOKEN

API="https://$DOMAIN/api/v1"
api(){
  curl --config "$AUTH_CONFIG" --connect-timeout 10 --max-time 30 \
    --max-filesize 10485760 -fsS \
    -H 'Content-Type: application/json' "$@"
}

fetch_release_history(){
  local filter page page_json page_count releases
  filter="$1"
  releases='[]'
  for page in $(seq 1 10); do
    page_json="$(api \
      "$API/repos/$ORG/$REPO/releases?limit=50&page=$page$filter")"
    page_count="$(
      jq -er 'if type == "array" then length else error("invalid") end' \
        <<<"$page_json"
    )" || {
      echo "Forgejo release history response is invalid" >&2
      return 1
    }
    releases="$(
      jq -cn --argjson releases "$releases" --argjson page "$page_json" \
        '$releases + $page'
    )"
    if [ "$page_count" -lt 50 ]; then
      break
    fi
    if [ "$page" -eq 10 ]; then
      echo "Forgejo release history exceeded the bounded page limit" >&2
      return 1
    fi
  done
  printf '%s' "$releases"
}

fetch_assets(){
  local assets
  assets="$(api "$API/repos/$ORG/$REPO/releases/$REL_ID/assets")"
  jq -e 'type == "array"' <<<"$assets" >/dev/null || {
    echo "Forgejo release assets response is invalid" >&2
    return 1
  }
  printf '%s' "$assets"
}

normalize_assets(){
  jq -cer --arg download_root \
    "https://$DOMAIN/$ORG/$REPO/releases/download/$TAG/" '
    if type == "array" and
       all(.[];
         (.id | type == "number") and
         (.name | type == "string") and
         (.size | type == "number") and
         (.size >= 0) and
         (.type == "attachment") and
         (.browser_download_url == ($download_root + .name)))
    then [.[] | {name, size}] | sort_by(.name)
    else error("invalid release assets")
    end
  ' <<<"$1"
}

verify_remote_payloads(){
  local f name download_url
  for f in "${ASSETS[@]}"; do
    name="$(basename "$f")"
    download_url="https://$DOMAIN/$ORG/$REPO/releases/download/$TAG/$name"
    if ! curl --config "$AUTH_CONFIG" --connect-timeout 10 --max-time 600 \
      --location -fsS --output "$VERIFY_FILE" "$download_url"; then
      echo "Forgejo asset verification download failed" >&2
      return 2
    fi
    if ! cmp -s "$f" "$VERIFY_FILE"; then
      echo "Forgejo asset payload does not match $name" >&2
      return 1
    fi
  done
}

EXPECTED_ASSETS='[]'
for f in "${ASSETS[@]}"; do
  name="$(basename "$f")"
  local_size="$(wc -c < "$f" | tr -d '[:space:]')"
  EXPECTED_ASSETS="$(
    jq -cn --argjson assets "$EXPECTED_ASSETS" --arg name "$name" \
      --argjson size "$local_size" \
      '$assets + [{name:$name,size:$size}] | sort_by(.name)'
  )"
done
EXPECTED_COUNT="$(jq -r 'length' <<<"$EXPECTED_ASSETS")"
UNIQUE_EXPECTED_COUNT="$(
  jq -r '[.[].name] | unique | length' <<<"$EXPECTED_ASSETS"
)"
[ "$EXPECTED_COUNT" = "$UNIQUE_EXPECTED_COUNT" ] || {
  echo "Forgejo release asset names must be unique" >&2
  exit 2
}

PUBLISHED_HISTORY="$(fetch_release_history '')"
DRAFT_HISTORY="$(fetch_release_history '&draft=true')"
RELEASE_HISTORY="$(
  jq -cen --argjson published "$PUBLISHED_HISTORY" --argjson drafts "$DRAFT_HISTORY" '
    ($published + $drafts)
    | if all(.[]; .id | type == "number") then unique_by(.id)
      else error("invalid release identifiers")
      end
  '
)" || {
  echo "Forgejo release history response is invalid" >&2
  exit 1
}
printf '%s' "$RELEASE_HISTORY" |
  python3 "$ROOT/Tools/forgejo-version-gate.py" --target "$VER"

return_release_to_draft(){
  local draft_release
  draft_release="$(api -X PATCH "$API/repos/$ORG/$REPO/releases/$REL_ID" \
    -d "$(jq -n --arg n "NOOP $TAG" --arg b "$NOTES" \
          '{name:$n,body:$b,draft:true,prerelease:false}')")"
  jq -e --arg tag "$TAG" --arg target "$TARGET_COMMITISH" \
    --arg name "NOOP $TAG" --arg body "$NOTES" '
      .draft == true and
      .prerelease == false and
      .tag_name == $tag and
      .target_commitish == $target and
      .name == $name and
      .body == $body
    ' <<<"$draft_release" >/dev/null || {
    echo "Forgejo did not return the verified release to draft" >&2
    return 1
  }
}

echo "→ mirror verified release $TAG"
HISTORY_TAG_COUNT="$(
  jq -r --arg tag "$TAG" '[.[] | select(.tag_name == $tag)] | length' \
    <<<"$RELEASE_HISTORY"
)"
[ "$HISTORY_TAG_COUNT" -le 1 ] || {
  echo "Forgejo release history contains duplicate target tags" >&2
  exit 1
}
if [ "$HISTORY_TAG_COUNT" = "1" ]; then
  REL_JSON="$(
    jq -c --arg tag "$TAG" '.[] | select(.tag_name == $tag)' \
      <<<"$RELEASE_HISTORY"
  )"
else
  REL_STATUS="$(
    curl --config "$AUTH_CONFIG" --connect-timeout 10 --max-time 30 \
      --max-filesize 10485760 \
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
fi
REL_ID="$(printf '%s' "$REL_JSON" | jq -r '.id // empty')"
NEEDS_ASSET_REFRESH=1
if [ -z "$REL_ID" ]; then
  CREATED_RELEASE="$(api -X POST "$API/repos/$ORG/$REPO/releases" \
    -d "$(jq -n --arg t "$TAG" --arg n "NOOP $TAG" --arg b "$NOTES" \
          --arg c "$TARGET_COMMITISH" \
          '{tag_name:$t,target_commitish:$c,name:$n,body:$b,draft:true,prerelease:false}')")"
  REL_ID="$(jq -er '.id | select(type == "number" and . > 0)' \
    <<<"$CREATED_RELEASE")" || {
    echo "Forgejo did not return a valid release identifier" >&2
    exit 1
  }
  jq -e --arg tag "$TAG" --arg target "$TARGET_COMMITISH" '
    .tag_name == $tag and
    .target_commitish == $target and
    .draft == true and
    .prerelease == false
  ' <<<"$CREATED_RELEASE" >/dev/null || {
    echo "Forgejo created a release with an invalid identity" >&2
    exit 1
  }
  echo "  created draft release"
else
  [[ "$REL_ID" =~ ^[1-9][0-9]*$ ]] || {
    echo "existing Forgejo release has an invalid identifier" >&2
    exit 1
  }
  [ "$(jq -r '.tag_name // empty' <<<"$REL_JSON")" = "$TAG" ] || {
    echo "existing Forgejo release has an invalid tag identity" >&2
    exit 1
  }
  REMOTE_TARGET="$(printf '%s' "$REL_JSON" | jq -r '.target_commitish // empty')"
  [ "$REMOTE_TARGET" = "$TARGET_COMMITISH" ] || {
    echo "existing Forgejo release does not target the verified commit" >&2
    exit 1
  }
  jq -e '.draft | type == "boolean"' <<<"$REL_JSON" >/dev/null || {
    echo "existing Forgejo release has an invalid draft state" >&2
    exit 1
  }
  REMOTE_DRAFT="$(jq -r '.draft' <<<"$REL_JSON")"
  jq -e '.prerelease | type == "boolean"' <<<"$REL_JSON" >/dev/null || {
    echo "existing Forgejo release has an invalid prerelease state" >&2
    exit 1
  }
  REMOTE_PRERELEASE="$(jq -r '.prerelease' <<<"$REL_JSON")"
  jq -e '.name | type == "string"' <<<"$REL_JSON" >/dev/null || {
    echo "existing Forgejo release has an invalid name" >&2
    exit 1
  }
  REMOTE_NAME="$(jq -r '.name' <<<"$REL_JSON")"
  jq -e '.body | type == "string"' <<<"$REL_JSON" >/dev/null || {
    echo "existing Forgejo release has invalid notes" >&2
    exit 1
  }
  REMOTE_BODY="$(jq -r '.body' <<<"$REL_JSON")"
  REMOTE_ASSETS="$(fetch_assets)"
  NORMALIZED_REMOTE_ASSETS="$(normalize_assets "$REMOTE_ASSETS")" || {
    echo "Forgejo release assets response is invalid" >&2
    exit 1
  }
  ASSET_PAYLOADS_MATCH=0
  if [ "$NORMALIZED_REMOTE_ASSETS" = "$EXPECTED_ASSETS" ]; then
    if verify_remote_payloads; then
      ASSET_PAYLOADS_MATCH=1
    else
      VERIFY_STATUS=$?
      [ "$VERIFY_STATUS" = "1" ] || {
        echo "Forgejo asset payloads could not be verified" >&2
        exit 1
      }
    fi
  fi
  if [ "$ASSET_PAYLOADS_MATCH" = "1" ]; then
    NEEDS_ASSET_REFRESH=0
    if [ "$REMOTE_DRAFT" = "false" ] &&
       [ "$REMOTE_PRERELEASE" = "false" ] &&
       [ "$REMOTE_NAME" = "NOOP $TAG" ] &&
       [ "$REMOTE_BODY" = "$NOTES" ]; then
      echo "✓ $TAG is already published with the exact verified asset set."
      exit 0
    fi
    echo "  existing release has exact assets; reconciling canonical metadata"
  else
    echo "  release exists — returning it to draft while assets refresh"
    return_release_to_draft || {
      exit 1
    }
  fi
fi

if [ "$NEEDS_ASSET_REFRESH" = "1" ]; then
  REMOTE_ASSETS="$(fetch_assets)"
  normalize_assets "$REMOTE_ASSETS" >/dev/null || {
    echo "Forgejo release assets response is invalid" >&2
    exit 1
  }
  while IFS= read -r asset_id; do
    [ -n "$asset_id" ] || continue
    [[ "$asset_id" =~ ^[1-9][0-9]*$ ]] || {
      echo "Forgejo release contains an invalid asset identifier" >&2
      exit 1
    }
    api -X DELETE \
      "$API/repos/$ORG/$REPO/releases/$REL_ID/assets/$asset_id" >/dev/null
  done < <(jq -r '.[].id' <<<"$REMOTE_ASSETS")

  REMOTE_ASSETS="$(fetch_assets)"
  [ "$(normalize_assets "$REMOTE_ASSETS")" = "[]" ] || {
    echo "Forgejo release assets could not be cleared; release remains draft" >&2
    exit 1
  }

  for f in "${ASSETS[@]}"; do
    name="$(basename "$f")"
    local_size="$(wc -c < "$f" | tr -d '[:space:]')"
    UPLOADED_ASSET="$(
      curl --config "$AUTH_CONFIG" --connect-timeout 10 --max-time 600 -fsS \
        -F "attachment=@$f;type=application/octet-stream" \
        "$API/repos/$ORG/$REPO/releases/$REL_ID/assets?name=$name"
    )" || {
      echo "Forgejo asset upload failed; release remains draft" >&2
      exit 1
    }
    jq -e --arg name "$name" --argjson size "$local_size" \
      --arg download_url \
        "https://$DOMAIN/$ORG/$REPO/releases/download/$TAG/$name" '
        .name == $name and
        .size == $size and
        .type == "attachment" and
        .browser_download_url == $download_url
      ' <<<"$UPLOADED_ASSET" >/dev/null || {
      echo "Forgejo returned invalid metadata for $name; release remains draft" >&2
      exit 1
    }
    echo "  ↑ $name"
  done
fi

REMOTE_ASSETS="$(fetch_assets)"
NORMALIZED_REMOTE_ASSETS="$(normalize_assets "$REMOTE_ASSETS")" || {
  echo "Forgejo release assets response is invalid" >&2
  exit 1
}
[ "$NORMALIZED_REMOTE_ASSETS" = "$EXPECTED_ASSETS" ] || {
  echo "Forgejo release asset set is not exact; release remains draft" >&2
  exit 1
}
verify_remote_payloads || {
  echo "Forgejo release payloads are not exact; release remains draft" >&2
  exit 1
}

if ! PUBLISHED_RELEASE="$(
  api -X PATCH "$API/repos/$ORG/$REPO/releases/$REL_ID" \
    -d "$(jq -n --arg n "NOOP $TAG" --arg b "$NOTES" \
          '{name:$n,body:$b,draft:false,prerelease:false}')"
)"; then
  return_release_to_draft || {
    echo "Forgejo ambiguous publication rollback failed" >&2
    exit 1
  }
  echo "Forgejo publication response failed; release is draft" >&2
  exit 1
fi
[ "$(jq -r '.draft' <<<"$PUBLISHED_RELEASE")" = "false" ] &&
  [ "$(jq -r '.prerelease' <<<"$PUBLISHED_RELEASE")" = "false" ] &&
  [ "$(jq -r '.tag_name' <<<"$PUBLISHED_RELEASE")" = "$TAG" ] &&
  [ "$(jq -r '.name' <<<"$PUBLISHED_RELEASE")" = "NOOP $TAG" ] &&
  [ "$(jq -r '.body' <<<"$PUBLISHED_RELEASE")" = "$NOTES" ] &&
  [ "$(jq -r '.target_commitish' <<<"$PUBLISHED_RELEASE")" = \
    "$TARGET_COMMITISH" ] || {
  echo "Forgejo did not publish the verified release" >&2
  exit 1
}

REMOTE_ASSETS="$(fetch_assets)"
POST_PUBLICATION_VALID=1
if [ "$(normalize_assets "$REMOTE_ASSETS")" != "$EXPECTED_ASSETS" ]; then
  POST_PUBLICATION_VALID=0
elif ! verify_remote_payloads; then
  POST_PUBLICATION_VALID=0
fi
if [ "$POST_PUBLICATION_VALID" != "1" ]; then
  return_release_to_draft || {
    echo "Forgejo publication drift rollback failed" >&2
    exit 1
  }
  echo "Forgejo release asset set changed during publication; release is draft" >&2
  exit 1
fi
echo "✓ $TAG published: https://$DOMAIN/$ORG/$REPO/releases/tag/$TAG"
