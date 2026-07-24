#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# release.sh — cut a NOOP release on the canonical GitHub repository.
# Run from your Mac at release time, after the anonymized binaries are built.
#
#   Tools/release.sh <version> <asset> [<asset> ...] [-- "release notes"]
#   e.g. Tools/release.sh 4.7.0 \
#          dist/NOOP-macos-v4.7.0.zip dist/NOOP-ios-unsigned-v4.7.0.ipa \
#          dist/NOOP-android-v4.7.0.apk \
#          -- "Bug fixes and the new Lab Book."
#
# GitHub is CANONICAL — the release is created there FIRST
# (Dhanunjay-Divi/Noop) as a draft, assets are uploaded and verified, and only
# then is it published as latest. A Forgejo mirror is attempted only when the
# operator explicitly sets NOOP_RELEASE_FORGE=1 and supplies that script's
# FORGE_DOMAIN/FORGE_ORG/FORGE_REPO variables. This prevents a fork checkout
# from accidentally publishing into historical upstream infrastructure.
#
# Same args as forgejo-release.sh: <version> <asset...> [-- notes].
# Idempotent: re-running clobbers the release's assets (and edits the title/notes)
# rather than erroring on an existing tag.
#
# GitHub token from ~/.config/noop/gh_token. An explicitly enabled Forge mirror
# uses the separate token handled by forgejo-release.sh.
# No secret ever appears on a command line.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# Canonical GitHub coordinates. A deliberate alternate target must use this
# task-specific variable; a generic inherited GH_REPO cannot silently redirect a
# release.
GH_REPO="${NOOP_RELEASE_GITHUB_REPO:-Dhanunjay-Divi/Noop}"

VER="${1:?usage: release.sh <version> <asset...> [-- notes]}"; shift
TAG="v$VER"
NOTES="NOOP $TAG — see CHANGELOG.md."
ASSETS=()
# split args into assets + optional "-- notes".
while [ $# -gt 0 ]; do
  if [ "$1" = "--" ]; then shift; NOTES="${1:-$NOTES}"; break; fi
  ASSETS+=("$1"); shift
done

# ── iOS asset: ONE canonical name ────────────────────────────────────────────
# Match the fork workflows and public docs: NOOP-ios-unsigned-v<V>.ipa.
# Normalize any locally supplied IPA to that name so the uploaded asset and the
# AltStore URL cannot drift apart.
NEW_ASSETS=()
for f in ${ASSETS[@]+"${ASSETS[@]}"}; do
  case "$f" in
    *.ipa)
      if [ -f "$f" ]; then
        ios_f="$(dirname "$f")/NOOP-ios-unsigned-v${VER}.ipa"
        if [ "$f" != "$ios_f" ]; then
          cp -f "$f" "$ios_f" 2>/dev/null || {
            echo "  ✗ could not normalize iOS asset: $f" >&2
            exit 1
          }
          echo "  iOS asset: $(basename "$ios_f")"
        fi
        NEW_ASSETS+=("$ios_f")
      else
        NEW_ASSETS+=("$f")
      fi ;;
    *) NEW_ASSETS+=("$f") ;;
  esac
done
ASSETS=("${NEW_ASSETS[@]}")
# rebuild the forgejo arg list from the (now alias-expanded) assets + notes,
# so the mirror uploads exactly the same set as GitHub.
FORGE_ARGS=(${ASSETS[@]+"${ASSETS[@]}"} -- "$NOTES")

# ── 1. GitHub (canonical) ────────────────────────────────────────────────────
GH_TOKEN_FILE="$HOME/.config/noop/gh_token"
[ -f "$GH_TOKEN_FILE" ] || { echo "missing $GH_TOKEN_FILE" >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "gh CLI not found on PATH" >&2; exit 1; }

# ── Cadence guard (anti-suspension safeguard — see docs/SAFEGUARDS.md) ────────
# GitHub once auto-flagged this account for activity that looked bot-like — a
# rapid BURST of releases (its Acceptable Use Policy bars "excessive automated
# bulk activity"). Releases should be BATCHED, not drip-shipped one tiny fix at
# a time. This refuses to publish if we've already cut several today, or one was
# just published, UNLESS you deliberately override — so a burst is always a
# conscious choice, never an accident. Tunable: CADENCE_LIMIT, CADENCE_MIN_GAP_MIN.
CADENCE_LIMIT="${CADENCE_LIMIT:-3}"                 # releases/day before the gate trips
CADENCE_MIN_GAP_MIN="${CADENCE_MIN_GAP_MIN:-20}"    # minutes that must pass since the last
if [ "${ALLOW_RAPID_RELEASE:-0}" != "1" ]; then
  _rel_json="$(GH_TOKEN="$(cat "$GH_TOKEN_FILE")" gh api "repos/$GH_REPO/releases?per_page=20" 2>/dev/null || echo '[]')"
  _today="$(date -u +%Y-%m-%d)"
  _count_today="$(printf '%s' "$_rel_json" | python3 -c "import sys,json
