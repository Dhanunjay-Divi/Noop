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
from app.managed_app_check import (
    FirebaseAppCheckTokenVerifier,
    ManagedAppCheckVerifying,
)
from app.managed_identity import (
    IdentityToolkitTokenVerifier,
    ManagedTokenVerifying,
)
from app.observability import (
    OperationalSink,
    RequestObservabilityMiddleware,
    emit_operational_event,
    internal_server_error_response,
)
from app.ownership_api import ownership_router
from app.ownership_possession import (
    OwnershipPossessionVerifying,
    UnavailableOwnershipPossessionVerifier,
)
from app.ownership_repository import (
    OwnershipRepository,
    PostgresOwnershipRepository,
)
from app.repository import PostgresRepository


def create_ownership_app(
    *,
    settings: Settings | None = None,
    repository: OwnershipRepository | None = None,
    app_check_verifier: ManagedAppCheckVerifying | None = None,
    token_verifier: ManagedTokenVerifying | None = None,
    possession_verifier: OwnershipPossessionVerifying | None = None,
    event_sink: OperationalSink = emit_operational_event,
) -> FastAPI:
    runtime_settings = settings or Settings.from_env()
    primary: PostgresRepository | None = None
    postgres_repository: PostgresOwnershipRepository | None = None
    if repository is None:
        primary = PostgresRepository(
            runtime_settings.database_url or "",
            pool_min_size=runtime_settings.pool_min_size,
            pool_max_size=runtime_settings.pool_max_size,
            statement_cache_size=(runtime_settings.database_statement_cache_size),
            run_migrations=runtime_settings.run_migrations,
            database_engine=runtime_settings.database_engine,
        )
        postgres_repository = PostgresOwnershipRepository(primary)
        runtime_repository: OwnershipRepository = postgres_repository
    else:
        runtime_repository = repository

    runtime_token_verifier = token_verifier or IdentityToolkitTokenVerifier(
        project_id=runtime_settings.ownership_project_id or "",
        api_key=runtime_settings.ownership_identity_api_key or "",
        cache_seconds=runtime_settings.ownership_identity_cache_seconds,
        cache_entries=runtime_settings.ownership_identity_cache_entries,
    )
    runtime_app_check_verifier = app_check_verifier or FirebaseAppCheckTokenVerifier(
        project_number=runtime_settings.ownership_project_number or "",
        allowed_app_ids=frozenset(
            {
                runtime_settings.ownership_apple_app_id or "",
                runtime_settings.ownership_android_app_id or "",
            }
        ),
        jwks_cache_seconds=(runtime_settings.ownership_app_check_cache_seconds),
    )
    runtime_possession_verifier = (
        possession_verifier or UnavailableOwnershipPossessionVerifier()
    )

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        if not runtime_settings.ownership_service_enabled:
            raise RuntimeError(
                "NOOP_OWNERSHIP_SERVICE_ENABLED must be true for ownership API"
            )
        runtime_settings.validate_for_startup(
            needs_database=primary is not None,
            needs_api_token=False,
        )
        if primary is not None:
            await primary.startup()
        try:
            yield
        finally:
            if primary is not None:
                await primary.shutdown()

    app = FastAPI(
        title="NOOP Band Ownership",
        summary="Identity and ownership authority without health data",
        version=__version__,
        lifespan=lifespan,
        docs_url=None,
        redoc_url=None,
    )
    app.state.settings = runtime_settings
    app.state.repository = runtime_repository
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
        service="noop-ownership-api",
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
        return {"status": "ok", "service": "noop-band-ownership"}

    @app.get("/readyz")
    async def ready() -> dict[str, str]:
        if postgres_repository is not None:
            if not await postgres_repository.runtime_ready():
                raise HTTPException(
                    status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                    detail="ownership service is not ready",
                )
        return {"status": "ready", "service": "noop-band-ownership"}

    app.include_router(
        ownership_router(
            settings=runtime_settings,
            repository=runtime_repository,
            app_check_verifier=runtime_app_check_verifier,
            token_verifier=runtime_token_verifier,
            possession_verifier=runtime_possession_verifier,
            event_sink=event_sink,
        )
    )
    return app


app = create_ownership_app()
