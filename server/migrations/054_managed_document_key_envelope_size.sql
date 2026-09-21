-- Client-encrypted document keys use one canonical A256GCM wrap envelope:
-- 12-byte nonce, 32-byte ciphertext, 16-byte tag, and 12-byte binding prefix.
-- Account-master recovery wrappers remain provider-specific and retain the
-- broader size bound established by migration 050.

ALTER TABLE managed_document_keys
    ADD CONSTRAINT managed_document_key_document_wrapped_size
    CHECK (
        key_kind <> 'document'
        OR octet_length(wrapped_key) = 72
    ) NOT VALID;

ALTER TABLE managed_document_keys
    VALIDATE CONSTRAINT managed_document_key_document_wrapped_size;

ALTER TABLE managed_document_key_versions
    ADD CONSTRAINT managed_document_key_version_document_wrapped_size
    CHECK (
        key_kind <> 'document'
        OR octet_length(wrapped_key) = 72
    ) NOT VALID;

ALTER TABLE managed_document_key_versions
    VALIDATE CONSTRAINT
        managed_document_key_version_document_wrapped_size;
