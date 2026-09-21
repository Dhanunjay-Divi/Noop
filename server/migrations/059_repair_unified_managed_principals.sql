-- Repair unified managed-account links created by migration 047 for identities
-- that were already terminal when that backfill ran. Applied migrations remain
-- immutable, so this forward migration removes only the historical bad links.

DO $migration$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM noop_schema_migrations
        WHERE version = '047_unified_account_principals.sql'
          AND checksum =
              '3159e5f01eff093e7048bae091f19e2128ae6f436e7fa14e33a4e8d56703d324'
    ) THEN
        RAISE EXCEPTION
            'migration 047 ledger entry is unavailable or mismatched'
            USING ERRCODE = 'check_violation';
    END IF;
END
$migration$;

-- Ownership registration must lock an existing unified principal and create
-- its ownership link in the same transaction. Keep the runtime role off the
-- unified tables and expose only this exact keyed reconciliation boundary.
-- Qualify every relation at creation time and leave pg_temp last so a caller
-- cannot shadow a control-plane table.
DO $migration$
DECLARE
    target_schema name := current_schema();
BEGIN
    EXECUTE format(
        $ddl$
        CREATE OR REPLACE FUNCTION %1$I.noop_ownership_lock_unified_principal(
            requested_issuer text,
            requested_provider_tenant text,
            requested_subject_hash text
        )
        RETURNS text
        LANGUAGE sql
        SECURITY DEFINER
        SET search_path = pg_catalog, pg_temp
        AS $function$
            WITH locked_principal AS MATERIALIZED (
                SELECT
                    principal.principal_id,
                    principal.issuer,
                    principal.provider_tenant,
                    principal.subject_hash,
                    principal.status
                FROM %1$I.unified_account_principals AS principal
                WHERE principal.issuer = requested_issuer
                  AND principal.provider_tenant = requested_provider_tenant
                  AND principal.subject_hash =
                      requested_subject_hash::character(64)
                FOR UPDATE
            ),
            linked_ownership AS (
                INSERT INTO %1$I.unified_ownership_account_links (
                    principal_id,
                    ownership_account_id,
                    ownership_identity_id,
                    issuer,
                    provider_tenant,
                    subject_hash
                )
                SELECT
                    principal.principal_id,
                    identity.account_id,
                    identity.identity_id,
                    principal.issuer,
                    principal.provider_tenant,
                    principal.subject_hash
                FROM locked_principal AS principal
                JOIN %1$I.ownership_external_identities AS identity
                  ON identity.issuer = principal.issuer
                 AND identity.provider_tenant = principal.provider_tenant
                 AND identity.subject_hash = principal.subject_hash
                JOIN %1$I.ownership_accounts AS account
                  ON account.account_id = identity.account_id
                WHERE principal.status = 'active'
                  AND identity.status = 'active'
                  AND account.status = 'active'
                ON CONFLICT DO NOTHING
                RETURNING principal_id
            )
            SELECT status
            FROM locked_principal
        $function$
        $ddl$,
        target_schema
    );
    EXECUTE format(
        'REVOKE ALL ON FUNCTION %I.'
        'noop_ownership_lock_unified_principal(text, text, text) FROM PUBLIC',
        target_schema
    );
END
$migration$;

CREATE TEMP TABLE noop_migration_059_terminal_managed_links (
    principal_id uuid PRIMARY KEY,
    managed_account_id uuid NOT NULL UNIQUE,
    managed_identity_id uuid NOT NULL UNIQUE
) ON COMMIT DROP;

INSERT INTO noop_migration_059_terminal_managed_links (
    principal_id,
    managed_account_id,
    managed_identity_id
)
SELECT
    managed_link.principal_id,
    managed_link.managed_account_id,
    managed_link.managed_identity_id
FROM unified_managed_account_links AS managed_link
JOIN managed_external_identities AS identity
  ON identity.account_id = managed_link.managed_account_id
 AND identity.identity_id = managed_link.managed_identity_id
JOIN managed_accounts AS account
  ON account.account_id = identity.account_id
JOIN noop_schema_migrations AS migration_047
  ON migration_047.version = '047_unified_account_principals.sql'
 AND migration_047.checksum =
     '3159e5f01eff093e7048bae091f19e2128ae6f436e7fa14e33a4e8d56703d324'
WHERE managed_link.linked_at = migration_047.applied_at
  AND (
      (
        identity.status = 'revoked'
        AND identity.revoked_at IS NOT NULL
        AND identity.revoked_at <= migration_047.applied_at
      )
      OR (
        account.status = 'erased'
        AND account.erased_at IS NOT NULL
        AND account.erased_at <= migration_047.applied_at
      )
  );

