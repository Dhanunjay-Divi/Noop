from __future__ import annotations

from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import uuid4

import pytest

from app.unified_identity_authority import (
    ALLOWED_AUTHORITY_TRANSITIONS,
    AuthorityEvidence,
    AuthorityTransitionRejectedError,
    ManagedAuthorityState,
    _transition_evidence,
    _transition_request_digest,
    _validate_transition_request,
)

MIGRATIONS = Path(__file__).resolve().parents[1] / "migrations"


def test_unified_identity_migrations_are_additive_and_account_scoped() -> None:
    identity_sql = (MIGRATIONS / "047_unified_account_principals.sql").read_text(
        encoding="utf-8"
    )
    authority_sql = (MIGRATIONS / "048_managed_authority_state.sql").read_text(
        encoding="utf-8"
    )

    assert "ALTER TABLE managed_accounts" not in identity_sql
    assert "ALTER TABLE ownership_accounts" not in identity_sql
    assert "SELECT issuer, provider_tenant, subject_hash" in identity_sql
    assert "FROM managed_external_identities" in identity_sql
    assert "FROM ownership_external_identities" in identity_sql
    assert "FOREIGN KEY (managed_account_id, managed_identity_id)" in identity_sql
    assert "FOREIGN KEY (ownership_account_id, ownership_identity_id)" in identity_sql
    assert "FOREIGN KEY (principal_id, managed_account_id)" in authority_sql
    assert "DEFERRABLE INITIALLY DEFERRED" in authority_sql
    assert "pruning_authorized_at >= restore_proven_at" in authority_sql


def test_authority_transition_graph_is_explicit_and_fail_closed() -> None:
    assert ALLOWED_AUTHORITY_TRANSITIONS == {
        "local_only": frozenset({"local_only", "uploading", "rollback"}),
        "uploading": frozenset({"shadow", "rollback"}),
        "shadow": frozenset({"parity_approved", "rollback"}),
        "parity_approved": frozenset({"restore_proven", "rollback"}),
        "restore_proven": frozenset({"cloud_authoritative", "rollback"}),
        "cloud_authoritative": frozenset({"rollback"}),
        "rollback": frozenset({"local_only", "uploading", "rollback"}),
    }


def test_authority_evidence_requires_exact_digest_and_utc_time() -> None:
    with pytest.raises(ValueError, match="SHA-256"):
        AuthorityEvidence(
            evidence_id=uuid4(),
            receipt_sha256="not-a-digest",
            recorded_at=datetime.now(UTC),
        )
    with pytest.raises(ValueError, match="UTC offset"):
        AuthorityEvidence(
            evidence_id=uuid4(),
            receipt_sha256="a" * 64,
            recorded_at=datetime.now().replace(tzinfo=None),
        )

    offset_time = datetime.now(UTC).astimezone()
    evidence = AuthorityEvidence(
        evidence_id=uuid4(),
        receipt_sha256="b" * 64,
        recorded_at=offset_time,
    )
    assert evidence.recorded_at.tzinfo is UTC


def test_transition_request_accepts_evidence_only_at_exact_gate() -> None:
    evidence = AuthorityEvidence(
        evidence_id=uuid4(),
        receipt_sha256="c" * 64,
        recorded_at=datetime.now(UTC),
    )

    _validate_transition_request(
        data_class="raw_motion",
        target_state="shadow",
        reason="upload_acknowledged",
        upload_acknowledgement=evidence,
        restore_proof=None,
        authorize_pruning=False,
    )
    with pytest.raises(AuthorityTransitionRejectedError, match="upload"):
        _validate_transition_request(
            data_class="raw_motion",
            target_state="shadow",
            reason="upload_acknowledged",
            upload_acknowledgement=None,
            restore_proof=None,
            authorize_pruning=False,
        )
    with pytest.raises(AuthorityTransitionRejectedError, match="pruning"):
        _validate_transition_request(
            data_class="raw_motion",
            target_state="parity_approved",
            reason="parity_approved",
            upload_acknowledgement=None,
            restore_proof=None,
            authorize_pruning=True,
        )
    with pytest.raises(AuthorityTransitionRejectedError, match="reason"):
        _validate_transition_request(
            data_class="raw_motion",
            target_state="rollback",
            reason="migration_started",
            upload_acknowledgement=None,
            restore_proof=None,
            authorize_pruning=False,
        )


