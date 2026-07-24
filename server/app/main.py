from __future__ import annotations

import hashlib
import hmac
import json
import re
from contextlib import asynccontextmanager
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from typing import Annotated, Any
from uuid import UUID

from fastapi import (
    APIRouter,
    Depends,
    FastAPI,
    Header,
    HTTPException,
    Query,
    Request,
    Response,
    status,
)
from fastapi.encoders import jsonable_encoder
from fastapi.responses import FileResponse, JSONResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from fastapi.staticfiles import StaticFiles
from pydantic import ValidationError

from app import __version__
from app.config import Settings
from app.models import (
    IDENTIFIER_PATTERN,
    STREAM_RANGES,
    StrictModel,
    SyncPayload,
    SyncResult,
)
from app.repository import (
    MemoryRepository,
    PostgresRepository,
    Repository,
    SyncConflictError,
)

RAW_NOTICE = (
    "Rows labelled raw_sensor or unclassified_sensor are uncalibrated sensor "
    "values. In particular, raw_adc is not clinical SpO2, temperature, or "
    "respiration data. Noop metrics are informational and not medical advice."
)
DEVICE_RE = re.compile(IDENTIFIER_PATTERN)
security = HTTPBearer(auto_error=False)


class RetentionRunRequest(StrictModel):
    device_id: str | None = None


def _normalise_utc(value: datetime, field_name: str) -> datetime:
    if value.tzinfo is None or value.utcoffset() is None:
        raise HTTPException(
            status_code=422,
            detail=f"{field_name} must include a UTC offset",
        )
    return value.astimezone(UTC)


def _device_id(value: str) -> str:
    if DEVICE_RE.fullmatch(value) is None:
        raise HTTPException(status_code=422, detail="invalid device_id")
    return value


