from __future__ import annotations

from datetime import UTC, datetime
from urllib.error import HTTPError
from urllib.parse import parse_qs, urlsplit

import pytest

from app.managed_object_store import (
    GCSV4ObjectStore,
    IAMBlobSigner,
    StaticBlobSigner,
)


@pytest.mark.asyncio
async def test_upload_capability_is_create_only_and_contract_bound() -> None:
    now = datetime(2026, 9, 3, 12, 34, 56, tzinfo=UTC)
    signer = StaticBlobSigner("noop-api@example.iam.gserviceaccount.com")
    store = GCSV4ObjectStore(
        bucket="noop-private-bucket",
        signer=signer,
        clock=lambda: now,
    )

    capability = await store.upload_capability(
        object_key="v1/tenant/chunk",
        content_type="application/vnd.noop.chunk+protobuf",
        content_sha256="a" * 64,
        content_length=4096,
        expires_in_seconds=900,
    )

    parsed = urlsplit(capability.url)
    query = parse_qs(parsed.query)
    assert capability.method == "PUT"
    assert parsed.path == "/noop-private-bucket/v1/tenant/chunk"
    assert capability.headers["content-length"] == "4096"
    assert capability.headers["x-goog-if-generation-match"] == "0"
    assert capability.headers["x-goog-content-sha256"] == "a" * 64
    assert capability.headers["x-goog-meta-noop-sha256"] == "a" * 64
    assert query["X-Goog-Expires"] == ["900"]
    assert query["X-Goog-SignedHeaders"] == [
        "content-length;content-type;host;x-goog-content-sha256;"
        "x-goog-if-generation-match;x-goog-meta-noop-sha256"
    ]
    assert capability.expires_at.timestamp() - now.timestamp() == 900
    assert len(signer.payloads) == 1


@pytest.mark.asyncio
async def test_download_capability_is_generation_bound() -> None:
    now = datetime(2026, 9, 3, 12, tzinfo=UTC)
    store = GCSV4ObjectStore(
        bucket="noop-private-bucket",
        signer=StaticBlobSigner("noop-api@example.iam.gserviceaccount.com"),
        clock=lambda: now,
    )

    capability = await store.download_capability(
        object_key="v1/tenant/chunk",
        generation=42,
        expires_in_seconds=600,
    )

    query = parse_qs(urlsplit(capability.url).query)
    assert capability.method == "GET"
    assert query["generation"] == ["42"]
    assert query["X-Goog-Expires"] == ["600"]


@pytest.mark.asyncio
async def test_object_capability_rejects_unsafe_object_key() -> None:
    store = GCSV4ObjectStore(
        bucket="noop-private-bucket",
        signer=StaticBlobSigner("noop-api@example.iam.gserviceaccount.com"),
    )

    with pytest.raises(ValueError):
        await store.download_capability(
            object_key="/unexpected-root",
            generation=1,
            expires_in_seconds=600,
        )


@pytest.mark.asyncio
async def test_delete_treats_missing_generation_as_already_deleted(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    signer = IAMBlobSigner("noop-lifecycle@example.iam.gserviceaccount.com")
    monkeypatch.setattr(signer, "_access_token", lambda: "test-token")

    def missing(*args, **kwargs):
        raise HTTPError(
            url="https://storage.googleapis.com/test",
            code=404,
            msg="not found",
            hdrs=None,
            fp=None,
        )

    monkeypatch.setattr("urllib.request.urlopen", missing)
    store = GCSV4ObjectStore(
        bucket="noop-private-bucket",
        signer=signer,
    )

    await store.delete(
        object_key="v1/tenant/already-deleted",
        generation=42,
    )
