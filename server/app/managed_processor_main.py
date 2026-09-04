from __future__ import annotations

import base64
import binascii
import hashlib
import json
import re
from contextlib import asynccontextmanager
from dataclasses import dataclass

from fastapi import FastAPI, HTTPException, Request, Response, status

from app import __version__
from app.config import Settings
from app.main import RateLimitMiddleware, RequestSizeLimitMiddleware
from app.managed_object_store import (
    GCSV4ObjectStore,
    IAMBlobSigner,
    ManagedObjectStoreError,
)
from app.managed_processing import ManagedChunkProcessor
from app.managed_repository import (
    ManagedConflictError,
    ManagedNotFoundError,
    ManagedProcessingBusyError,
    PostgresManagedRepository,
)
from app.repository import PostgresRepository

OBJECT_KEY_RE = re.compile(
    r"^v1/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-"
    r"[0-9a-f]{4}-[0-9a-f]{12}/"
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-"
    r"[0-9a-f]{4}-[0-9a-f]{12}$"
)


@dataclass(frozen=True, slots=True)
class StorageFinalizeEvent:
    object_key: str
    generation: int
    event_hash: str


def parse_storage_finalize_event(
    body: object,
    *,
    expected_bucket: str,
) -> StorageFinalizeEvent:
    if not isinstance(body, dict):
        raise ValueError("Pub/Sub envelope must be an object")
    message = body.get("message")
    if not isinstance(message, dict):
        raise ValueError("Pub/Sub message is missing")
    encoded = message.get("data")
    if not isinstance(encoded, str) or not encoded:
        raise ValueError("Pub/Sub message data is missing")
    try:
        raw = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error):
        raise ValueError("Pub/Sub message data is invalid") from None
    if not raw or len(raw) > 65_536:
        raise ValueError("storage event exceeds its size contract")
    try:
        event = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise ValueError("storage event JSON is invalid") from None
    if not isinstance(event, dict):
        raise ValueError("storage event must be an object")
    bucket = event.get("bucket")
    object_key = event.get("name")
    generation_raw = event.get("generation")
    if bucket != expected_bucket:
        raise ValueError("storage event bucket does not match")
    if not isinstance(object_key, str) or OBJECT_KEY_RE.fullmatch(object_key) is None:
        raise ValueError("storage event object key is invalid")
    try:
        generation = int(generation_raw)
    except (TypeError, ValueError):
        raise ValueError("storage event generation is invalid") from None
    if generation <= 0 or str(generation) != str(generation_raw):
        raise ValueError("storage event generation is invalid")
    return StorageFinalizeEvent(
        object_key=object_key,
        generation=generation,
        event_hash=hashlib.sha256(raw).hexdigest(),
    )


def create_managed_processor_app(
    *,
    settings: Settings | None = None,
) -> FastAPI:
    runtime_settings = settings or Settings.from_env()
    primary = PostgresRepository(
        runtime_settings.database_url or "",
        pool_min_size=runtime_settings.pool_min_size,
        pool_max_size=runtime_settings.pool_max_size,
        statement_cache_size=runtime_settings.database_statement_cache_size,
        run_migrations=False,
        database_engine=runtime_settings.database_engine,
    )
    repository = PostgresManagedRepository(
        primary,
        home_region=runtime_settings.managed_home_region,
        residency_policy_version=(runtime_settings.managed_residency_policy_version),
        default_plan_code=runtime_settings.managed_default_plan_code,
        default_plan_revision=runtime_settings.managed_default_plan_revision,
        consent_policy_kind=runtime_settings.managed_consent_policy_kind,
        entitlement_mode=runtime_settings.managed_entitlement_mode,
        replay_secret=runtime_settings.managed_replay_secret or "",
    )
    object_store = GCSV4ObjectStore(
        bucket=runtime_settings.managed_raw_bucket or "",
        signer=IAMBlobSigner(runtime_settings.managed_signer_email or ""),
    )
    processor = ManagedChunkProcessor(
        repository,
        object_store,
        processor_revision="managed-json-v1",
    )

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        runtime_settings.validate_for_startup(
            needs_database=True,
            needs_api_token=False,
        )
        if (
            not runtime_settings.managed_raw_bucket
            or not runtime_settings.managed_signer_email
        ):
            raise RuntimeError(
                "managed processor requires NOOP_MANAGED_RAW_BUCKET and "
                "NOOP_MANAGED_SIGNER_EMAIL"
            )
        await primary.startup()
        try:
            yield
        finally:
            await primary.shutdown()

    app = FastAPI(
        title="NOOP+ Managed Processor",
        version=__version__,
        lifespan=lifespan,
        docs_url=None,
        redoc_url=None,
    )
    app.add_middleware(
        RequestSizeLimitMiddleware,
        max_bytes=min(runtime_settings.max_request_bytes, 1_000_000),
    )
    app.add_middleware(
        RateLimitMiddleware,
        credential_limit=runtime_settings.rate_limit_requests_per_minute,
        origin_limit=runtime_settings.rate_limit_origin_requests_per_minute,
        provider_callback_origin_limit=(
            runtime_settings.rate_limit_provider_callback_pre_auth_requests_per_minute
        ),
        max_keys=runtime_settings.rate_limit_max_keys,
    )

    @app.get("/healthz")
    async def health() -> dict[str, str]:
        return {"status": "ok", "service": "noop-managed-processor"}

    @app.get("/readyz")
    async def ready() -> dict[str, str]:
        if not await primary.ready():
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="managed processor is not ready",
            )
        return {"status": "ready", "service": "noop-managed-processor"}

    @app.post("/v1/events/storage-finalized", status_code=204)
    async def storage_finalized(request: Request) -> Response:
        try:
            body = await request.json()
            event = parse_storage_finalize_event(
                body,
                expected_bucket=runtime_settings.managed_raw_bucket or "",
            )
        except (ValueError, json.JSONDecodeError):
            return Response(status_code=status.HTTP_204_NO_CONTENT)
        try:
            await processor.process(
                object_key=event.object_key,
                generation=event.generation,
                queue_event_hash=event.event_hash,
            )
        except ManagedNotFoundError:
            return Response(status_code=status.HTTP_204_NO_CONTENT)
        except (ManagedObjectStoreError, ManagedProcessingBusyError):
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="managed object processing is temporarily unavailable",
                headers={"Retry-After": "10"},
            ) from None
        except ManagedConflictError:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="managed object processing conflicted with current state",
                headers={"Retry-After": "10"},
            ) from None
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    return app


app = create_managed_processor_app()