def _canonical_payload_hash(payload: SyncPayload) -> str:
    canonical = json.dumps(
        payload.model_dump(mode="json"),
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def _json_download(value: Any, filename: str) -> Response:
    body = json.dumps(
        jsonable_encoder(value),
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    )
    return Response(
        body,
        media_type="application/json",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


def create_app(
    *,
    settings: Settings | None = None,
    repository: Repository | None = None,
) -> FastAPI:
    runtime_settings = settings or Settings.from_env()
    runtime_repository: Repository
    if repository is not None:
        runtime_repository = repository
    elif runtime_settings.database_url:
        runtime_repository = PostgresRepository(
            runtime_settings.database_url,
            pool_min_size=runtime_settings.pool_min_size,
            pool_max_size=runtime_settings.pool_max_size,
        )
    else:
        # Startup validation will reject this in normal deployment. Keeping a
        # lazy placeholder makes import-time tooling and OpenAPI generation safe.
        runtime_repository = MemoryRepository()

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        runtime_settings.validate_for_startup(
            needs_database=isinstance(runtime_repository, PostgresRepository)
            or repository is None
        )
        await runtime_repository.startup()
        try:
            yield
        finally:
            await runtime_repository.shutdown()

    app = FastAPI(
        title="Noop Self-Hosted",
        summary="Private, opt-in storage for your Noop biometric data",
        version=__version__,
        lifespan=lifespan,
    )
    app.state.settings = runtime_settings
    app.state.repository = runtime_repository

    @app.middleware("http")
    async def privacy_headers(request: Request, call_next):
        response = await call_next(request)
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("Referrer-Policy", "no-referrer")
        response.headers.setdefault("X-Frame-Options", "DENY")
        response.headers.setdefault(
            "Permissions-Policy",
            "camera=(), microphone=(), geolocation=(), payment=(), usb=()",
        )
        if request.url.path.startswith("/v1"):
            response.headers["Cache-Control"] = "no-store"
        return response

    async def require_api_token(
        credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(security)],
    ) -> None:
        expected = runtime_settings.api_token or ""
        supplied = (
            credentials.credentials
            if credentials is not None and credentials.scheme.casefold() == "bearer"
            else ""
        )
        if not expected or not hmac.compare_digest(
            supplied.encode("utf-8"), expected.encode("utf-8")
        ):
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="invalid or missing bearer token",
                headers={"WWW-Authenticate": "Bearer"},
            )

    @app.get("/healthz", tags=["operations"])
    async def health() -> dict[str, str]:
        # Public and intentionally contains no database/user information.
        return {"status": "ok"}

    router = APIRouter(
        prefix="/v1",
        dependencies=[Depends(require_api_token)],
    )

    @router.get("/status", tags=["operations"])
    async def service_status() -> dict[str, Any]:
        stats = await runtime_repository.stats()
        return {
            "status": "ok",
            "version": __version__,
            "retention_days": runtime_settings.retention_days,
            "stats": stats,
            "notice": RAW_NOTICE,
        }

    @router.post(
        "/sync",
        response_model=SyncResult,
        status_code=status.HTTP_200_OK,
        tags=["sync"],
    )
    async def sync_payload(
        request: Request,
        idempotency_key: Annotated[str | None, Header(alias="Idempotency-Key")] = None,
    ) -> SyncResult:
        declared_length = request.headers.get("content-length")
        if declared_length:
            try:
                too_large = int(declared_length) > runtime_settings.max_request_bytes
            except ValueError:
                raise HTTPException(status_code=400, detail="invalid Content-Length")
            if too_large:
                raise HTTPException(status_code=413, detail="sync payload is too large")
        chunks = bytearray()
        async for chunk in request.stream():
            chunks.extend(chunk)
            if len(chunks) > runtime_settings.max_request_bytes:
                raise HTTPException(status_code=413, detail="sync payload is too large")
        body = bytes(chunks)
        try:
            payload = SyncPayload.model_validate_json(body)
        except ValidationError as exc:
            return JSONResponse(
                status_code=422,
                content={"detail": jsonable_encoder(exc.errors())},
            )
        if idempotency_key is not None:
            try:
                header_batch = UUID(idempotency_key)
            except ValueError:
                raise HTTPException(
                    status_code=400, detail="Idempotency-Key must be a UUID"
                )
            if header_batch != payload.batch_id:
                raise HTTPException(
                    status_code=409,
                    detail="Idempotency-Key does not match batch_id",
                )
        try:
            return await runtime_repository.sync(
                payload, _canonical_payload_hash(payload)
            )
        except SyncConflictError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc

    @router.get("/devices", tags=["read"])
    async def devices() -> dict[str, Any]:
        return {
            "devices": await runtime_repository.list_devices(),
            "notice": RAW_NOTICE,
        }

    @router.get("/devices/{device_id}/latest", tags=["read"])
    async def latest(
        device_id: str,
        metrics: str | None = Query(
            default=None,
            description="Optional comma-separated canonical stream names",
        ),
    ) -> dict[str, Any]:
        selected: list[str] | None = None
        if metrics:
            selected = sorted(
                {item.strip() for item in metrics.split(",") if item.strip()}
            )
            unknown = set(selected) - set(STREAM_RANGES)
            if unknown:
                raise HTTPException(
                    status_code=422,
                    detail=f"unknown metrics: {', '.join(sorted(unknown))}",
                )
        return {
            "device_id": _device_id(device_id),
            "metrics": await runtime_repository.latest_metrics(device_id, selected),
            "notice": RAW_NOTICE,
        }

    @router.get("/devices/{device_id}/streams/{metric}", tags=["read"])
    async def metric_values(
        device_id: str,
        metric: str,
        start: datetime | None = None,
        end: datetime | None = None,
        limit: int = Query(default=10_000, ge=1, le=50_000),
    ) -> dict[str, Any]:
        _device_id(device_id)
        if metric not in STREAM_RANGES:
            raise HTTPException(status_code=404, detail="unknown metric stream")
        finish = _normalise_utc(end, "end") if end else datetime.now(UTC)
        beginning = (
            _normalise_utc(start, "start") if start else finish - timedelta(days=1)
        )
        if beginning >= finish:
            raise HTTPException(status_code=422, detail="start must be before end")
        return {
            "device_id": device_id,
            "metric": metric,
            "start": beginning,
            "end": finish,
            "samples": await runtime_repository.metric_range(
                device_id, metric, beginning, finish, limit
            ),
            "notice": RAW_NOTICE,
        }

    @router.get("/devices/{device_id}/daily", tags=["read"])
    async def daily_values(
        device_id: str,
        start: date | None = None,
        end: date | None = None,
    ) -> dict[str, Any]:
        _device_id(device_id)
        finish = end or datetime.now(UTC).date()
        beginning = start or finish - timedelta(days=89)
        if beginning > finish:
            raise HTTPException(status_code=422, detail="start must not be after end")
        if (finish - beginning).days > 3_660:
            raise HTTPException(status_code=422, detail="date range exceeds 10 years")
        return {
            "device_id": device_id,
            "start": beginning,
            "end": finish,
            "days": await runtime_repository.daily_metrics(
                device_id, beginning, finish
            ),
            "efficiency_unit": "fraction_0_to_1",
            "notice": RAW_NOTICE,
        }

    async def _bounded_interval(
        start: datetime | None, end: datetime | None
    ) -> tuple[datetime, datetime]:
        finish = _normalise_utc(end, "end") if end else datetime.now(UTC)
        beginning = (
            _normalise_utc(start, "start") if start else finish - timedelta(days=90)
        )
        if beginning >= finish:
            raise HTTPException(status_code=422, detail="start must be before end")
        if finish - beginning > timedelta(days=3_660):
            raise HTTPException(status_code=422, detail="date range exceeds 10 years")
        return beginning, finish

    @router.get("/devices/{device_id}/events", tags=["read"])
    async def event_values(
        device_id: str,
        start: datetime | None = None,
        end: datetime | None = None,
        limit: int = Query(default=10_000, ge=1, le=50_000),
    ) -> dict[str, Any]:
        _device_id(device_id)
        beginning, finish = await _bounded_interval(start, end)
        return {
            "device_id": device_id,
            "events": await runtime_repository.events(
                device_id, beginning, finish, limit
            ),
            "notice": "Event labels and payloads are preserved raw protocol provenance.",
        }

    @router.get("/devices/{device_id}/sleep", tags=["read"])
    async def sleep_values(
        device_id: str,
        start: datetime | None = None,
        end: datetime | None = None,
        limit: int = Query(default=1_000, ge=1, le=10_000),
    ) -> dict[str, Any]:
        _device_id(device_id)
        beginning, finish = await _bounded_interval(start, end)
        return {
            "device_id": device_id,
            "sessions": await runtime_repository.sleep_sessions(
                device_id, beginning, finish, limit
            ),
            "efficiency_unit": "fraction_0_to_1",
            "notice": RAW_NOTICE,
        }

    @router.get("/devices/{device_id}/workouts", tags=["read"])
    async def workout_values(
        device_id: str,
        start: datetime | None = None,
        end: datetime | None = None,
        limit: int = Query(default=1_000, ge=1, le=10_000),
    ) -> dict[str, Any]:
        _device_id(device_id)
        beginning, finish = await _bounded_interval(start, end)
        return {
            "device_id": device_id,
            "workouts": await runtime_repository.workouts(
                device_id, beginning, finish, limit
            ),
            "notice": RAW_NOTICE,
        }

    @router.get("/devices/{device_id}/journal", tags=["read"])
    async def journal_values(
        device_id: str,
        start: date | None = None,
        end: date | None = None,
    ) -> dict[str, Any]:
        _device_id(device_id)
        finish = end or datetime.now(UTC).date()
        beginning = start or finish - timedelta(days=365)
        if beginning > finish:
            raise HTTPException(status_code=422, detail="start must not be after end")
        return {
            "device_id": device_id,
            "entries": await runtime_repository.journal_entries(
                device_id, beginning, finish
            ),
        }

    @router.get("/devices/{device_id}/export", tags=["data-control"])
    async def export(
        device_id: str,
        start: datetime | None = None,
        end: datetime | None = None,
    ) -> Response:
        _device_id(device_id)
        beginning = _normalise_utc(start, "start") if start else None
        finish = _normalise_utc(end, "end") if end else None
        if beginning and finish and beginning >= finish:
            raise HTTPException(status_code=422, detail="start must be before end")
        value = await runtime_repository.export_device(device_id, beginning, finish)
        return _json_download(value, f"noop-{device_id}-export.json")

    @router.delete("/devices/{device_id}", tags=["data-control"])
    async def erase_device(
        device_id: str,
        confirmation: Annotated[str | None, Header(alias="X-Noop-Confirm")] = None,
    ) -> dict[str, Any]:
        _device_id(device_id)
        expected = f"DELETE {device_id}"
        if confirmation != expected:
            raise HTTPException(
                status_code=412,
                detail=f"set X-Noop-Confirm to {expected!r}",
            )
        counts = await runtime_repository.delete_device(device_id)
        return {"status": "deleted", "device_id": device_id, "counts": counts}

    @router.post("/admin/retention/run", tags=["data-control"])
    async def run_retention(
        body: RetentionRunRequest,
        confirmation: Annotated[str | None, Header(alias="X-Noop-Confirm")] = None,
    ) -> dict[str, Any]:
        if runtime_settings.retention_days is None:
            raise HTTPException(
                status_code=409,
                detail="retention is disabled; set NOOP_RETENTION_DAYS first",
            )
        if confirmation != "PURGE":
            raise HTTPException(
                status_code=412,
                detail="set X-Noop-Confirm to 'PURGE'",
            )
        if body.device_id is not None:
            _device_id(body.device_id)
        cutoff = datetime.now(UTC) - timedelta(days=runtime_settings.retention_days)
        counts = await runtime_repository.purge_before(cutoff, body.device_id)
        return {
            "status": "purged",
            "cutoff": cutoff,
            "retention_days": runtime_settings.retention_days,
            "device_id": body.device_id,
            "counts": counts,
        }

    app.include_router(router)

    static_root = Path(__file__).resolve().parent / "static"
    if runtime_settings.dashboard_enabled:
        app.mount(
            "/assets",
            StaticFiles(directory=static_root),
            name="static-assets",
        )

        @app.get("/", include_in_schema=False)
        @app.get("/dashboard", include_in_schema=False)
        async def dashboard() -> FileResponse:
            return FileResponse(
                static_root / "index.html",
                headers={
                    "Cache-Control": "no-store",
                    "Content-Security-Policy": (
                        "default-src 'self'; script-src 'self'; style-src 'self'; "
                        "img-src 'self' data:; connect-src 'self'; object-src 'none'; "
                        "base-uri 'none'; frame-ancestors 'none'"
                    ),
                    "Referrer-Policy": "no-referrer",
                    "X-Content-Type-Options": "nosniff",
                    "X-Frame-Options": "DENY",
                    "Permissions-Policy": (
                        "camera=(), microphone=(), geolocation=(), payment=(), usb=()"
                    ),
                },
            )

    return app


app = create_app()