CREATE TEMP TABLE noop_migration_059_retired_ownership_repairs (
    principal_id uuid PRIMARY KEY,
    ownership_account_id uuid NOT NULL UNIQUE,
    ownership_identity_id uuid NOT NULL UNIQUE,
    expected_retired_at timestamptz NOT NULL
) ON COMMIT DROP;

-- Migration 052 can already have removed the managed link, retired the
-- principal, and completed provider-identity deletion before this repair runs.
-- Revive only a principal whose exact retirement timestamp is backed by a
-- completed account erasure that removed a managed link, and only when the
-- matching ownership root already existed before that retirement.
INSERT INTO noop_migration_059_retired_ownership_repairs (
    principal_id,
    ownership_account_id,
    ownership_identity_id,
    expected_retired_at
)
SELECT DISTINCT
    principal.principal_id,
    ownership_identity.account_id,
    ownership_identity.identity_id,
    principal.retired_at
FROM unified_account_principals AS principal
JOIN ownership_external_identities AS ownership_identity
  ON ownership_identity.issuer = principal.issuer
 AND ownership_identity.provider_tenant = principal.provider_tenant
 AND ownership_identity.subject_hash = principal.subject_hash
JOIN ownership_accounts AS ownership_account
  ON ownership_account.account_id = ownership_identity.account_id
WHERE principal.status = 'retired'
  AND principal.retired_at IS NOT NULL
  AND principal.updated_at = principal.retired_at
  AND ownership_identity.status = 'active'
  AND ownership_account.status IN ('active', 'deletion_pending')
  AND ownership_identity.created_at <= principal.retired_at
  AND ownership_identity.verified_at <= principal.retired_at
  AND ownership_account.created_at <= principal.retired_at
  AND NOT EXISTS (
      SELECT 1
      FROM unified_managed_account_links AS managed_link
      WHERE managed_link.principal_id = principal.principal_id
  )
  AND NOT EXISTS (
      SELECT 1
      FROM unified_ownership_account_links AS ownership_link
      WHERE ownership_link.principal_id = principal.principal_id
  )
  AND EXISTS (
      SELECT 1
      FROM managed_account_cloud_erasure_tombstones AS tombstone
      JOIN managed_erasure_jobs AS job
        ON job.account_id = tombstone.account_id
       AND job.erasure_job_id = tombstone.erasure_job_id
      JOIN managed_accounts AS managed_account
        ON managed_account.account_id = tombstone.account_id
      WHERE tombstone.erasure_scope = 'account'
        AND tombstone.managed_identity_link_rows > 0
        AND tombstone.erased_at = principal.retired_at
        AND job.scope = 'account'
        AND job.status = 'completed'
        AND managed_account.status = 'erased'
  );

-- The affected rows predate the guarded erasure path. Permit only this
-- transaction to remove their dependent control-plane state and bad link.
SELECT set_config('noop.unified_principal_repair', '059', true);

-- Retired principals are ordinarily terminal. Permit only the exact
-- tombstone-backed candidates above to move back to active in this transaction.
-- The ordinary terminal guard is restored before commit.
DO $migration$
DECLARE
    target_schema name := current_schema();
BEGIN
    EXECUTE format(
        $ddl$
        CREATE OR REPLACE FUNCTION %1$I.noop_unified_principal_guard()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $function$
        DECLARE
            pending_reactivation boolean;
        BEGIN
            IF TG_OP = 'DELETE' THEN
                RAISE EXCEPTION 'unified account principals cannot be deleted'
                    USING ERRCODE = '23514';
            END IF;
            IF NEW.principal_id IS DISTINCT FROM OLD.principal_id
               OR NEW.issuer IS DISTINCT FROM OLD.issuer
               OR NEW.provider_tenant IS DISTINCT FROM OLD.provider_tenant
               OR NEW.subject_hash IS DISTINCT FROM OLD.subject_hash
               OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
                RAISE EXCEPTION 'unified account principal identity is immutable'
                    USING ERRCODE = '23514';
            END IF;
            IF NEW.version <> OLD.version + 1
               OR NEW.updated_at < OLD.updated_at THEN
                RAISE EXCEPTION 'unified account principal revision is invalid'
                    USING ERRCODE = '23514';
            END IF;

            pending_reactivation :=
                current_setting('noop.unified_principal_repair', true) = '059'
                AND OLD.status = 'retired'
                AND NEW.status = 'active'
                AND NEW.retired_at = OLD.retired_at
                AND EXISTS (
                    SELECT 1
                    FROM pg_temp.noop_migration_059_retired_ownership_repairs
                         AS repair
                    WHERE repair.principal_id = OLD.principal_id
                      AND repair.expected_retired_at = OLD.retired_at
                );

            IF OLD.status = 'retired'
               AND pending_reactivation IS NOT TRUE THEN
                RAISE EXCEPTION 'retired unified account principals are immutable'
                    USING ERRCODE = '23514';
            END IF;
            IF NEW.status = 'retired' AND NEW.retired_at IS NULL THEN
                RAISE EXCEPTION 'principal retirement requires a timestamp'
                    USING ERRCODE = '23514';
            END IF;
            RETURN NEW;
        END
        $function$
        $ddl$,
        target_schema
    );
