from __future__ import annotations

from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Request, status
from fastapi.encoders import jsonable_encoder
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from app import __version__
from app.config import Settings
from app.main import (
    RateLimitMiddleware,
    RequestSizeLimitMiddleware,
    _validation_errors_without_inputs,
)
from app.managed_api import managed_router
from app.managed_app_check import FirebaseAppCheckTokenVerifier
from app.managed_identity import IdentityToolkitTokenVerifier
from app.managed_identity_deletion import ManagedIdentityDeletionTicketCodec
from app.managed_object_store import GCSV4ObjectStore, IAMBlobSigner
from app.managed_push import (
    FirebaseCloudMessagingProvider,
    ManagedPushTokenCodec,
    UnavailableManagedPushProvider,
)
from app.managed_repository import PostgresManagedRepository
from app.managed_safety_repository import (
    ManagedSafetyPushService,
    PostgresManagedSafetyRepository,
)
from app.observability import (
    RequestObservabilityMiddleware,
    internal_server_error_response,
)
from app.repository import PostgresRepository


def create_managed_app(*, settings: Settings | None = None) -> FastAPI:
    runtime_settings = settings or Settings.from_env()
    primary = PostgresRepository(
        runtime_settings.database_url or "",
        pool_min_size=runtime_settings.pool_min_size,
        pool_max_size=runtime_settings.pool_max_size,
        statement_cache_size=runtime_settings.database_statement_cache_size,
        run_migrations=runtime_settings.run_migrations,
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
    verifier = IdentityToolkitTokenVerifier(
        project_id=runtime_settings.managed_project_id or "",
        api_key=runtime_settings.managed_identity_api_key or "",
        cache_seconds=runtime_settings.managed_identity_cache_seconds,
        cache_entries=runtime_settings.managed_identity_cache_entries,
    )
    app_check_verifier = FirebaseAppCheckTokenVerifier(
        project_number=runtime_settings.managed_project_number or "",
        allowed_app_ids=frozenset(
            {
                runtime_settings.managed_apple_app_id or "",
                runtime_settings.managed_android_app_id or "",
            }
        ),
        jwks_cache_seconds=runtime_settings.managed_app_check_cache_seconds,
    )
    object_store = GCSV4ObjectStore(
        bucket=runtime_settings.managed_raw_bucket or "",
        signer=IAMBlobSigner(runtime_settings.managed_signer_email or ""),
    )
    identity_deletion_ticket_codec = ManagedIdentityDeletionTicketCodec(
        runtime_settings.managed_replay_secret or ""
    )
    safety_repository = PostgresManagedSafetyRepository(primary)
    safety_push_service = None
    if runtime_settings.managed_push_token_secret:
        token_codec = ManagedPushTokenCodec(
            runtime_settings.managed_push_token_secret,
            previous_secrets=(
                (runtime_settings.managed_push_token_previous_secret,)
                if runtime_settings.managed_push_token_previous_secret
                else ()
            ),
            write_version=runtime_settings.managed_push_token_write_version,
        )
        provider = (
            FirebaseCloudMessagingProvider(
                project_id=runtime_settings.managed_project_id or "",
                timeout_seconds=(runtime_settings.managed_push_timeout_seconds),
            )
            if runtime_settings.managed_push_enabled
            else UnavailableManagedPushProvider()
        )
        safety_push_service = ManagedSafetyPushService(
            repository=safety_repository,
            token_codec=token_codec,
            provider=provider,
            max_concurrency=(runtime_settings.managed_push_max_concurrency),
        )

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        if not runtime_settings.managed_storage_enabled:
            raise RuntimeError(
                "NOOP_MANAGED_STORAGE_ENABLED must be true for managed API"
            )
        runtime_settings.validate_for_startup(
            needs_database=True,
            needs_api_token=False,
        )
        await primary.startup()
        try:
            yield
        finally:
            await primary.shutdown()

    app = FastAPI(
        title="NOOP+ Managed Storage",
        summary="Optional managed backup and multi-device sync",
        version=__version__,
        lifespan=lifespan,
        docs_url=None,
        redoc_url=None,
    )
    app.state.settings = runtime_settings
    app.state.repository = repository
    app.state.object_store = object_store
    app.add_middleware(
        RequestSizeLimitMiddleware,
        max_bytes=runtime_settings.max_request_bytes,
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
    app.add_middleware(
        RequestObservabilityMiddleware,
        service="noop-managed-api",
    )
    app.add_exception_handler(Exception, internal_server_error_response)

    @app.exception_handler(RequestValidationError)
    async def redact_validation_inputs(
        _: Request,
        exc: RequestValidationError,
    ) -> JSONResponse:
        return JSONResponse(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            content=jsonable_encoder(
                {"detail": _validation_errors_without_inputs(exc.errors())}
            ),
        )

    @app.get("/healthz")
    async def health() -> dict[str, str]:
        return {"status": "ok", "service": "noop-managed-storage"}

    @app.get("/readyz")
    async def ready() -> dict[str, str]:
        database_ready = await primary.ready()
        configuration_ready = database_ready and await repository.configuration_ready(
            policy_version=(runtime_settings.managed_consent_policy_version or ""),
            policy_sha256=(runtime_settings.managed_consent_policy_sha256 or ""),
        )
        if not configuration_ready:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="managed storage is not ready",
            )
        return {"status": "ready", "service": "noop-managed-storage"}

    app.include_router(
        managed_router(
            settings=runtime_settings,
            repository=repository,
            app_check_verifier=app_check_verifier,
            token_verifier=verifier,
            object_store=object_store,
            identity_deletion_ticket_codec=identity_deletion_ticket_codec,
            safety_repository=safety_repository,
            safety_push_service=safety_push_service,
        )
    )
    return app


app = create_managed_app()
