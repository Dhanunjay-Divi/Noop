-- Opaque client-managed key material for encrypted personal documents.
-- The server never receives an unwrapped account master key or document key.

CREATE TABLE managed_document_keys (
    account_id uuid NOT NULL
        REFERENCES managed_accounts(account_id) ON DELETE RESTRICT,
    key_id uuid NOT NULL,
    key_kind text NOT NULL,
    wrapping_key_id uuid,
    wrapping_revision integer NOT NULL,
    algorithm text NOT NULL,
    wrapped_key bytea NOT NULL,
    wrapped_key_sha256 char(64) NOT NULL,
    recovery_method text,
    status text NOT NULL DEFAULT 'active',
    successor_key_id uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz,
    PRIMARY KEY (account_id, key_id),
    CONSTRAINT managed_document_key_kind
        CHECK (key_kind IN ('account_master', 'document')),
    CONSTRAINT managed_document_key_wrapping_revision
        CHECK (wrapping_revision > 0),
    CONSTRAINT managed_document_key_algorithm
        CHECK (algorithm = 'A256GCM'),
    CONSTRAINT managed_document_key_wrapped_size
        CHECK (octet_length(wrapped_key) BETWEEN 40 AND 16384),
    CONSTRAINT managed_document_key_wrapped_digest
        CHECK (wrapped_key_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_document_key_recovery_method
        CHECK (
            recovery_method IS NULL
            OR recovery_method IN (
                'recovery_key',
                'device_transfer',
                'platform_escrow'
            )
        ),
    CONSTRAINT managed_document_key_parent_contract
        CHECK (
            (
                key_kind = 'account_master'
                AND wrapping_key_id IS NULL
                AND recovery_method IS NOT NULL
            )
            OR (
                key_kind = 'document'
                AND wrapping_key_id IS NOT NULL
                AND wrapping_key_id <> key_id
                AND recovery_method IS NULL
            )
        ),
    CONSTRAINT managed_document_key_status
        CHECK (status IN ('active', 'retired', 'revoked')),
    CONSTRAINT managed_document_key_revocation
        CHECK (
            (status = 'revoked' AND revoked_at IS NOT NULL)
            OR (status <> 'revoked' AND revoked_at IS NULL)
        ),
    CONSTRAINT managed_document_key_successor
        CHECK (
            successor_key_id IS NULL
            OR successor_key_id <> key_id
        ),
    CONSTRAINT managed_document_key_successor_status
        CHECK (successor_key_id IS NULL OR status = 'revoked'),
    CONSTRAINT managed_document_key_updated
        CHECK (updated_at >= created_at)
);

ALTER TABLE managed_document_keys
    ADD CONSTRAINT managed_document_key_wrapping_fk
    FOREIGN KEY (account_id, wrapping_key_id)
    REFERENCES managed_document_keys(account_id, key_id)
    ON DELETE RESTRICT
    DEFERRABLE INITIALLY DEFERRED,
    ADD CONSTRAINT managed_document_key_successor_fk
    FOREIGN KEY (account_id, successor_key_id)
    REFERENCES managed_document_keys(account_id, key_id)
    ON DELETE RESTRICT
    DEFERRABLE INITIALLY DEFERRED;

CREATE TABLE managed_document_key_versions (
    account_id uuid NOT NULL,
    key_id uuid NOT NULL,
    key_kind text NOT NULL,
    wrapping_revision integer NOT NULL,
    wrapping_key_id uuid,
    algorithm text NOT NULL,
    wrapped_key bytea NOT NULL,
    wrapped_key_sha256 char(64) NOT NULL,
    recovery_method text,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, key_id, wrapping_revision),
    CONSTRAINT managed_document_key_version_key_fk
        FOREIGN KEY (account_id, key_id)
        REFERENCES managed_document_keys(account_id, key_id)
        ON DELETE RESTRICT
        DEFERRABLE INITIALLY DEFERRED,
    CONSTRAINT managed_document_key_version_kind
        CHECK (key_kind IN ('account_master', 'document')),
    CONSTRAINT managed_document_key_version_revision
        CHECK (wrapping_revision > 0),
    CONSTRAINT managed_document_key_version_algorithm
        CHECK (algorithm = 'A256GCM'),
    CONSTRAINT managed_document_key_version_wrapped_size
        CHECK (octet_length(wrapped_key) BETWEEN 40 AND 16384),
    CONSTRAINT managed_document_key_version_wrapped_digest
        CHECK (wrapped_key_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_document_key_version_recovery_method
        CHECK (
            recovery_method IS NULL
            OR recovery_method IN (
                'recovery_key',
                'device_transfer',
                'platform_escrow'
            )
        ),
    CONSTRAINT managed_document_key_version_parent_contract
        CHECK (
            (
                key_kind = 'account_master'
                AND wrapping_key_id IS NULL
                AND recovery_method IS NOT NULL
            )
            OR (
                key_kind = 'document'
                AND wrapping_key_id IS NOT NULL
                AND wrapping_key_id <> key_id
                AND recovery_method IS NULL
            )
        )
);

ALTER TABLE managed_document_key_versions
    ADD CONSTRAINT managed_document_key_version_wrapping_fk
    FOREIGN KEY (account_id, wrapping_key_id)
    REFERENCES managed_document_keys(account_id, key_id)
    ON DELETE RESTRICT
    DEFERRABLE INITIALLY DEFERRED;

CREATE INDEX managed_document_keys_active_idx
    ON managed_document_keys (
        account_id,
        key_kind,
        updated_at DESC,
        key_id
    )
    WHERE status = 'active';

CREATE INDEX managed_document_keys_wrapping_idx
    ON managed_document_keys (
        account_id,
        wrapping_key_id,
        status,
        key_id
    )
    WHERE wrapping_key_id IS NOT NULL;

CREATE INDEX managed_document_key_versions_history_idx
    ON managed_document_key_versions (
        account_id,
        key_id,
        wrapping_revision DESC
    );

CREATE OR REPLACE FUNCTION noop_managed_document_key_version_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    stored_key_kind text;
    parent_key_kind text;
    parent_status text;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'managed document key versions are append-only'
            USING ERRCODE = '23514';
    END IF;
    SELECT key_kind
    INTO stored_key_kind
    FROM managed_document_keys
    WHERE account_id = NEW.account_id
      AND key_id = NEW.key_id;
    IF stored_key_kind IS NULL OR stored_key_kind <> NEW.key_kind THEN
        RAISE EXCEPTION 'managed document key version kind is invalid'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.key_kind = 'document' THEN
        SELECT key_kind, status
        INTO parent_key_kind, parent_status
        FROM managed_document_keys
        WHERE account_id = NEW.account_id
          AND key_id = NEW.wrapping_key_id;
        IF parent_key_kind IS DISTINCT FROM 'account_master'
           OR parent_status IS DISTINCT FROM 'active' THEN
            RAISE EXCEPTION
                'active account master wrapping key is required'
                USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN NEW;
END
$function$;

CREATE TRIGGER managed_document_key_version_guard
BEFORE INSERT OR UPDATE OR DELETE ON managed_document_key_versions
FOR EACH ROW
EXECUTE FUNCTION noop_managed_document_key_version_guard();

CREATE OR REPLACE FUNCTION noop_managed_document_key_lifecycle_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    parent_key_kind text;
    parent_status text;
    successor_key_kind text;
    successor_status text;
    active_dependents boolean;
    cycle_found boolean;
    matching_version boolean;
    wrapping_changed boolean;
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'managed document keys cannot be deleted'
            USING ERRCODE = '23514';
    END IF;
    IF TG_OP = 'INSERT' THEN
        IF NEW.key_kind = 'document' THEN
            SELECT key_kind, status
            INTO parent_key_kind, parent_status
            FROM managed_document_keys
            WHERE account_id = NEW.account_id
              AND key_id = NEW.wrapping_key_id;
            IF parent_key_kind IS DISTINCT FROM 'account_master'
               OR parent_status IS DISTINCT FROM 'active' THEN
                RAISE EXCEPTION
                    'active account master wrapping key is required'
                    USING ERRCODE = '23514';
            END IF;
        END IF;
        RETURN NEW;
    END IF;
    IF NEW IS NOT DISTINCT FROM OLD THEN
        RETURN NEW;
    END IF;
    IF NEW.account_id IS DISTINCT FROM OLD.account_id
       OR NEW.key_id IS DISTINCT FROM OLD.key_id
       OR NEW.key_kind IS DISTINCT FROM OLD.key_kind
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
       OR NEW.updated_at < OLD.updated_at THEN
        RAISE EXCEPTION 'managed document key identity is immutable'
            USING ERRCODE = '23514';
    END IF;

    wrapping_changed := (
        NEW.wrapping_key_id IS DISTINCT FROM OLD.wrapping_key_id
        OR NEW.wrapping_revision IS DISTINCT FROM OLD.wrapping_revision
        OR NEW.algorithm IS DISTINCT FROM OLD.algorithm
        OR NEW.wrapped_key IS DISTINCT FROM OLD.wrapped_key
        OR NEW.wrapped_key_sha256 IS DISTINCT FROM OLD.wrapped_key_sha256
        OR NEW.recovery_method IS DISTINCT FROM OLD.recovery_method
    );
    IF wrapping_changed THEN
        IF OLD.key_kind <> 'document'
           OR OLD.status <> 'active'
           OR NEW.status <> 'active'
           OR NEW.wrapping_revision <> OLD.wrapping_revision + 1
           OR NEW.successor_key_id IS DISTINCT FROM OLD.successor_key_id
           OR NEW.revoked_at IS DISTINCT FROM OLD.revoked_at THEN
            RAISE EXCEPTION 'managed document key rotation is invalid'
                USING ERRCODE = '23514';
        END IF;
        SELECT key_kind, status
        INTO parent_key_kind, parent_status
        FROM managed_document_keys
        WHERE account_id = NEW.account_id
          AND key_id = NEW.wrapping_key_id;
        IF parent_key_kind IS DISTINCT FROM 'account_master'
           OR parent_status IS DISTINCT FROM 'active' THEN
            RAISE EXCEPTION
                'active account master wrapping key is required'
                USING ERRCODE = '23514';
        END IF;
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
              AND version.recovery_method
                    IS NOT DISTINCT FROM NEW.recovery_method
        ) INTO matching_version;
        IF matching_version IS NOT TRUE THEN
            RAISE EXCEPTION
                'managed document key rotation history is required'
                USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
    END IF;

    IF NEW.wrapping_key_id IS DISTINCT FROM OLD.wrapping_key_id
       OR NEW.wrapping_revision IS DISTINCT FROM OLD.wrapping_revision
       OR NEW.algorithm IS DISTINCT FROM OLD.algorithm
       OR NEW.wrapped_key IS DISTINCT FROM OLD.wrapped_key
       OR NEW.wrapped_key_sha256 IS DISTINCT FROM OLD.wrapped_key_sha256
       OR NEW.recovery_method IS DISTINCT FROM OLD.recovery_method
       OR OLD.status <> 'active'
       OR NEW.status <> 'revoked'
       OR NEW.revoked_at IS NULL THEN
        RAISE EXCEPTION 'managed document key revocation is invalid'
            USING ERRCODE = '23514';
    END IF;

    IF OLD.key_kind = 'account_master' THEN
        SELECT EXISTS (
            SELECT 1
            FROM managed_document_keys AS dependent
            WHERE dependent.account_id = OLD.account_id
              AND dependent.key_kind = 'document'
              AND dependent.wrapping_key_id = OLD.key_id
              AND dependent.status = 'active'
        ) INTO active_dependents;
        IF active_dependents IS TRUE THEN
            RAISE EXCEPTION
                'account master key has active dependent document keys'
                USING ERRCODE = '23514';
        END IF;
    END IF;

    IF NEW.successor_key_id IS NOT NULL THEN
        SELECT key_kind, status
        INTO successor_key_kind, successor_status
        FROM managed_document_keys
        WHERE account_id = NEW.account_id
          AND key_id = NEW.successor_key_id;
        IF successor_key_kind IS DISTINCT FROM OLD.key_kind
           OR successor_status IS DISTINCT FROM 'active' THEN
            RAISE EXCEPTION
                'managed document key successor must be active and same-kind'
                USING ERRCODE = '23514';
        END IF;
        WITH RECURSIVE successor_chain AS (
            SELECT key_id, successor_key_id, ARRAY[key_id] AS path
            FROM managed_document_keys
            WHERE account_id = NEW.account_id
              AND key_id = NEW.successor_key_id
            UNION ALL
            SELECT candidate.key_id,
                   candidate.successor_key_id,
                   chain.path || candidate.key_id
            FROM successor_chain AS chain
            JOIN managed_document_keys AS candidate
              ON candidate.account_id = NEW.account_id
             AND candidate.key_id = chain.successor_key_id
            WHERE NOT candidate.key_id = ANY(chain.path)
        )
        SELECT EXISTS (
            SELECT 1
            FROM successor_chain
            WHERE key_id = OLD.key_id
               OR successor_key_id = OLD.key_id
        ) INTO cycle_found;
        IF cycle_found IS TRUE THEN
            RAISE EXCEPTION 'managed document key successor cycle is invalid'
                USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN NEW;
END
$function$;

CREATE TRIGGER managed_document_key_lifecycle_guard
BEFORE INSERT OR UPDATE OR DELETE ON managed_document_keys
FOR EACH ROW
EXECUTE FUNCTION noop_managed_document_key_lifecycle_guard();

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

CREATE CONSTRAINT TRIGGER managed_document_key_current_version
AFTER INSERT OR UPDATE ON managed_document_keys
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION noop_managed_document_key_current_version();
