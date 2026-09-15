from __future__ import annotations

import hashlib

from app.managed_identity import ManagedIdentityClaims


FEEDBACK_LEGACY_PRINCIPAL_HASH_VERSION = 0
FEEDBACK_PRINCIPAL_HASH_VERSION = 1


def feedback_principal_hash(claims: ManagedIdentityClaims) -> str:
    payload = (
        b"noop-feedback-principal-v1\0"
        + claims.issuer.encode("utf-8")
        + b"\0"
        + claims.provider_tenant.encode("utf-8")
        + b"\0"
        + claims.subject.encode("utf-8")
    )
    return hashlib.sha256(payload).hexdigest()


def feedback_principal_matches(
    *,
    stored_version: int,
    stored_hash: str,
    claims: ManagedIdentityClaims,
) -> bool:
    # Version 0 contains only a subject hash. It cannot prove the Firebase
    # issuer or tenant, so it must remain lifecycle-only and fail closed.
    return (
        stored_version == FEEDBACK_PRINCIPAL_HASH_VERSION
        and stored_hash == feedback_principal_hash(claims)
    )
