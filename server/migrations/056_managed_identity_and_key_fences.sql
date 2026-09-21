-- Close the final account-erasure and encrypted-document lifecycle races.

CREATE OR REPLACE FUNCTION noop_managed_document_key_reference_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF OLD.key_kind = 'document'
       AND OLD.status <> 'revoked'
       AND NEW.status = 'revoked'
       AND EXISTS (
            SELECT 1
            FROM managed_documents AS document
            WHERE document.account_id = OLD.account_id
              AND document.document_key_id = OLD.key_id
              AND document.deleted_at IS NULL
       ) THEN
        RAISE EXCEPTION 'document key is still referenced by live documents'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$function$;

CREATE TRIGGER managed_document_key_reference_guard
BEFORE UPDATE OF status ON managed_document_keys
FOR EACH ROW
EXECUTE FUNCTION noop_managed_document_key_reference_guard();

CREATE OR REPLACE FUNCTION noop_unified_account_link_guard()
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
        RAISE EXCEPTION '% is immutable', TG_TABLE_NAME
            USING ERRCODE = '23514';
    END IF;

    SELECT status
    INTO principal_status
    FROM unified_account_principals
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
        FROM managed_external_identities AS identity
        JOIN managed_accounts AS account
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
        FROM ownership_external_identities AS identity
        JOIN ownership_accounts AS account
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
        RAISE EXCEPTION 'unified account link identity is unavailable or mismatched'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$function$;
