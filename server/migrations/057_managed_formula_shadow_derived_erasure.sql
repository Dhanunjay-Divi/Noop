-- Permit a verifying derived-data erasure job to remove formula shadow rows
-- without widening the authority/key erasure context.

CREATE OR REPLACE FUNCTION noop_managed_formula_shadow_erasure_context(
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
              AND job.status = 'verifying'
              AND (
                    (
                        job.scope = 'derived_data'
                        AND account.status = 'active'
                    )
                    OR (
                        job.scope IN ('all_managed_data', 'account')
                        AND account.status = 'erasure_pending'
                    )
                  )
        )
$function$;

CREATE OR REPLACE FUNCTION noop_managed_formula_shadow_delete_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF noop_managed_formula_shadow_erasure_context(OLD.account_id) THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'managed formula shadow results are append-only'
        USING ERRCODE = '23514';
END
$function$;
