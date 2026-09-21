-- Account erasure for managed authority, formula shadow, and wrapped keys.
-- Ordinary mutation remains blocked. The only deletion path is a matching
-- account-erasure job that is already in the verifying phase.

ALTER TABLE managed_erasure_jobs
    ADD CONSTRAINT managed_erasure_job_account_job_unique
    UNIQUE (account_id, erasure_job_id);

CREATE TABLE managed_account_cloud_erasure_tombstones (
    account_id uuid NOT NULL
        REFERENCES managed_accounts(account_id) ON DELETE RESTRICT,
    erasure_job_id uuid NOT NULL,
    erasure_scope text NOT NULL,
    authority_state_rows bigint NOT NULL,
    authority_transition_rows bigint NOT NULL,
    formula_shadow_rows bigint NOT NULL,
    document_key_rows bigint NOT NULL,
    document_key_version_rows bigint NOT NULL,
    managed_identity_link_rows bigint NOT NULL,
    erased_at timestamptz NOT NULL,
    PRIMARY KEY (account_id, erasure_job_id),
    UNIQUE (erasure_job_id),
    CONSTRAINT managed_account_cloud_erasure_job_fk
        FOREIGN KEY (account_id, erasure_job_id)
        REFERENCES managed_erasure_jobs(account_id, erasure_job_id)
        ON DELETE RESTRICT,
    CONSTRAINT managed_account_cloud_erasure_scope
        CHECK (erasure_scope IN ('all_managed_data', 'account')),
    CONSTRAINT managed_account_cloud_erasure_counts
        CHECK (
            authority_state_rows >= 0
            AND authority_transition_rows >= 0
            AND formula_shadow_rows >= 0
            AND document_key_rows >= 0
            AND document_key_version_rows >= 0
            AND managed_identity_link_rows >= 0
        )
);

