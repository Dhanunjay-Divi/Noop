-- Non-destructive live readiness inventory for the future managed-document
-- privacy contract. The filename is retained because migration versions are
-- immutable once referenced, but this migration never quarantines, deletes,
-- rewrites, or publishes user documents.
--
-- The server cannot convert plaintext to client-encrypted content because it
-- does not possess the client key. Activation therefore remains a later,
-- version-gated rollout after clients can encrypt, restore, and backfill every
-- supported document kind. This view exposes aggregate counts only and remains
-- current as documents change after the migration runs.

CREATE OR REPLACE VIEW managed_document_contract_v2_readiness AS
WITH classified AS (
    SELECT document.document_kind,
           (
               document.document_kind <> 'day_ownership'
               AND document.content_mode = 'server_readable'
           ) AS is_legacy_plaintext,
           (
               document.document_kind = 'day_ownership'
               AND NOT (
                   document.content_mode = 'server_readable'
                   AND COALESCE(
                       noop_managed_day_ownership_payload_valid(
                           document.payload_json
                       ),
                       false
                   )
               )
           ) AS is_invalid_day_ownership,
           (
               document.document_kind <> 'day_ownership'
               AND document.content_mode = 'client_encrypted'
           ) AS is_encrypted_non_day,
           head.current_revision = document.document_revision AS is_current
    FROM managed_documents AS document
    LEFT JOIN managed_document_heads AS head
      ON head.account_id = document.account_id
     AND head.document_kind = document.document_kind
     AND head.document_id = document.document_id
    WHERE document.deleted_at IS NULL
),
blocking_by_kind AS (
    SELECT COALESCE(
        jsonb_object_agg(
            counts.document_kind,
            counts.blocking_revisions
            ORDER BY counts.document_kind
        ),
        '{}'::jsonb
    ) AS value
    FROM (
        SELECT document_kind,
               count(*)::bigint AS blocking_revisions
        FROM classified
        WHERE is_legacy_plaintext OR is_invalid_day_ownership
        GROUP BY document_kind
    ) AS counts
),
summary AS (
    SELECT
        count(*) FILTER (
            WHERE is_legacy_plaintext
        )::bigint AS legacy_plaintext_revisions,
        count(*) FILTER (
            WHERE is_legacy_plaintext AND is_current
        )::bigint AS legacy_plaintext_heads,
        count(*) FILTER (
            WHERE is_invalid_day_ownership
        )::bigint AS invalid_day_ownership_revisions,
        count(*) FILTER (
            WHERE is_invalid_day_ownership AND is_current
        )::bigint AS invalid_day_ownership_heads,
        count(*) FILTER (
            WHERE is_encrypted_non_day
        )::bigint AS encrypted_non_day_revisions,
        count(*) FILTER (
            WHERE is_encrypted_non_day AND is_current
        )::bigint AS encrypted_non_day_heads
    FROM classified
)
SELECT
    'managed_document_content_v2'::text AS readiness_key,
    summary.legacy_plaintext_revisions,
    summary.legacy_plaintext_heads,
    summary.invalid_day_ownership_revisions,
    summary.invalid_day_ownership_heads,
    summary.encrypted_non_day_revisions,
    summary.encrypted_non_day_heads,
    blocking_by_kind.value AS blocking_by_kind,
    clock_timestamp() AS observed_at
FROM summary
CROSS JOIN blocking_by_kind;