END
$migration$;

-- Migration 056 ordinarily accepts links only for active accounts. During this
-- transaction, permit an active ownership identity on a deletion-pending
-- account to receive the missing historical link. The exact ordinary guard is
-- restored before commit.
DO $migration$
DECLARE
    target_schema name := current_schema();
BEGIN
    EXECUTE format(
        $ddl$
        CREATE OR REPLACE FUNCTION %1$I.noop_unified_account_link_guard()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $function$
        DECLARE
            identity_issuer text;
            identity_tenant text;
            identity_subject_hash char(64);
            identity_status text;
            account_status text;
            principal_status text;
            pending_ownership_repair boolean;
        BEGIN
            IF TG_OP <> 'INSERT' THEN
                RAISE EXCEPTION '%% is immutable', TG_TABLE_NAME
                    USING ERRCODE = '23514';
            END IF;

            SELECT status
            INTO principal_status
            FROM %1$I.unified_account_principals
            WHERE principal_id = NEW.principal_id
              AND issuer = NEW.issuer
              AND provider_tenant = NEW.provider_tenant
              AND subject_hash = NEW.subject_hash
            FOR SHARE;

            IF TG_TABLE_NAME = 'unified_managed_account_links' THEN
                SELECT identity.issuer,
                       identity.provider_tenant,
                       identity.subject_hash,
                       identity.status,
                       account.status
                INTO identity_issuer,
                     identity_tenant,
                     identity_subject_hash,
                     identity_status,
                     account_status
                FROM %1$I.managed_external_identities AS identity
                JOIN %1$I.managed_accounts AS account
                  ON account.account_id = identity.account_id
                WHERE identity.account_id = NEW.managed_account_id
                  AND identity.identity_id = NEW.managed_identity_id
                FOR SHARE OF identity, account;
            ELSIF TG_TABLE_NAME = 'unified_ownership_account_links' THEN
                SELECT identity.issuer,
                       identity.provider_tenant,
                       identity.subject_hash,
                       identity.status,
                       account.status
                INTO identity_issuer,
                     identity_tenant,
                     identity_subject_hash,
                     identity_status,
                     account_status
                FROM %1$I.ownership_external_identities AS identity
                JOIN %1$I.ownership_accounts AS account
                  ON account.account_id = identity.account_id
                WHERE identity.account_id = NEW.ownership_account_id
                  AND identity.identity_id = NEW.ownership_identity_id
                FOR SHARE OF identity, account;
            ELSE
                RAISE EXCEPTION 'unsupported unified account link table'
                    USING ERRCODE = '23514';
            END IF;

            pending_ownership_repair :=
                current_setting('noop.unified_principal_repair', true) = '059'
                AND TG_TABLE_NAME = 'unified_ownership_account_links'
                AND account_status = 'deletion_pending';

            IF principal_status IS DISTINCT FROM 'active'
               OR identity_status IS DISTINCT FROM 'active'
               OR (
                   account_status IS DISTINCT FROM 'active'
                   AND pending_ownership_repair IS NOT TRUE
               )
               OR identity_issuer IS NULL
               OR identity_issuer IS DISTINCT FROM NEW.issuer
               OR identity_tenant IS DISTINCT FROM NEW.provider_tenant
               OR identity_subject_hash IS DISTINCT FROM NEW.subject_hash THEN
                RAISE EXCEPTION
                    'unified account link identity is unavailable or mismatched'
                    USING ERRCODE = '23514';
            END IF;
            RETURN NEW;
        END
        $function$
        $ddl$,
        target_schema
    );
END
$migration$;