def test_restore_proof_cannot_predate_upload_acknowledgement() -> None:
    now = datetime.now(UTC)
    state = {
        "upload_acknowledgement_id": uuid4(),
        "upload_acknowledgement_sha256": "d" * 64,
        "upload_acknowledged_at": now,
        "restore_proof_id": None,
        "restore_proof_sha256": None,
        "restore_proven_at": None,
    }
    restore = AuthorityEvidence(
        evidence_id=uuid4(),
        receipt_sha256="e" * 64,
        recorded_at=now - timedelta(seconds=1),
    )

    with pytest.raises(AuthorityTransitionRejectedError, match="predate"):
        _transition_evidence(
            state=state,
            target_state="restore_proven",
            upload_acknowledgement=None,
            restore_proof=restore,
            authorize_pruning=False,
            now=now + timedelta(seconds=1),
        )


def test_reconsent_requires_exact_policy_evidence() -> None:
    with pytest.raises(AuthorityTransitionRejectedError, match="policy"):
        _validate_transition_request(
            data_class="raw_motion",
            target_state="local_only",
            reason="reconsent_recorded",
            upload_acknowledgement=None,
            restore_proof=None,
            authorize_pruning=False,
        )

    _validate_transition_request(
        data_class="raw_motion",
        target_state="local_only",
        reason="reconsent_recorded",
        upload_acknowledgement=None,
        restore_proof=None,
        authorize_pruning=False,
        reconsent_policy_kind="managed_storage",
        reconsent_policy_version="staging-v2",
        reconsent_policy_sha256="a" * 64,
        reconsent_installation_id="ios-test-1",
    )


def test_authority_request_digest_binds_exact_evidence() -> None:
    now = datetime.now(UTC)
    first = AuthorityEvidence(
        evidence_id=uuid4(),
        receipt_sha256="f" * 64,
        recorded_at=now,
    )
    second = AuthorityEvidence(
        evidence_id=first.evidence_id,
        receipt_sha256="0" * 64,
        recorded_at=now,
    )

    first_digest = _transition_request_digest(
        target_state="shadow",
        reason="upload_acknowledged",
        upload_acknowledgement=first,
        restore_proof=None,
        authorize_pruning=False,
    )
    assert first_digest == _transition_request_digest(
        target_state="shadow",
        reason="upload_acknowledged",
        upload_acknowledgement=first,
        restore_proof=None,
        authorize_pruning=False,
    )
    assert first_digest != _transition_request_digest(
        target_state="shadow",
        reason="upload_acknowledged",
        upload_acknowledgement=second,
        restore_proof=None,
        authorize_pruning=False,
    )


def test_pruning_requires_cloud_state_ack_restore_and_authorization() -> None:
    now = datetime.now(UTC)
    base = {
        "principal_id": uuid4(),
        "managed_account_id": uuid4(),
        "data_class": "raw_motion",
        "state": "cloud_authoritative",
        "transition_version": 5,
        "upload_acknowledgement_id": uuid4(),
        "upload_acknowledgement_sha256": "1" * 64,
        "upload_acknowledged_at": now,
        "restore_proof_id": uuid4(),
        "restore_proof_sha256": "2" * 64,
        "restore_proven_at": now,
        "pruning_authorized_at": now,
        "last_opt_out_at": None,
        "last_reconsented_at": None,
        "reconsent_consent_event_id": None,
        "reconsent_policy_version": None,
        "reconsent_policy_sha256": None,
    }

    assert ManagedAuthorityState(**base).pruning_authorized is True
    assert (
        ManagedAuthorityState(
            **{**base, "pruning_authorized_at": None}
        ).pruning_authorized
        is False
    )
    assert (
        ManagedAuthorityState(**{**base, "state": "rollback"}).pruning_authorized
        is False
    )
