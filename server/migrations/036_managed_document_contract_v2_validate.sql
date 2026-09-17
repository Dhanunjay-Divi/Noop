-- Validate only the additive kind registry. The future content-mode contract
-- remains deliberately absent until client encryption and recovery are ready.

DO $managed_document_contract_v2_validate$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'managed_document_kind_v2'
          AND conrelid = 'managed_documents'::regclass
          AND NOT convalidated
    ) THEN
        ALTER TABLE managed_documents
            VALIDATE CONSTRAINT managed_document_kind_v2;
    END IF;
END
$managed_document_contract_v2_validate$;
