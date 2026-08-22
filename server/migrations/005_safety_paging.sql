-- Opt-in emergency-contact paging. Owner credentials and invitation
-- capabilities are stored only as SHA-256 digests. Pages contain no biometric
-- values and require at least two explicitly accepted contacts.

CREATE TABLE IF NOT EXISTS safety_profiles (
    profile_id uuid PRIMARY KEY,
    enrollment_id uuid NOT NULL UNIQUE,
    display_name text NOT NULL,
    installation_id text NOT NULL,
    token_hash char(64) NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    disabled_at timestamptz,
    CONSTRAINT safety_profile_display_name_length
        CHECK (char_length(display_name) BETWEEN 1 AND 64)
);

CREATE UNIQUE INDEX IF NOT EXISTS safety_profiles_one_active_installation_idx
    ON safety_profiles (installation_id)
    WHERE disabled_at IS NULL;

CREATE TABLE IF NOT EXISTS safety_contacts (
    contact_id uuid PRIMARY KEY,
    profile_id uuid NOT NULL REFERENCES safety_profiles(profile_id) ON DELETE CASCADE,
    display_name text NOT NULL,
    phone_e164 text NOT NULL,
    status text NOT NULL DEFAULT 'pending',
    invite_token_hash char(64) UNIQUE,
    invited_at timestamptz NOT NULL,
    invite_expires_at timestamptz NOT NULL,
    invitation_provider_reference text,
    invitation_delivery_status text NOT NULL DEFAULT 'pending',
    invitation_error text,
    accepted_at timestamptz,
    declined_at timestamptz,
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT safety_contact_display_name_length
        CHECK (char_length(display_name) BETWEEN 1 AND 64),
    CONSTRAINT safety_contact_phone_e164
        CHECK (phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
    CONSTRAINT safety_contact_status
        CHECK (status IN ('pending', 'accepted', 'declined', 'revoked')),
    CONSTRAINT safety_contact_delivery_status
        CHECK (invitation_delivery_status IN ('pending', 'queued', 'sent', 'delivered', 'failed')),
    CONSTRAINT safety_contact_invite_expiry
        CHECK (invite_expires_at > invited_at)
);

CREATE UNIQUE INDEX IF NOT EXISTS safety_contacts_active_phone_idx
    ON safety_contacts (profile_id, phone_e164)
    WHERE revoked_at IS NULL;

CREATE INDEX IF NOT EXISTS safety_contacts_profile_idx
    ON safety_contacts (profile_id, created_at)
    WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS safety_dispatches (
    dispatch_id uuid PRIMARY KEY,
    profile_id uuid NOT NULL REFERENCES safety_profiles(profile_id) ON DELETE RESTRICT,
    idempotency_key uuid NOT NULL,
    request_hash char(64) NOT NULL,
    trigger text NOT NULL,
    status text NOT NULL DEFAULT 'pending',
    created_at timestamptz NOT NULL,
    completed_at timestamptz,
    CONSTRAINT safety_dispatch_trigger CHECK (trigger IN ('manual_sos')),
    CONSTRAINT safety_dispatch_status
        CHECK (status IN ('pending', 'submitted', 'partial_failure', 'failed')),
    UNIQUE (profile_id, idempotency_key)
);

CREATE TABLE IF NOT EXISTS safety_deliveries (
    delivery_id uuid PRIMARY KEY,
    dispatch_id uuid NOT NULL REFERENCES safety_dispatches(dispatch_id) ON DELETE CASCADE,
    contact_id uuid NOT NULL REFERENCES safety_contacts(contact_id) ON DELETE RESTRICT,
    channel text NOT NULL,
    status text NOT NULL DEFAULT 'pending',
    provider_reference text,
    error text,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    CONSTRAINT safety_delivery_channel CHECK (channel IN ('sms', 'voice')),
    CONSTRAINT safety_delivery_status
        CHECK (status IN ('pending', 'submitting', 'queued', 'sent', 'delivered', 'failed')),
    UNIQUE (dispatch_id, contact_id, channel)
);

CREATE UNIQUE INDEX IF NOT EXISTS safety_delivery_provider_reference_idx
    ON safety_deliveries (provider_reference)
    WHERE provider_reference IS NOT NULL;