try: d=json.load(sys.stdin)
except Exception: d=[]
print(sum(1 for r in d if str(r.get('created_at','')).startswith('$_today') and not r.get('draft')))" 2>/dev/null || echo 0)"
  _gap_min="$(printf '%s' "$_rel_json" | python3 -c "import sys,json,datetime
try: d=json.load(sys.stdin)
except Exception: d=[]
pub=[r['created_at'] for r in d if r.get('created_at') and not r.get('draft')]
if not pub: print(99999)
else:
  last=max(datetime.datetime.strptime(p,'%Y-%m-%dT%H:%M:%SZ') for p in pub)
  print(int((datetime.datetime.utcnow()-last).total_seconds()//60))" 2>/dev/null || echo 99999)"
  if [ "${_count_today:-0}" -ge "$CADENCE_LIMIT" ] || [ "${_gap_min:-99999}" -lt "$CADENCE_MIN_GAP_MIN" ]; then
    echo "────────────────────────────────────────────────────────────────────" >&2
    echo "⛔ CADENCE GUARD — refusing to publish $TAG." >&2
    echo "   ${_count_today} release(s) already today; last one ${_gap_min} min ago." >&2
    echo "   Rapid release bursts are what tripped GitHub's abuse filter before." >&2
    echo "   BATCH the fixes into one release and space them out. If this release" >&2
    echo "   is genuinely warranted right now, re-run with:  ALLOW_RAPID_RELEASE=1" >&2
    echo "────────────────────────────────────────────────────────────────────" >&2
    exit 2
  fi
fi

# Validate every requested asset before creating or modifying a remote release.
# A missing file must never produce a published, incomplete release.
# ${ARR[@]+"${ARR[@]}"} guards against the empty-array "unbound variable" trap
# in macOS's stock bash 3.2 under `set -u`.
GH_ASSETS=()
MISSING_ASSETS=0
for f in ${ASSETS[@]+"${ASSETS[@]}"}; do
  if [ -f "$f" ]; then
    GH_ASSETS+=("$f")
  else
    echo "  ✗ missing asset: $f" >&2
    MISSING_ASSETS=1
  fi
done
[ "$MISSING_ASSETS" = 0 ] || exit 1
[ "${#GH_ASSETS[@]}" -gt 0 ] || {
  echo "  ✗ at least one release asset is required" >&2
  exit 1
}

echo "→ release $TAG on GitHub $GH_REPO (canonical)"
GH_OK=1
if GH_TOKEN="$(cat "$GH_TOKEN_FILE")" \
   gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1; then
  # Fail closed on a rerun too: temporarily return an existing release to draft
  # while its notes and assets are refreshed.
  echo "  release exists — returning it to draft while assets refresh"
  GH_TOKEN="$(cat "$GH_TOKEN_FILE")" \
    gh release edit "$TAG" --repo "$GH_REPO" \
      --title "NOOP $TAG" --notes "$NOTES" --draft >/dev/null \
    || { echo "  ⚠ gh release edit failed" >&2; GH_OK=0; }
else
  GH_TOKEN="$(cat "$GH_TOKEN_FILE")" \
    gh release create "$TAG" --repo "$GH_REPO" \
      --title "NOOP $TAG" --notes "$NOTES" --draft \
    || { echo "  ⚠ gh release create failed" >&2; GH_OK=0; }
fi

if [ "$GH_OK" = 1 ]; then
  GH_TOKEN="$(cat "$GH_TOKEN_FILE")" \
    gh release upload "$TAG" "${GH_ASSETS[@]}" --repo "$GH_REPO" --clobber \
    || { echo "  ⚠ gh release upload failed; release remains draft" >&2; GH_OK=0; }
fi

if [ "$GH_OK" = 1 ]; then
  REMOTE_ASSETS="$(GH_TOKEN="$(cat "$GH_TOKEN_FILE")" \
    gh release view "$TAG" --repo "$GH_REPO" --json assets --jq '.assets[].name')" \
    || { echo "  ⚠ could not inspect uploaded assets; release remains draft" >&2; GH_OK=0; }
fi
if [ "$GH_OK" = 1 ]; then
  for f in "${GH_ASSETS[@]}"; do
    expected="$(basename "$f")"
    if ! grep -Fxq "$expected" <<<"$REMOTE_ASSETS"; then
      echo "  ⚠ uploaded release is missing $expected; release remains draft" >&2
      GH_OK=0
    fi
  done
fi

if [ "$GH_OK" = 1 ]; then
  GH_TOKEN="$(cat "$GH_TOKEN_FILE")" \
    gh release edit "$TAG" --repo "$GH_REPO" \
      --draft=false --prerelease=false --latest >/dev/null \
    || { echo "  ⚠ final publish failed; inspect the draft" >&2; GH_OK=0; }
fi

[ "$GH_OK" = 1 ] \
  && echo "✓ $TAG on GitHub: https://github.com/$GH_REPO/releases/tag/$TAG" \
  || echo "✗ GitHub release for $TAG had errors (see above)" >&2

# ── 2. Optional Forgejo mirror (explicit opt-in; never aborts) ────────────────
if [ "${NOOP_RELEASE_FORGE:-0}" = "1" ] && [ -x "$HERE/forgejo-release.sh" ]; then
  echo "→ mirroring $TAG to the explicitly configured Forgejo repository"
  if "$HERE/forgejo-release.sh" "$VER" ${FORGE_ARGS[@]+"${FORGE_ARGS[@]}"}; then
    :  # forgejo-release.sh prints its own success line
  else
    echo "  ⚠ Forgejo mirror failed (non-fatal — GitHub is canonical)" >&2
  fi
elif [ "${NOOP_RELEASE_FORGE:-0}" = "1" ]; then
  echo "  ⚠ $HERE/forgejo-release.sh not found/executable — skipping mirror" >&2
else
  echo "→ Forgejo mirror disabled (set NOOP_RELEASE_FORGE=1 plus FORGE_* to enable)"
fi

# ── 3. Distribution manifests (AltStore source + Homebrew cask) ───────────────
# These were historically run BY HAND and got silently skipped for the whole
# 6.0.x batch, stranding every iOS-sideload and `brew` user on 5.3.0 (#560/#562).
# Wire them into the release so the manifests can never fall behind a release
# again. Best-effort: a manifest miss warns but never fails the run (the GitHub
# release already succeeded). Only fires when the matching asset is present and
# the GitHub release was OK. The AltStore source file is committed/pushed by the
# normal `git push` of altstore-source.json; the cask script self-pushes its tap.
if [ "$GH_OK" = 1 ]; then
  IPA_ASSET=""; ZIP_ASSET=""
  for f in ${ASSETS[@]+"${ASSETS[@]}"}; do
    case "$f" in
      *NOOP-ios-unsigned-v*.ipa) [ -z "$IPA_ASSET" ] && [ -f "$f" ] && IPA_ASSET="$f" ;;
      *NOOP-macos-v*.zip|*NOOP-v*-macos.zip|*NOOP-v*macos*.zip) [ -f "$f" ] && ZIP_ASSET="$f" ;;
    esac
  done
  if [ -n "$IPA_ASSET" ] && [ -x "$HERE/update-altstore-source.sh" ]; then
    echo "→ refreshing AltStore source for $VER"
    "$HERE/update-altstore-source.sh" "$VER" "$IPA_ASSET" \
      || echo "  ⚠ AltStore source update failed — run Tools/update-altstore-source.sh by hand" >&2
    echo "  ↳ remember to commit + push altstore-source.json"
  fi
  if [ -n "$ZIP_ASSET" ] && [ "${NOOP_RELEASE_HOMEBREW:-0}" = "1" ] \
     && [ -x "$HERE/update-homebrew-cask.sh" ]; then
    echo "→ refreshing Homebrew cask for $VER"
    "$HERE/update-homebrew-cask.sh" "$VER" "$ZIP_ASSET" \
      || echo "  ⚠ Homebrew cask update failed — run Tools/update-homebrew-cask.sh by hand" >&2
  elif [ -n "$ZIP_ASSET" ]; then
    echo "→ Homebrew tap update disabled (set NOOP_RELEASE_HOMEBREW=1 after configuring a fork-owned tap)"
  fi
fi

# exit reflects the canonical (GitHub) outcome only
[ "$GH_OK" = 1 ]