CREATE OR REPLACE FUNCTION noop_managed_account_erasure_context(
    scoped_account_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $function$
    SELECT
        current_setting(
            'noop.managed_erasure_account_id',
            true
        ) = scoped_account_id::text
        AND EXISTS (
            SELECT 1
            FROM managed_erasure_jobs AS job
            JOIN managed_accounts AS account
              ON account.account_id = job.account_id
            WHERE job.account_id = scoped_account_id
              AND job.erasure_job_id::text = current_setting(
                    'noop.managed_erasure_job_id',
                    true
              )
              AND job.scope IN ('all_managed_data', 'account')
              AND job.status = 'verifying'
              AND account.status = 'erasure_pending'
        )
$function$;

CREATE OR REPLACE FUNCTION noop_managed_authority_transition_delete_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF noop_managed_account_erasure_context(OLD.managed_account_id) THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'managed authority transitions are append-only'
        USING ERRCODE = '23514';
END
$function$;

DROP TRIGGER managed_authority_transition_append_only
    ON managed_authority_transitions;

CREATE TRIGGER managed_authority_transition_append_only
BEFORE UPDATE ON managed_authority_transitions
FOR EACH ROW
EXECUTE FUNCTION noop_managed_authority_transition_append_only();

CREATE TRIGGER managed_authority_transition_delete_guard
BEFORE DELETE ON managed_authority_transitions
FOR EACH ROW
EXECUTE FUNCTION noop_managed_authority_transition_delete_guard();

CREATE OR REPLACE FUNCTION noop_managed_authority_state_delete_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF noop_managed_account_erasure_context(OLD.managed_account_id) THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'managed authority state cannot be deleted'
        USING ERRCODE = '23514';
END
$function$;

CREATE TRIGGER managed_authority_state_delete_guard
BEFORE DELETE ON managed_authority_states
FOR EACH ROW
EXECUTE FUNCTION noop_managed_authority_state_delete_guard();

CREATE OR REPLACE FUNCTION noop_managed_formula_shadow_delete_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF noop_managed_account_erasure_context(OLD.account_id) THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'managed formula shadow results are append-only'
        USING ERRCODE = '23514';
END
$function$;

DROP TRIGGER managed_formula_shadow_immutable
    ON managed_formula_shadow_results;

CREATE TRIGGER managed_formula_shadow_immutable
BEFORE UPDATE ON managed_formula_shadow_results
FOR EACH ROW
EXECUTE FUNCTION noop_managed_formula_shadow_immutable();

CREATE TRIGGER managed_formula_shadow_delete_guard
BEFORE DELETE ON managed_formula_shadow_results
FOR EACH ROW
EXECUTE FUNCTION noop_managed_formula_shadow_delete_guard();

CREATE OR REPLACE FUNCTION noop_managed_document_key_version_delete_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF noop_managed_account_erasure_context(OLD.account_id) THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'managed document key versions are append-only'
        USING ERRCODE = '23514';
END
$function$;

DROP TRIGGER managed_document_key_version_guard
    ON managed_document_key_versions;

CREATE TRIGGER managed_document_key_version_guard
BEFORE INSERT OR UPDATE ON managed_document_key_versions
FOR EACH ROW
EXECUTE FUNCTION noop_managed_document_key_version_guard();

CREATE TRIGGER managed_document_key_version_delete_guard
BEFORE DELETE ON managed_document_key_versions
FOR EACH ROW
EXECUTE FUNCTION noop_managed_document_key_version_delete_guard();

CREATE OR REPLACE FUNCTION noop_managed_document_key_delete_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF noop_managed_account_erasure_context(OLD.account_id) THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'managed document keys cannot be deleted'
        USING ERRCODE = '23514';
END
$function$;

DROP TRIGGER managed_document_key_lifecycle_guard
    ON managed_document_keys;

CREATE TRIGGER managed_document_key_lifecycle_guard
BEFORE INSERT OR UPDATE ON managed_document_keys
FOR EACH ROW
EXECUTE FUNCTION noop_managed_document_key_lifecycle_guard();

CREATE TRIGGER managed_document_key_delete_guard
BEFORE DELETE ON managed_document_keys
FOR EACH ROW
EXECUTE FUNCTION noop_managed_document_key_delete_guard();

CREATE OR REPLACE FUNCTION noop_unified_managed_link_delete_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF noop_managed_account_erasure_context(OLD.managed_account_id) THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'unified managed account links are immutable'
        USING ERRCODE = '23514';
END
$function$;

DROP TRIGGER unified_managed_account_link_guard
    ON unified_managed_account_links;

CREATE TRIGGER unified_managed_account_link_guard
BEFORE INSERT OR UPDATE ON unified_managed_account_links
FOR EACH ROW
EXECUTE FUNCTION noop_unified_account_link_guard();

CREATE TRIGGER unified_managed_account_link_delete_guard
BEFORE DELETE ON unified_managed_account_links
FOR EACH ROW
EXECUTE FUNCTION noop_unified_managed_link_delete_guard();

CREATE OR REPLACE FUNCTION noop_erase_managed_account_cloud_state(
    erased_account_id uuid,
    account_erasure_job_id uuid,
    erasure_time timestamptz
)
RETURNS TABLE (
    authority_state_rows bigint,
    authority_transition_rows bigint,
    formula_shadow_rows bigint,
    document_key_rows bigint,
    document_key_version_rows bigint,
    managed_identity_link_rows bigint
)
LANGUAGE plpgsql
AS $function$
DECLARE
    existing_tombstone managed_account_cloud_erasure_tombstones%ROWTYPE;
    erasure_ready boolean;
    erasure_scope text;
    deleted_authority_states bigint := 0;
    deleted_authority_transitions bigint := 0;
    deleted_formula_shadows bigint := 0;
    deleted_document_keys bigint := 0;
    deleted_document_key_versions bigint := 0;
    deleted_managed_links bigint := 0;
    removed_principal_ids uuid[] := ARRAY[]::uuid[];
BEGIN
    IF erasure_time IS NULL THEN
        RAISE EXCEPTION 'managed account erasure time is required'
            USING ERRCODE = '23514';
    END IF;

    SELECT *
    INTO existing_tombstone
    FROM managed_account_cloud_erasure_tombstones
    WHERE account_id = erased_account_id
      AND erasure_job_id = account_erasure_job_id
    FOR UPDATE;
    IF FOUND THEN
        RETURN QUERY
        SELECT
            existing_tombstone.authority_state_rows,
            existing_tombstone.authority_transition_rows,
            existing_tombstone.formula_shadow_rows,
            existing_tombstone.document_key_rows,
            existing_tombstone.document_key_version_rows,
            existing_tombstone.managed_identity_link_rows;
        RETURN;
    END IF;

    SELECT job.scope
    INTO erasure_scope
    FROM managed_erasure_jobs AS job
    JOIN managed_accounts AS account
      ON account.account_id = job.account_id
    WHERE job.account_id = erased_account_id
      AND job.erasure_job_id = account_erasure_job_id
      AND job.scope IN ('all_managed_data', 'account')
      AND job.status = 'verifying'
      AND job.requested_at <= erasure_time
      AND account.status = 'erasure_pending'
    FOR SHARE OF job, account;
    erasure_ready := FOUND;
    IF erasure_ready IS NOT TRUE THEN
        RAISE EXCEPTION 'managed account cloud erasure is not authorized'
            USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM managed_erasure_jobs AS job
        WHERE job.account_id = erased_account_id
          AND job.erasure_job_id <> account_erasure_job_id
          AND job.status IN ('running', 'verifying')
    ) THEN
        RAISE EXCEPTION 'managed account cloud erasure conflicts with another job'
            USING ERRCODE = '23514';
    END IF;

    PERFORM set_config(
        'noop.managed_erasure_account_id',
        erased_account_id::text,
        true
    );
    PERFORM set_config(
        'noop.managed_erasure_job_id',
        account_erasure_job_id::text,
        true
    );

    DELETE FROM managed_formula_shadow_results
    WHERE account_id = erased_account_id;
    GET DIAGNOSTICS deleted_formula_shadows = ROW_COUNT;

    DELETE FROM managed_authority_transitions
    WHERE managed_account_id = erased_account_id;
    GET DIAGNOSTICS deleted_authority_transitions = ROW_COUNT;

    DELETE FROM managed_authority_states
    WHERE managed_account_id = erased_account_id;
    GET DIAGNOSTICS deleted_authority_states = ROW_COUNT;

    DELETE FROM managed_document_key_versions
    WHERE account_id = erased_account_id;
    GET DIAGNOSTICS deleted_document_key_versions = ROW_COUNT;

    DELETE FROM managed_document_keys
    WHERE account_id = erased_account_id;
    GET DIAGNOSTICS deleted_document_keys = ROW_COUNT;

    IF erasure_scope = 'account' THEN
        WITH removed_links AS (
            DELETE FROM unified_managed_account_links
            WHERE managed_account_id = erased_account_id
            RETURNING principal_id
        )
        SELECT count(*), COALESCE(array_agg(principal_id), ARRAY[]::uuid[])
        INTO deleted_managed_links, removed_principal_ids
        FROM removed_links;

        UPDATE unified_account_principals AS principal
        SET status = 'retired',
            version = principal.version + 1,
            updated_at = GREATEST(principal.updated_at, erasure_time),
            retired_at = erasure_time
        WHERE principal.principal_id = ANY(removed_principal_ids)
          AND principal.status = 'active'
          AND NOT EXISTS (
              SELECT 1
              FROM unified_managed_account_links AS managed_link
              WHERE managed_link.principal_id = principal.principal_id
          )
          AND NOT EXISTS (
              SELECT 1
              FROM unified_ownership_account_links AS ownership_link
              WHERE ownership_link.principal_id = principal.principal_id
          );
    END IF;

    IF EXISTS (
        SELECT 1
        FROM managed_formula_shadow_results
        WHERE account_id = erased_account_id
        UNION ALL
        SELECT 1
        FROM managed_authority_transitions
        WHERE managed_account_id = erased_account_id
        UNION ALL
        SELECT 1
        FROM managed_authority_states
        WHERE managed_account_id = erased_account_id
        UNION ALL
        SELECT 1
        FROM managed_document_key_versions
        WHERE account_id = erased_account_id
        UNION ALL
        SELECT 1
        FROM managed_document_keys
        WHERE account_id = erased_account_id
    ) THEN
        RAISE EXCEPTION 'managed account cloud erasure verification failed'
            USING ERRCODE = '23514';
    END IF;
    IF erasure_scope = 'account' AND EXISTS (
        SELECT 1
        FROM unified_managed_account_links
        WHERE managed_account_id = erased_account_id
    ) THEN
        RAISE EXCEPTION 'managed account identity-link erasure verification failed'
            USING ERRCODE = '23514';
    END IF;

    INSERT INTO managed_account_cloud_erasure_tombstones (
        account_id,
        erasure_job_id,
        erasure_scope,
        authority_state_rows,
        authority_transition_rows,
        formula_shadow_rows,
        document_key_rows,
        document_key_version_rows,
        managed_identity_link_rows,
        erased_at
    ) VALUES (
        erased_account_id,
        account_erasure_job_id,
        erasure_scope,
        deleted_authority_states,
        deleted_authority_transitions,
        deleted_formula_shadows,
        deleted_document_keys,
        deleted_document_key_versions,
        deleted_managed_links,
        erasure_time
    );

    RETURN QUERY
    SELECT
        deleted_authority_states,
        deleted_authority_transitions,
        deleted_formula_shadows,
        deleted_document_keys,
        deleted_document_key_versions,
        deleted_managed_links;
END
$function$;