CREATE OR REPLACE FUNCTION noop_managed_authority_transition_delete_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF current_setting('noop.unified_principal_repair', true) = '059'
       OR noop_managed_account_erasure_context(OLD.managed_account_id) THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'managed authority transitions are append-only'
        USING ERRCODE = '23514';
END
$function$;

CREATE OR REPLACE FUNCTION noop_managed_authority_state_delete_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF current_setting('noop.unified_principal_repair', true) = '059'
       OR noop_managed_account_erasure_context(OLD.managed_account_id) THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'managed authority state cannot be deleted'
        USING ERRCODE = '23514';
END
$function$;

CREATE OR REPLACE FUNCTION noop_unified_managed_link_delete_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF current_setting('noop.unified_principal_repair', true) = '059'
       OR noop_managed_account_erasure_context(OLD.managed_account_id) THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'unified managed account links are immutable'
        USING ERRCODE = '23514';
END
$function$;

DELETE FROM managed_authority_transitions AS transition
USING noop_migration_059_terminal_managed_links AS repair
WHERE transition.managed_account_id = repair.managed_account_id;

DELETE FROM managed_authority_states AS state
USING noop_migration_059_terminal_managed_links AS repair
WHERE state.managed_account_id = repair.managed_account_id;

DELETE FROM unified_managed_account_links AS managed_link
USING noop_migration_059_terminal_managed_links AS repair
WHERE managed_link.principal_id = repair.principal_id
  AND managed_link.managed_account_id = repair.managed_account_id
  AND managed_link.managed_identity_id = repair.managed_identity_id;

-- Match managed erasure's dependent-row -> managed-link -> principal order.
-- Ownership registration locks the principal before inserting ownership rows,
-- so whichever transaction obtains this row lock first determines whether the
-- registration commits and is preserved or observes a retired principal.
DO $migration$
DECLARE
    locked_principal_id uuid;
BEGIN
    FOR locked_principal_id IN
        SELECT principal.principal_id
        FROM unified_account_principals AS principal
        JOIN (
            SELECT principal_id
            FROM noop_migration_059_terminal_managed_links
            UNION
            SELECT principal_id
            FROM noop_migration_059_retired_ownership_repairs
        ) AS repair
          ON repair.principal_id = principal.principal_id
        ORDER BY principal.principal_id
        FOR UPDATE OF principal
    LOOP
        NULL;
    END LOOP;
END
$migration$;

UPDATE unified_account_principals AS principal
SET status = 'active',
    version = principal.version + 1,
    updated_at = GREATEST(principal.updated_at, clock_timestamp())
FROM noop_migration_059_retired_ownership_repairs AS repair
WHERE principal.principal_id = repair.principal_id
  AND principal.status = 'retired'
  AND principal.retired_at = repair.expected_retired_at;

-- An active ownership identity can have appeared after migration 047 or after
-- migration 052 retired an otherwise orphaned principal. Link every exact
-- active principal/identity match before deciding whether a principal is now
-- orphaned. Preserve deletion-pending ownership accounts so cancellation can
-- return them to active state.
INSERT INTO unified_ownership_account_links (
    principal_id,
    ownership_account_id,
    ownership_identity_id,
    issuer,
    provider_tenant,
    subject_hash
)
SELECT
    principal.principal_id,
    identity.account_id,
    identity.identity_id,
    identity.issuer,
    identity.provider_tenant,
    identity.subject_hash
FROM unified_account_principals AS principal
JOIN ownership_external_identities AS identity
  ON identity.issuer = principal.issuer
 AND identity.provider_tenant = principal.provider_tenant
 AND identity.subject_hash = principal.subject_hash
JOIN ownership_accounts AS account
  ON account.account_id = identity.account_id
WHERE principal.status = 'active'
  AND identity.status = 'active'
  AND account.status IN ('active', 'deletion_pending')
  AND NOT EXISTS (
      SELECT 1
      FROM unified_ownership_account_links AS ownership_link
      WHERE ownership_link.principal_id = principal.principal_id
  )
ON CONFLICT DO NOTHING;

DO $migration$
DECLARE
    repair_time timestamptz := clock_timestamp();
