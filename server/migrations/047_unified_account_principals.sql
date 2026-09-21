-- One Firebase identity root shared by the managed-health and first-party
-- ownership control planes. Provider subjects remain SHA-256 digests; email,
-- phone, token, and other direct identifiers do not belong in these tables.

CREATE TABLE unified_account_principals (
    principal_id uuid PRIMARY KEY,
    issuer text NOT NULL,
    provider_tenant text NOT NULL DEFAULT '',
    subject_hash char(64) NOT NULL,
    status text NOT NULL DEFAULT 'active',
    version bigint NOT NULL DEFAULT 1,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    retired_at timestamptz,
    CONSTRAINT unified_account_principal_key_unique
        UNIQUE (issuer, provider_tenant, subject_hash),
    CONSTRAINT unified_account_principal_scope_unique
        UNIQUE (
            principal_id,
            issuer,
            provider_tenant,
            subject_hash
        ),
    CONSTRAINT unified_account_principal_issuer
        CHECK (
            length(issuer) BETWEEN 1 AND 512
            AND issuer !~ '[[:space:]]'
        ),
    CONSTRAINT unified_account_principal_tenant
        CHECK (
            provider_tenant = ''
            OR provider_tenant ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
        ),
    CONSTRAINT unified_account_principal_subject_digest
        CHECK (subject_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT unified_account_principal_status
        CHECK (status IN ('active', 'retired')),
    CONSTRAINT unified_account_principal_version
        CHECK (version > 0),
    CONSTRAINT unified_account_principal_updated_order
        CHECK (updated_at >= created_at),
    CONSTRAINT unified_account_principal_retired_order
        CHECK (retired_at IS NULL OR retired_at >= created_at),
    CONSTRAINT unified_account_principal_status_time
        CHECK (status <> 'retired' OR retired_at IS NOT NULL)
);

CREATE INDEX unified_account_principals_status_idx
    ON unified_account_principals (status, updated_at);

CREATE TABLE unified_managed_account_links (
    principal_id uuid NOT NULL,
    managed_account_id uuid NOT NULL,
    managed_identity_id uuid NOT NULL,
    issuer text NOT NULL,
    provider_tenant text NOT NULL DEFAULT '',
    subject_hash char(64) NOT NULL,
    linked_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (principal_id),
    CONSTRAINT unified_managed_account_link_account_unique
        UNIQUE (managed_account_id),
    CONSTRAINT unified_managed_account_link_identity_unique
        UNIQUE (managed_identity_id),
    CONSTRAINT unified_managed_account_link_scope_unique
        UNIQUE (principal_id, managed_account_id),
    CONSTRAINT unified_managed_account_link_principal_fk
        FOREIGN KEY (
            principal_id,
            issuer,
            provider_tenant,
            subject_hash
        )
        REFERENCES unified_account_principals (
            principal_id,
            issuer,
            provider_tenant,
            subject_hash
        )
        ON DELETE RESTRICT,
    CONSTRAINT unified_managed_account_link_identity_fk
        FOREIGN KEY (managed_account_id, managed_identity_id)
        REFERENCES managed_external_identities (account_id, identity_id)
        ON DELETE RESTRICT
);

CREATE TABLE unified_ownership_account_links (
    principal_id uuid NOT NULL,
    ownership_account_id uuid NOT NULL,
    ownership_identity_id uuid NOT NULL,
    issuer text NOT NULL,
    provider_tenant text NOT NULL DEFAULT '',
    subject_hash char(64) NOT NULL,
    linked_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (principal_id),
    CONSTRAINT unified_ownership_account_link_account_unique
        UNIQUE (ownership_account_id),
    CONSTRAINT unified_ownership_account_link_identity_unique
        UNIQUE (ownership_identity_id),
    CONSTRAINT unified_ownership_account_link_scope_unique
        UNIQUE (principal_id, ownership_account_id),
    CONSTRAINT unified_ownership_account_link_principal_fk
        FOREIGN KEY (
            principal_id,
            issuer,
            provider_tenant,
            subject_hash
        )
        REFERENCES unified_account_principals (
            principal_id,
            issuer,
            provider_tenant,
            subject_hash
        )
        ON DELETE RESTRICT,
    CONSTRAINT unified_ownership_account_link_identity_fk
        FOREIGN KEY (ownership_account_id, ownership_identity_id)
        REFERENCES ownership_external_identities (account_id, identity_id)
        ON DELETE RESTRICT
);

CREATE OR REPLACE FUNCTION noop_unified_principal_guard()
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
$function$;

CREATE TRIGGER unified_account_principal_guard
BEFORE UPDATE OR DELETE ON unified_account_principals
FOR EACH ROW
EXECUTE FUNCTION noop_unified_principal_guard();

CREATE OR REPLACE FUNCTION noop_unified_account_link_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    identity_issuer text;
    identity_tenant text;
    identity_subject_hash char(64);
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION '% is immutable', TG_TABLE_NAME
            USING ERRCODE = '23514';
    END IF;

    IF TG_TABLE_NAME = 'unified_managed_account_links' THEN
        SELECT issuer, provider_tenant, subject_hash
        INTO identity_issuer, identity_tenant, identity_subject_hash
        FROM managed_external_identities
        WHERE account_id = NEW.managed_account_id
          AND identity_id = NEW.managed_identity_id;
    ELSIF TG_TABLE_NAME = 'unified_ownership_account_links' THEN
        SELECT issuer, provider_tenant, subject_hash
        INTO identity_issuer, identity_tenant, identity_subject_hash
        FROM ownership_external_identities
        WHERE account_id = NEW.ownership_account_id
          AND identity_id = NEW.ownership_identity_id;
    ELSE
        RAISE EXCEPTION 'unsupported unified account link table'
            USING ERRCODE = '23514';
    END IF;

    IF identity_issuer IS NULL
       OR identity_issuer IS DISTINCT FROM NEW.issuer
       OR identity_tenant IS DISTINCT FROM NEW.provider_tenant
       OR identity_subject_hash IS DISTINCT FROM NEW.subject_hash THEN
        RAISE EXCEPTION 'unified account link identity does not match principal'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$function$;

CREATE TRIGGER unified_managed_account_link_guard
BEFORE INSERT OR UPDATE OR DELETE ON unified_managed_account_links
FOR EACH ROW
EXECUTE FUNCTION noop_unified_account_link_guard();

CREATE TRIGGER unified_ownership_account_link_guard
BEFORE INSERT OR UPDATE OR DELETE ON unified_ownership_account_links
FOR EACH ROW
EXECUTE FUNCTION noop_unified_account_link_guard();

INSERT INTO unified_account_principals (
    principal_id,
    issuer,
    provider_tenant,
    subject_hash
)
SELECT
    gen_random_uuid(),
    existing.issuer,
    existing.provider_tenant,
    existing.subject_hash
FROM (
    SELECT issuer, provider_tenant, subject_hash
    FROM managed_external_identities
    UNION
    SELECT issuer, provider_tenant, subject_hash
    FROM ownership_external_identities
) AS existing
ON CONFLICT (issuer, provider_tenant, subject_hash) DO NOTHING;

INSERT INTO unified_managed_account_links (
    principal_id,
    managed_account_id,
    managed_identity_id,
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
FROM managed_external_identities AS identity
JOIN unified_account_principals AS principal
  ON principal.issuer = identity.issuer
 AND principal.provider_tenant = identity.provider_tenant
 AND principal.subject_hash = identity.subject_hash;

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
FROM ownership_external_identities AS identity
JOIN unified_account_principals AS principal
  ON principal.issuer = identity.issuer
 AND principal.provider_tenant = identity.provider_tenant
 AND principal.subject_hash = identity.subject_hash;
