-- Bind newly encrypted personal documents to the opaque document-key registry
-- without rewriting historical rows that reference managed_client_keys.

ALTER TABLE managed_documents
    ADD COLUMN document_key_id uuid;

ALTER TABLE managed_documents
    ADD CONSTRAINT managed_document_document_key_fk
    FOREIGN KEY (account_id, document_key_id)
    REFERENCES managed_document_keys(account_id, key_id)
    ON DELETE RESTRICT
    NOT VALID;

ALTER TABLE managed_documents
    VALIDATE CONSTRAINT managed_document_document_key_fk;

ALTER TABLE managed_documents
    ADD CONSTRAINT managed_document_payload_v2
    CHECK (
        (
            deleted_at IS NOT NULL
            AND (
                client_key_id IS NULL
                OR document_key_id IS NULL
            )
            AND payload_json IS NULL
            AND payload_ciphertext IS NULL
        )
        OR (
            deleted_at IS NULL
            AND content_mode = 'server_readable'
            AND client_key_id IS NULL
            AND document_key_id IS NULL
            AND payload_json IS NOT NULL
            AND jsonb_typeof(payload_json) = 'object'
            AND pg_column_size(payload_json) <= 1048576
            AND payload_ciphertext IS NULL
        )
        OR (
            deleted_at IS NULL
            AND content_mode = 'client_encrypted'
            AND (
                (
                    client_key_id IS NOT NULL
                    AND document_key_id IS NULL
                )
                OR (
                    client_key_id IS NULL
                    AND document_key_id IS NOT NULL
                )
            )
            AND payload_json IS NULL
            AND payload_ciphertext IS NOT NULL
            AND octet_length(payload_ciphertext) BETWEEN 17 AND 1048576
        )
    ) NOT VALID;

ALTER TABLE managed_documents
    VALIDATE CONSTRAINT managed_document_payload_v2;

ALTER TABLE managed_documents
    DROP CONSTRAINT managed_document_payload;

ALTER TABLE managed_documents
    RENAME CONSTRAINT managed_document_payload_v2
    TO managed_document_payload;

CREATE INDEX managed_documents_document_key_idx
    ON managed_documents (account_id, document_key_id)
    WHERE document_key_id IS NOT NULL;

CREATE OR REPLACE FUNCTION noop_managed_document_key_authority_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    selected_kind text;
    selected_status text;
BEGIN
    IF NEW.document_key_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT key_kind, status
    INTO selected_kind, selected_status
    FROM managed_document_keys
    WHERE account_id = NEW.account_id
      AND key_id = NEW.document_key_id
    FOR SHARE;

    IF selected_kind IS DISTINCT FROM 'document'
       OR selected_status IS DISTINCT FROM 'active' THEN
        RAISE EXCEPTION
            'active account-scoped document key is required'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$function$;

CREATE TRIGGER managed_document_key_authority_guard
BEFORE INSERT OR UPDATE OF account_id, document_key_id
ON managed_documents
FOR EACH ROW
EXECUTE FUNCTION noop_managed_document_key_authority_guard();
