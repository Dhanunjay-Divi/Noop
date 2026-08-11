#!/usr/bin/env bash
#
# Fail-closed validation for a signed iOS release artifact. With a previous `.app` as argument 2,
# this also enforces the identity continuity that makes an install an in-place upgrade rather than a
# new sandbox with apparently missing history.
#
# Usage:
#   bash Tools/verify-ios-release-contract.sh path/to/New/NOOP.app [path/to/Previous/NOOP.app]

set -euo pipefail

NEW_APP="${1:?usage: $0 path/to/New/NOOP.app [path/to/Previous/NOOP.app]}"
PREVIOUS_APP="${2:-}"
[ -d "$NEW_APP" ] || { echo "new app bundle not found: $NEW_APP" >&2; exit 1; }
[ -z "$PREVIOUS_APP" ] || [ -d "$PREVIOUS_APP" ] || {
  echo "previous app bundle not found: $PREVIOUS_APP" >&2
  exit 1
}

WORK_DIR=$(mktemp -d /tmp/noop-ios-release-contract.XXXXXX)
cleanup() {
  if [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

plist_value() {
  local plist="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
}

entitlements_for() {
  local bundle="$1"
  local output="$2"
  codesign -d --entitlements :- "$bundle" 2>/dev/null > "$output"
  plutil -lint "$output" >/dev/null
}

validate_group_contract() {
  local bundle="$1"
  local label="$2"
  local info="$bundle/Info.plist"
  local configured_group
  configured_group=$(plist_value "$info" AppGroupIdentifier)
  [ -n "$configured_group" ] || { echo "$label has no AppGroupIdentifier" >&2; exit 1; }

  local entitlement_file="$WORK_DIR/$(echo "$label" | tr '/ ' '__').entitlements.plist"
  entitlements_for "$bundle" "$entitlement_file"
  local signed_group
  signed_group=$(plist_value "$entitlement_file" 'com.apple.security.application-groups:0')
  [ "$signed_group" = "$configured_group" ] || {
    echo "$label App Group mismatch: Info=$configured_group signed=$signed_group" >&2
    exit 1
  }
}

validate_new_bundle() {
  local bundle="$1"
  local label="$2"
  [ -f "$bundle/Info.plist" ] || { echo "$label Info.plist missing" >&2; exit 1; }
  [ -f "$bundle/PrivacyInfo.xcprivacy" ] || { echo "$label PrivacyInfo.xcprivacy missing" >&2; exit 1; }
  codesign --verify --strict "$bundle"
  validate_group_contract "$bundle" "$label"
}

codesign --verify --deep --strict "$NEW_APP"
validate_new_bundle "$NEW_APP" app

APP_ENTITLEMENTS="$WORK_DIR/app.entitlements.plist"
entitlements_for "$NEW_APP" "$APP_ENTITLEMENTS"
[ "$(plist_value "$APP_ENTITLEMENTS" com.apple.developer.healthkit)" = "true" ] || {
  echo "signed app is missing com.apple.developer.healthkit" >&2
  exit 1
}
[ "$(plist_value "$APP_ENTITLEMENTS" com.apple.developer.healthkit.background-delivery)" = "true" ] || {
  echo "signed app is missing com.apple.developer.healthkit.background-delivery" >&2
  exit 1
}

BACKGROUND_MODES=$(plist_value "$NEW_APP/Info.plist" UIBackgroundModes)
for mode in bluetooth-central location fetch; do
  echo "$BACKGROUND_MODES" | grep -Fxq "    $mode" || {
    echo "signed app Info.plist is missing UIBackgroundModes/$mode" >&2
    exit 1
  }
done

# Validate every app/extension process that declares the shared group. The Watch app also requires
# HealthKit; its complication and the iOS widget require the same group but not HealthKit.
while IFS= read -r -d '' nested; do
  relative=${nested#"$NEW_APP/"}
  validate_new_bundle "$nested" "$relative"
  if [[ "$nested" == */Watch/*.app ]]; then
    NESTED_ENTITLEMENTS="$WORK_DIR/$(echo "$relative" | tr '/ ' '__').health.entitlements.plist"
    entitlements_for "$nested" "$NESTED_ENTITLEMENTS"
    [ "$(plist_value "$NESTED_ENTITLEMENTS" com.apple.developer.healthkit)" = "true" ] || {
      echo "$relative is missing its HealthKit entitlement" >&2
      exit 1
    }
  fi
done < <(find "$NEW_APP" -mindepth 1 -type d \( -name '*.appex' -o -name '*.app' \) -print0)

if [ -n "$PREVIOUS_APP" ]; then
  NEW_ID=$(plist_value "$NEW_APP/Info.plist" CFBundleIdentifier)
  OLD_ID=$(plist_value "$PREVIOUS_APP/Info.plist" CFBundleIdentifier)
  [ "$NEW_ID" = "$OLD_ID" ] || {
    echo "bundle identifier changed ($OLD_ID -> $NEW_ID); this would create a new data sandbox" >&2
    exit 1
  }

  NEW_GROUP=$(plist_value "$NEW_APP/Info.plist" AppGroupIdentifier)
  OLD_GROUP=$(plist_value "$PREVIOUS_APP/Info.plist" AppGroupIdentifier)
  [ "$NEW_GROUP" = "$OLD_GROUP" ] || {
    echo "App Group changed ($OLD_GROUP -> $NEW_GROUP); widgets/watch would lose shared state" >&2
    exit 1
  }

  NEW_BUILD=$(plist_value "$NEW_APP/Info.plist" CFBundleVersion)
  OLD_BUILD=$(plist_value "$PREVIOUS_APP/Info.plist" CFBundleVersion)
  [[ "$NEW_BUILD" =~ ^[0-9]+$ && "$OLD_BUILD" =~ ^[0-9]+$ && "$NEW_BUILD" -gt "$OLD_BUILD" ]] || {
    echo "CFBundleVersion must increase for an upgrade ($OLD_BUILD -> $NEW_BUILD)" >&2
    exit 1
  }

  for pair in "new:$NEW_APP" "old:$PREVIOUS_APP"; do
    name=${pair%%:*}
    app=${pair#*:}
    output="$WORK_DIR/$name.bundle-ids"
    : > "$output"
    while IFS= read -r -d '' nested; do
      plist_value "$nested/Info.plist" CFBundleIdentifier >> "$output"
    done < <(find "$app" -mindepth 1 -type d \( -name '*.appex' -o -name '*.app' \) -print0)
    sort -o "$output" "$output"
  done
  cmp -s "$WORK_DIR/old.bundle-ids" "$WORK_DIR/new.bundle-ids" || {
    echo "nested widget/watch bundle identifiers changed; upgrade continuity is not proven" >&2
    diff -u "$WORK_DIR/old.bundle-ids" "$WORK_DIR/new.bundle-ids" >&2 || true
    exit 1
  }
fi

echo "✓ signed iOS release contract verified: entitlements, privacy manifests, background modes, and stable upgrade identity"