BEGIN
    IF EXISTS (
        SELECT 1
        FROM unified_account_principals AS principal
        JOIN ownership_external_identities AS identity
          ON identity.issuer = principal.issuer
         AND identity.provider_tenant = principal.provider_tenant
         AND identity.subject_hash = principal.subject_hash
        JOIN ownership_accounts AS account
          ON account.account_id = identity.account_id
        LEFT JOIN unified_ownership_account_links AS ownership_link
          ON ownership_link.principal_id = principal.principal_id
         AND ownership_link.ownership_account_id = identity.account_id
         AND ownership_link.ownership_identity_id = identity.identity_id
        WHERE principal.status = 'active'
          AND identity.status = 'active'
          AND account.status IN ('active', 'deletion_pending')
          AND ownership_link.principal_id IS NULL
    ) THEN
        RAISE EXCEPTION
            'active ownership identity was not preserved during terminal repair'
            USING ERRCODE = 'check_violation';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM noop_migration_059_retired_ownership_repairs AS repair
        JOIN unified_account_principals AS principal
          ON principal.principal_id = repair.principal_id
        LEFT JOIN unified_ownership_account_links AS ownership_link
          ON ownership_link.principal_id = repair.principal_id
         AND ownership_link.ownership_account_id =
             repair.ownership_account_id
         AND ownership_link.ownership_identity_id =
             repair.ownership_identity_id
        WHERE principal.status IS DISTINCT FROM 'active'
           OR principal.retired_at IS DISTINCT FROM repair.expected_retired_at
           OR ownership_link.principal_id IS NULL
    ) THEN
        RAISE EXCEPTION
            'erasure-retired ownership principals were not restored'
            USING ERRCODE = 'check_violation';
    END IF;

    UPDATE unified_account_principals AS principal
    SET status = 'retired',
        version = principal.version + 1,
        updated_at = GREATEST(principal.updated_at, repair_time),
        retired_at = GREATEST(
            principal.created_at,
            principal.updated_at,
            repair_time
        )
    FROM noop_migration_059_terminal_managed_links AS repair
    WHERE principal.principal_id = repair.principal_id
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
      )
      AND NOT EXISTS (
          SELECT 1
          FROM ownership_external_identities AS identity
          JOIN ownership_accounts AS account
            ON account.account_id = identity.account_id
          WHERE identity.issuer = principal.issuer
            AND identity.provider_tenant = principal.provider_tenant
            AND identity.subject_hash = principal.subject_hash
            AND identity.status = 'active'
            AND account.status IN ('active', 'deletion_pending')
      );

    IF EXISTS (
        SELECT 1
        FROM noop_migration_059_terminal_managed_links AS repair
        JOIN unified_managed_account_links AS managed_link
          ON managed_link.principal_id = repair.principal_id
         AND managed_link.managed_account_id = repair.managed_account_id
         AND managed_link.managed_identity_id = repair.managed_identity_id
    ) THEN
        RAISE EXCEPTION
            'terminal managed identities remain linked to unified principals'
            USING ERRCODE = 'check_violation';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM noop_migration_059_terminal_managed_links AS repair
        JOIN managed_authority_states AS state
          ON state.managed_account_id = repair.managed_account_id
        UNION ALL
        SELECT 1
        FROM noop_migration_059_terminal_managed_links AS repair
        JOIN managed_authority_transitions AS transition
          ON transition.managed_account_id = repair.managed_account_id
    ) THEN
        RAISE EXCEPTION
            'terminal managed authority state remains after principal repair'
            USING ERRCODE = 'check_violation';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM unified_account_principals AS principal
        JOIN noop_migration_059_terminal_managed_links AS repair
          ON repair.principal_id = principal.principal_id
        WHERE principal.status = 'active'
          AND NOT EXISTS (
              SELECT 1
              FROM unified_managed_account_links AS managed_link
              WHERE managed_link.principal_id = principal.principal_id
          )
          AND NOT EXISTS (
              SELECT 1
              FROM unified_ownership_account_links AS ownership_link
              WHERE ownership_link.principal_id = principal.principal_id
          )
          AND NOT EXISTS (
              SELECT 1
              FROM ownership_external_identities AS identity
              JOIN ownership_accounts AS account
                ON account.account_id = identity.account_id
              WHERE identity.issuer = principal.issuer
                AND identity.provider_tenant = principal.provider_tenant
                AND identity.subject_hash = principal.subject_hash
                AND identity.status = 'active'
                AND account.status IN ('active', 'deletion_pending')
          )
    ) THEN
        RAISE EXCEPTION
            'orphaned unified principals remain active after terminal repair'
            USING ERRCODE = 'check_violation';
    END IF;
END
$migration$;

-- Restore the ordinary guards before the migration transaction commits.
DO $migration$
DECLARE
    target_schema name := current_schema();
