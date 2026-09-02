#!/bin/sh
set -eu

database=${1:-${PGDATABASE:?PGDATABASE is required}}
manifest=${NOOP_MIGRATION_MANIFEST:-/opt/noop/migration-manifest.sha256}

if [ ! -r "$manifest" ]; then
    echo "migration manifest is required: $manifest" >&2
    exit 66
fi

expected_count=$(awk 'NF { count += 1 } END { print count + 0 }' "$manifest")
applied_count=$(psql \
    --dbname="$database" \
    --set=ON_ERROR_STOP=1 \
    --no-align \
    --tuples-only \
    --command="SELECT count(*) FROM noop_schema_migrations;")
if [ "$expected_count" -eq 0 ] || [ "$applied_count" -ne "$expected_count" ]; then
    echo "restored migration count does not match this release" >&2
    exit 65
fi

while read -r checksum version extra; do
    [ -n "$checksum" ] || continue
    if [ -n "${extra:-}" ] \
        || ! printf '%s\n' "$checksum" | grep -Eq '^[0-9a-f]{64}$' \
        || ! printf '%s\n' "$version" \
            | grep -Eq '^[0-9]{3}_[a-z0-9_]+[.]sql$'; then
        echo "invalid migration manifest entry" >&2
        exit 66
    fi
    matched=$(psql \
        --dbname="$database" \
        --set=ON_ERROR_STOP=1 \
        --set=version="$version" \
        --set=checksum="$checksum" \
        --no-align \
        --tuples-only \
        --file=- <<'SQL'
SELECT count(*) FROM noop_schema_migrations
WHERE version = :'version'
  AND btrim(checksum) = :'checksum';
SQL
    )
    if [ "$matched" -ne 1 ]; then
        echo "restored migration checksum mismatch: $version" >&2
        exit 65
    fi
done <"$manifest"

psql \
    --dbname="$database" \
    --set=ON_ERROR_STOP=1 \
    --file=/opt/noop/restore-application-smoke.sql \
    >/dev/null

echo "restore application contract smoke test passed"
