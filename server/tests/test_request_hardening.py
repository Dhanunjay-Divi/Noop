from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import AsyncMock

from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app
from app.repository import MemoryRepository


TOKEN = "request-limit-test-token-abcdefghijklmnopqrstuvwxyz"
FIXTURES = Path(__file__).resolve().parent / "data"


def _small_client(max_request_bytes: int = 128) -> TestClient:
    return TestClient(
        create_app(
            settings=Settings(
                api_token=TOKEN,
                database_url=None,
                max_request_bytes=max_request_bytes,
            ),
            repository=MemoryRepository(),
        )
    )


def _contains_input_key(value: object) -> bool:
    if isinstance(value, dict):
        return "input" in value or any(
            _contains_input_key(item) for item in value.values()
        )
    if isinstance(value, list):
        return any(_contains_input_key(item) for item in value)
    return False


def test_global_limit_rejects_oversized_public_invite_body() -> None:
    with _small_client() as client:
        response = client.post(
            "/v1/social/invites/join",
            content=b"x" * 129,
            headers={"Content-Type": "application/json"},
        )

    assert response.status_code == 413
    assert response.json() == {"detail": "request body is too large"}


def test_global_limit_counts_streamed_chunks_without_content_length() -> None:
    def chunks():
        yield b'{"display_name":"'
        yield b"x" * 128
        yield b'"}'

    with _small_client() as client:
        response = client.post(
            "/v1/social/invites/join",
            content=chunks(),
            headers={"Content-Type": "application/json"},
        )

    assert "content-length" not in response.request.headers
    assert response.status_code == 413
    assert response.json() == {"detail": "request body is too large"}


def test_global_limit_also_precedes_authenticated_sync_parsing() -> None:
    with _small_client() as client:
        response = client.post(
            "/v1/sync",
            content=b"x" * 129,
            headers={
                "Authorization": f"Bearer {TOKEN}",
                "Content-Type": "application/json",
            },
        )

    assert response.status_code == 413


def test_sync_validation_never_reflects_invalid_input_values(
    client: TestClient,
    auth_headers: dict[str, str],
) -> None:
    payload = json.loads((FIXTURES / "apple_sync_v1.json").read_text())
    sensitive_value = "private-biometric-input-that-must-not-be-reflected"
    payload["streams"]["rr"][0]["value"] = sensitive_value

    response = client.post("/v1/sync", headers=auth_headers, json=payload)

    assert response.status_code == 422
    assert sensitive_value not in response.text
    assert not _contains_input_key(response.json()["detail"])


def test_liveness_and_database_readiness_are_distinct() -> None:
    repository = MemoryRepository()
    repository.ready = AsyncMock(return_value=False)  # type: ignore[method-assign]
    app = create_app(
        settings=Settings(api_token=TOKEN, database_url=None),
        repository=repository,
    )
    with TestClient(app) as client:
        assert client.get("/healthz").json() == {"status": "ok"}
        unavailable = client.get("/readyz")

    assert unavailable.status_code == 503
    assert unavailable.json() == {"status": "not_ready"}
    assert unavailable.headers["cache-control"] == "no-store"


def test_rate_limit_is_per_credential_and_exempts_health_probes() -> None:
    app = create_app(
        settings=Settings(
            api_token=TOKEN,
            database_url=None,
            rate_limit_requests_per_minute=2,
            rate_limit_origin_requests_per_minute=20,
        ),
        repository=MemoryRepository(),
    )
    with TestClient(app) as client:
        headers = {"Authorization": f"Bearer {TOKEN}"}
        assert client.get("/v1/status", headers=headers).status_code == 200
        alternate_scheme = {"Authorization": f"bearer {TOKEN}"}
        assert client.get("/v1/status", headers=alternate_scheme).status_code == 200
        limited = client.get("/v1/status", headers=headers)
        assert client.get("/healthz").status_code == 200
        assert client.get("/readyz").status_code == 200

    assert limited.status_code == 429
    assert limited.json() == {"detail": "request rate limit exceeded"}
    assert limited.headers["x-noop-ratelimit-scope"] == "credential"
    assert int(limited.headers["retry-after"]) >= 1


def test_rate_limit_bounds_unauthenticated_requests_by_direct_peer() -> None:
    app = create_app(
        settings=Settings(
            api_token=TOKEN,
            database_url=None,
            rate_limit_requests_per_minute=20,
            rate_limit_origin_requests_per_minute=2,
        ),
        repository=MemoryRepository(),
    )
    with TestClient(app) as client:
        assert client.get("/v1/status").status_code == 401
        assert client.get("/v1/status").status_code == 401
        limited = client.get("/v1/status")

    assert limited.status_code == 429
    assert limited.headers["x-noop-ratelimit-scope"] == "origin"