BEGIN
    EXECUTE format(
        $ddl$
        CREATE OR REPLACE FUNCTION %1$I.noop_unified_principal_guard()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $function$
        BEGIN
            IF TG_OP = 'DELETE' THEN
                RAISE EXCEPTION 'unified account principals cannot be deleted'
                    USING ERRCODE = '23514';
            END IF;
            IF NEW.principal_id IS DISTINCT FROM OLD.principal_id
               OR NEW.issuer IS DISTINCT FROM OLD.issuer
               OR NEW.provider_tenant IS DISTINCT FROM OLD.provider_tenant
               OR NEW.subject_hash IS DISTINCT FROM OLD.subject_hash
               OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
                RAISE EXCEPTION 'unified account principal identity is immutable'
                    USING ERRCODE = '23514';
            END IF;
            IF NEW.version <> OLD.version + 1
               OR NEW.updated_at < OLD.updated_at THEN
                RAISE EXCEPTION 'unified account principal revision is invalid'
                    USING ERRCODE = '23514';
            END IF;
            IF OLD.status = 'retired' THEN
                RAISE EXCEPTION 'retired unified account principals are immutable'
                    USING ERRCODE = '23514';
            END IF;
            IF NEW.status = 'retired' AND NEW.retired_at IS NULL THEN
                RAISE EXCEPTION 'principal retirement requires a timestamp'
                    USING ERRCODE = '23514';
            END IF;
            RETURN NEW;
        END
        $function$
        $ddl$,
        target_schema
    );
END
$migration$;

DO $migration$
DECLARE
    target_schema name := current_schema();
BEGIN
    EXECUTE format(
        $ddl$
        CREATE OR REPLACE FUNCTION %1$I.noop_unified_account_link_guard()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $function$
        DECLARE
            identity_issuer text;
            identity_tenant text;
            identity_subject_hash char(64);
            identity_status text;
            account_status text;
            principal_status text;
        BEGIN
            IF TG_OP <> 'INSERT' THEN
                RAISE EXCEPTION '%% is immutable', TG_TABLE_NAME
                    USING ERRCODE = '23514';
            END IF;

            SELECT status
            INTO principal_status
            FROM %1$I.unified_account_principals
            WHERE principal_id = NEW.principal_id
              AND issuer = NEW.issuer
              AND provider_tenant = NEW.provider_tenant
              AND subject_hash = NEW.subject_hash
            FOR SHARE;

            IF TG_TABLE_NAME = 'unified_managed_account_links' THEN
                SELECT identity.issuer,
                       identity.provider_tenant,
                       identity.subject_hash,
                       identity.status,
                       account.status
                INTO identity_issuer,
                     identity_tenant,
                     identity_subject_hash,
                     identity_status,
                     account_status
                FROM %1$I.managed_external_identities AS identity
                JOIN %1$I.managed_accounts AS account
                  ON account.account_id = identity.account_id
                WHERE identity.account_id = NEW.managed_account_id
                  AND identity.identity_id = NEW.managed_identity_id
                FOR SHARE OF identity, account;
            ELSIF TG_TABLE_NAME = 'unified_ownership_account_links' THEN
                SELECT identity.issuer,
                       identity.provider_tenant,
                       identity.subject_hash,
                       identity.status,
                       account.status
                INTO identity_issuer,
                     identity_tenant,
                     identity_subject_hash,
                     identity_status,
                     account_status
                FROM %1$I.ownership_external_identities AS identity
                JOIN %1$I.ownership_accounts AS account
                  ON account.account_id = identity.account_id
                WHERE identity.account_id = NEW.ownership_account_id
                  AND identity.identity_id = NEW.ownership_identity_id
                FOR SHARE OF identity, account;
            ELSE
                RAISE EXCEPTION 'unsupported unified account link table'
                    USING ERRCODE = '23514';
            END IF;

            IF principal_status IS DISTINCT FROM 'active'
               OR identity_status IS DISTINCT FROM 'active'
               OR account_status IS DISTINCT FROM 'active'
               OR identity_issuer IS NULL
               OR identity_issuer IS DISTINCT FROM NEW.issuer
               OR identity_tenant IS DISTINCT FROM NEW.provider_tenant
               OR identity_subject_hash IS DISTINCT FROM NEW.subject_hash THEN
                RAISE EXCEPTION
                    'unified account link identity is unavailable or mismatched'
                    USING ERRCODE = '23514';
            END IF;
            RETURN NEW;
        END
        $function$
        $ddl$,
        target_schema
    );
END
$migration$;

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
