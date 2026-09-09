-- Firebase Messaging registration callbacks provide an FCM registration
-- token on both platforms. Retain the former iOS "fid" label only for rolling
-- compatibility with already installed pre-fix clients and stored rows; the
-- provider always addresses FCM through message.token.

ALTER TABLE managed_push_installations
    DROP CONSTRAINT IF EXISTS managed_push_installation_target_kind;

ALTER TABLE managed_push_installations
    ADD CONSTRAINT managed_push_installation_target_kind
    CHECK (
        (
            platform = 'ios'
            AND target_kind IN ('token', 'fid')
        )
        OR (
            platform = 'android'
            AND target_kind = 'token'
        )
    );
