from __future__ import annotations

import io
import json
import urllib.request
from urllib.error import HTTPError
from uuid import uuid4

import pytest

from app.managed_identity_deletion import (
    IdentityToolkitAccountDeleter,
    ManagedIdentityDeletionError,
    ManagedIdentityDeletionTicketCodec,
    ManagedIdentityDeletionTicketError,
)


def test_identity_deletion_ticket_is_bound_and_contains_no_plaintext() -> None:
    codec = ManagedIdentityDeletionTicketCodec(
        "managed-replay-secret-at-least-32-bytes",
        random_bytes=lambda count: b"n" * count,
    )
    account_id = uuid4()
    request_id = uuid4()

    ticket = codec.seal(
        local_id="firebase-user-1",
        provider_tenant="noop-staging",
        account_id=account_id,
        request_id=request_id,
    )

    assert b"firebase-user-1" not in ticket
    assert b"noop-staging" not in ticket
    assert (
        codec.open(
            ticket=ticket,
            account_id=account_id,
            request_id=request_id,
        ).local_id
        == "firebase-user-1"
    )
    with pytest.raises(ManagedIdentityDeletionTicketError):
        codec.open(
            ticket=ticket,
            account_id=uuid4(),
            request_id=request_id,
        )


@pytest.mark.asyncio
async def test_identity_deleter_uses_oauth_local_id_and_tenant_path(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    codec = ManagedIdentityDeletionTicketCodec(
        "managed-replay-secret-at-least-32-bytes"
    )
    account_id = uuid4()
    request_id = uuid4()
    ticket = codec.seal(
        local_id="firebase-user-1",
        provider_tenant="noop-staging",
        account_id=account_id,
        request_id=request_id,
    )
    deleter = IdentityToolkitAccountDeleter(
        project_id="noop-test-project",
        ticket_codec=codec,
    )
    monkeypatch.setattr(deleter, "_access_token", lambda: "service-token")
    captured: list[urllib.request.Request] = []

    class Response:
        status = 200

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return None

    def respond(request, **kwargs):
        del kwargs
        captured.append(request)
        return Response()

    monkeypatch.setattr("urllib.request.urlopen", respond)

    await deleter.delete(
        ticket=ticket,
        account_id=account_id,
        request_id=request_id,
    )

    assert len(captured) == 1
    request = captured[0]
    assert request.full_url.endswith(
        "/noop-test-project/tenants/noop-staging/accounts:delete"
    )
    assert request.headers["Authorization"] == "Bearer service-token"
    assert json.loads(request.data or b"{}") == {
        "localId": "firebase-user-1",
        "targetProjectId": "noop-test-project",
        "tenantId": "noop-staging",
    }


@pytest.mark.asyncio
async def test_identity_deleter_treats_missing_user_as_idempotent_success(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    codec = ManagedIdentityDeletionTicketCodec(
        "managed-replay-secret-at-least-32-bytes"
    )
    account_id = uuid4()
    request_id = uuid4()
    ticket = codec.seal(
        local_id="already-deleted",
        provider_tenant="",
        account_id=account_id,
        request_id=request_id,
    )
    deleter = IdentityToolkitAccountDeleter(
        project_id="noop-test-project",
        ticket_codec=codec,
    )
    monkeypatch.setattr(deleter, "_access_token", lambda: "service-token")

    def missing(*args, **kwargs):
        del args, kwargs
        raise HTTPError(
            url="https://identitytoolkit.googleapis.com/test",
            code=400,
            msg="bad request",
            hdrs=None,
            fp=io.BytesIO(
                json.dumps({"error": {"message": "USER_NOT_FOUND"}}).encode("utf-8")
            ),
        )

    monkeypatch.setattr("urllib.request.urlopen", missing)

    await deleter.delete(
        ticket=ticket,
        account_id=account_id,
        request_id=request_id,
    )


@pytest.mark.asyncio
async def test_identity_deleter_preserves_retry_on_provider_failure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    codec = ManagedIdentityDeletionTicketCodec(
        "managed-replay-secret-at-least-32-bytes"
    )
    account_id = uuid4()
    request_id = uuid4()
    ticket = codec.seal(
        local_id="firebase-user-1",
        provider_tenant="",
        account_id=account_id,
        request_id=request_id,
    )
    deleter = IdentityToolkitAccountDeleter(
        project_id="noop-test-project",
        ticket_codec=codec,
    )
    monkeypatch.setattr(deleter, "_access_token", lambda: "service-token")

    def unavailable(*args, **kwargs):
        del args, kwargs
        raise HTTPError(
            url="https://identitytoolkit.googleapis.com/test",
            code=503,
            msg="unavailable",
            hdrs=None,
            fp=io.BytesIO(b"{}"),
        )

    monkeypatch.setattr("urllib.request.urlopen", unavailable)

    with pytest.raises(ManagedIdentityDeletionError):
        await deleter.delete(
            ticket=ticket,
            account_id=account_id,
            request_id=request_id,
        )
