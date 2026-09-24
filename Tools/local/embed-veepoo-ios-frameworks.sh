#!/bin/sh
set -eu

repository_root="${SRCROOT:?}"
"$repository_root/Tools/local/configure-veepoo-ios-sdk.py" --build-check

destination_root="${TARGET_BUILD_DIR:?}/${FRAMEWORKS_FOLDER_PATH:?}"
mkdir -p "$destination_root"

copy_framework() {
    source_framework="$1"
    framework_name="$2"
    destination_framework="$destination_root/$framework_name.framework"

    if [ ! -d "$source_framework" ]; then
        echo "error: missing verified supplier framework: $framework_name" >&2
        exit 1
    fi

    rm -rf "$destination_framework"
    /usr/bin/ditto "$source_framework" "$destination_framework"
    rm -rf "$destination_framework/Headers" "$destination_framework/Modules"

    if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ] &&
       [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
        /usr/bin/codesign --force \
            --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
            --preserve-metadata=identifier,entitlements \
            "$destination_framework"
    fi
}

for framework_name in ABParTool GRDFUSDK JLDialUnit ZipZap; do
    copy_framework \
        "${NOOP_VEEPOO_VENDOR_FRAMEWORK_DIR:?}/$framework_name.framework" \
        "$framework_name"
done

copy_framework \
    "${NOOP_VEEPOO_FMDB_FRAMEWORK_DIR:?}/FMDB.framework" \
    "FMDB"
copy_framework \
    "${NOOP_VEEPOO_MJEXTENSION_FRAMEWORK_DIR:?}/MJExtension.framework" \
    "MJExtension"
