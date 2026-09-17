-- Activate only the validated additive kind registry. A stricter content-mode
-- contract must ship later behind client encryption and restore version gates.

DO $managed_document_contract_v2_activate$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'managed_document_kind_v2'
          AND conrelid = 'managed_documents'::regclass
    ) THEN
        IF EXISTS (
            SELECT 1
            FROM pg_constraint
            WHERE conname = 'managed_document_kind'
              AND conrelid = 'managed_documents'::regclass
        ) THEN
            ALTER TABLE managed_documents
                DROP CONSTRAINT managed_document_kind;
        END IF;
        ALTER TABLE managed_documents
            RENAME CONSTRAINT managed_document_kind_v2
            TO managed_document_kind;
    END IF;
END
$managed_document_contract_v2_activate$;
