-- Bind new opaque account-master recovery receipts to the client-held key.
-- The server stores only an HMAC confirmation; it never receives plaintext
-- account-master or document keys.

ALTER TABLE managed_document_keys
    ADD COLUMN master_key_confirmation_hmac_sha256 char(64),
    ADD CONSTRAINT managed_document_key_master_confirmation_format
        CHECK (
            master_key_confirmation_hmac_sha256 IS NULL
            OR master_key_confirmation_hmac_sha256 ~ '^[0-9a-f]{64}$'
        ),
    ADD CONSTRAINT managed_document_key_document_confirmation_absent
        CHECK (
            key_kind <> 'document'
            OR master_key_confirmation_hmac_sha256 IS NULL
        );

ALTER TABLE managed_document_key_versions
    ADD COLUMN master_key_confirmation_hmac_sha256 char(64),
    ADD CONSTRAINT managed_document_key_version_master_confirmation_format
        CHECK (
            master_key_confirmation_hmac_sha256 IS NULL
            OR master_key_confirmation_hmac_sha256 ~ '^[0-9a-f]{64}$'
        ),
    ADD CONSTRAINT managed_document_key_version_document_confirmation_absent
        CHECK (
            key_kind <> 'document'
            OR master_key_confirmation_hmac_sha256 IS NULL
        );

CREATE OR REPLACE FUNCTION noop_managed_master_key_confirmation_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.key_kind = 'account_master'
           AND NEW.master_key_confirmation_hmac_sha256 IS NULL THEN
            RAISE EXCEPTION
                'new account master keys require client confirmation'
                USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.master_key_confirmation_hmac_sha256
       IS DISTINCT FROM OLD.master_key_confirmation_hmac_sha256 THEN
        RAISE EXCEPTION
            'account master key confirmation is immutable'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$function$;

CREATE TRIGGER managed_document_key_confirmation_guard
BEFORE INSERT OR UPDATE ON managed_document_keys
FOR EACH ROW
EXECUTE FUNCTION noop_managed_master_key_confirmation_guard();

CREATE OR REPLACE FUNCTION noop_managed_master_key_version_confirmation_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.key_kind = 'account_master'
       AND NEW.master_key_confirmation_hmac_sha256 IS NULL THEN
        RAISE EXCEPTION
            'new account master key versions require client confirmation'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$function$;

CREATE TRIGGER managed_master_key_version_confirmation_guard
BEFORE INSERT ON managed_document_key_versions
FOR EACH ROW
EXECUTE FUNCTION noop_managed_master_key_version_confirmation_guard();

CREATE OR REPLACE FUNCTION noop_managed_document_key_current_version()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    matching_version boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1
        FROM managed_document_key_versions AS version
        WHERE version.account_id = NEW.account_id
          AND version.key_id = NEW.key_id
          AND version.key_kind = NEW.key_kind
          AND version.wrapping_revision = NEW.wrapping_revision
          AND version.wrapping_key_id
                IS NOT DISTINCT FROM NEW.wrapping_key_id
          AND version.algorithm = NEW.algorithm
          AND version.wrapped_key = NEW.wrapped_key
          AND version.wrapped_key_sha256 = NEW.wrapped_key_sha256
          AND version.master_key_confirmation_hmac_sha256
                IS NOT DISTINCT FROM
                    NEW.master_key_confirmation_hmac_sha256
          AND version.recovery_method
                IS NOT DISTINCT FROM NEW.recovery_method
    ) INTO matching_version;
    IF matching_version IS NOT TRUE THEN
        RAISE EXCEPTION
            'managed document key current version is not recoverable'
            USING ERRCODE = '23514';
    END IF;
    RETURN NULL;
END
$function$;
