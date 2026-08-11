from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import logging
import math
import re
import secrets
import time
from collections import deque
from contextlib import asynccontextmanager, suppress
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from typing import Annotated, Any
from uuid import UUID, uuid4

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
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from fastapi.staticfiles import StaticFiles
from pydantic import ValidationError

from app import __version__
from app.config import Settings
from app.models import (
    FriendInviteCreate,
    FriendInviteJoin,
    FriendInviteRedeem,
    FriendProfileCreate,
    FriendProfileUpdate,
    FriendRequestDecision,
    FriendVisibilityPatch,
    IDENTIFIER_PATTERN,
    STREAM_RANGES,
    StrictModel,
    SyncPayload,
    SyncResult,
)
from app.repository import (
    FriendConflictError,
    FriendForbiddenError,
    FriendNotFoundError,
    MemoryRepository,
    PostgresRepository,
    Repository,
    SyncConflictError,
    SyncRetiredError,
)

RAW_NOTICE = (
    "Rows labelled raw_sensor or unclassified_sensor are uncalibrated sensor "
    "values. In particular, raw_adc is not clinical SpO2, temperature, or "
    "respiration data. Noop metrics are informational and not medical advice."
)
SOCIAL_SYNC_DAILY_RANGES: dict[str, tuple[float, float]] = {
    "recovery": (0.0, 100.0),
    "effort": (0.0, 100.0),
    "sleep_performance": (0.0, 100.0),
    "total_sleep_min": (0.0, 2_880.0),
    "avg_hrv": (0.0, 1_000.0),
    "resting_hr": (20.0, 260.0),
}
SOCIAL_SYNC_DAILY_METRICS = frozenset(SOCIAL_SYNC_DAILY_RANGES)
DEVICE_RE = re.compile(IDENTIFIER_PATTERN)
security = HTTPBearer(auto_error=False)
logger = logging.getLogger("noop.retention")


class RequestSizeLimitMiddleware:
    """Reject oversized HTTP bodies before FastAPI/Pydantic parses public or private routes."""

    def __init__(self, app: Any, *, max_bytes: int) -> None:
        self.app = app
        self.max_bytes = max_bytes

    async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> None:
        if scope.get("type") != "http":
            await self.app(scope, receive, send)
            return

        headers = {key.lower(): value for key, value in scope.get("headers", ())}
        declared = headers.get(b"content-length")
        if declared is not None:
            try:
                declared_length = int(declared.decode("ascii"))
            except (UnicodeDecodeError, ValueError):
                await JSONResponse(
                    status_code=400, content={"detail": "invalid Content-Length"}
                )(scope, receive, send)
                return
            if declared_length < 0:
                await JSONResponse(
                    status_code=400, content={"detail": "invalid Content-Length"}
                )(scope, receive, send)
                return
            if declared_length > self.max_bytes:
                await JSONResponse(
                    status_code=413,
                    content={"detail": "request body is too large"},
                )(scope, receive, send)
                return

        received = 0

        async def limited_receive() -> dict[str, Any]:
            nonlocal received
            message = await receive()
            if message.get("type") == "http.request":
                received += len(message.get("body", b""))
                if received > self.max_bytes:
                    # FastAPI preserves an HTTPException raised by receive(), while it maps an
                    # arbitrary exception during body parsing to a generic 400 response.
                    raise HTTPException(
                        status_code=413,
                        detail="request body is too large",
                    )
            return message

        await self.app(scope, limited_receive, send)


class SlidingWindowRateLimiter:
    """Bounded, process-local sliding-window limiter with no plaintext secrets."""

    def __init__(
        self,
        *,
        limit: int,
        window_seconds: float,
        max_keys: int,
    ) -> None:
        self.limit = limit
        self.window_seconds = window_seconds
        self.max_keys = max_keys
        self._buckets: dict[str, deque[float]] = {}
        self._lock = asyncio.Lock()
        self._last_full_cleanup = 0.0

    async def consume(self, key: str) -> tuple[bool, int]:
        now = time.monotonic()
        cutoff = now - self.window_seconds
        async with self._lock:
            if now - self._last_full_cleanup >= self.window_seconds:
                empty_keys: list[str] = []
                for stored_key, stored_bucket in self._buckets.items():
                    while stored_bucket and stored_bucket[0] <= cutoff:
                        stored_bucket.popleft()
                    if not stored_bucket:
                        empty_keys.append(stored_key)
                for empty_key in empty_keys:
                    del self._buckets[empty_key]
                self._last_full_cleanup = now

            # Collapse excess unique credentials into one fail-closed bucket.
            # This bounds memory and prevents a token-spray attack from creating
            # an unbounded dictionary or bypassing the direct-origin bucket.
            if key not in self._buckets and len(self._buckets) >= self.max_keys:
                key = "overflow"
            bucket = self._buckets.setdefault(key, deque())
            while bucket and bucket[0] <= cutoff:
                bucket.popleft()
            if len(bucket) >= self.limit:
                retry_after = max(
                    1,
                    math.ceil(bucket[0] + self.window_seconds - now),
                )
                return False, retry_after
            bucket.append(now)
            return True, 0


class RateLimitMiddleware:
    """Limit every API request by direct peer and bearer credential digest."""

    def __init__(
        self,
        app: Any,
        *,
        credential_limit: int,
        origin_limit: int,
        max_keys: int,
    ) -> None:
        self.app = app
        self._credential = SlidingWindowRateLimiter(
            limit=credential_limit,
            window_seconds=60,
            max_keys=max_keys,
        )
        self._origin = SlidingWindowRateLimiter(
            limit=origin_limit,
            window_seconds=60,
            max_keys=max_keys,
        )

    async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> None:
        if scope.get("type") != "http" or not scope.get("path", "").startswith("/v1"):
            await self.app(scope, receive, send)
            return

        client = scope.get("client")
        direct_peer = str(client[0]) if client else "unknown"
        origin_key = "origin:" + hashlib.sha256(direct_peer.encode("utf-8")).hexdigest()
        allowed, retry_after = await self._origin.consume(origin_key)
        if not allowed:
            await self._reject(scope, receive, send, retry_after, "origin")
            return

        headers = {key.lower(): value for key, value in scope.get("headers", ())}
        authorization = headers.get(b"authorization", b"")
        bearer_credential = (
            authorization[7:].strip()
            if authorization.lower().startswith(b"bearer ")
            else b""
        )
        if bearer_credential:
            credential_key = (
                "credential:" + hashlib.sha256(bearer_credential).hexdigest()
            )
            allowed, retry_after = await self._credential.consume(credential_key)
            if not allowed:
                await self._reject(
                    scope,
                    receive,
                    send,
                    retry_after,
                    "credential",
                )
                return

        await self.app(scope, receive, send)

    @staticmethod
    async def _reject(
        scope: dict[str, Any],
        receive: Any,
        send: Any,
        retry_after: int,
        limiter_scope: str,
    ) -> None:
        await JSONResponse(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            content={"detail": "request rate limit exceeded"},
            headers={
                "Retry-After": str(retry_after),
                "Cache-Control": "no-store",
                "X-Noop-RateLimit-Scope": limiter_scope,
            },
        )(scope, receive, send)


def _validation_errors_without_inputs(
    errors: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """Keep useful validation locations/messages without reflecting request values."""

    def strip(value: Any) -> Any:
        if isinstance(value, dict):
            return {key: strip(item) for key, item in value.items() if key != "input"}
        if isinstance(value, (list, tuple)):
            return [strip(item) for item in value]
        return value

    return [strip(error) for error in errors]


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


def _secret_hash(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _new_friend_token() -> str:
    # 256 bits of entropy. Only its digest is persisted.
    return f"noop_member_{secrets.token_urlsafe(32)}"


def _new_invite_code() -> tuple[str, str]:
    # 96 random bits, formatted for copy/paste. The repository stores only the
    # compact code's digest; this plaintext is returned exactly once.
    compact = f"NOOP{secrets.token_hex(12).upper()}"
    display = "-".join(
        (compact[:4], compact[4:10], compact[10:16], compact[16:22], compact[22:])
    )
    return display, compact


async def _run_retention_once(
    repository: Repository,
    settings: Settings,
    *,
    now: datetime | None = None,
) -> dict[str, int]:
    """Apply the configured global retention window exactly once.

    Keeping one cycle separate from the scheduler makes the destructive policy
    deterministic and testable. A disabled policy is always a no-op.
    """

    if settings.retention_days is None:
        return {}
    reference = (now or datetime.now(UTC)).astimezone(UTC)
    cutoff = reference - timedelta(days=settings.retention_days)
    replay_guard_until = reference + timedelta(
        days=settings.idempotency_replay_guard_days
    )
    return await repository.purge_before(cutoff, None, replay_guard_until)


async def _retention_worker(repository: Repository, settings: Settings) -> None:
    """Run retention periodically without making API availability depend on it."""

    interval_seconds = settings.retention_interval_hours * 60 * 60
    while True:
        await asyncio.sleep(interval_seconds)
        try:
            counts = await _run_retention_once(repository, settings)
            logger.info("scheduled retention completed: %s", counts)
        except asyncio.CancelledError:
            raise
        except Exception:
            # A transient database failure must be visible to operators, but it
            # must not take down ingestion. The next bounded cycle retries.
            logger.exception("scheduled retention failed")


async def require_friend_profile(
    request: Request,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(security)],
) -> dict[str, Any]:
    supplied = (
        credentials.credentials
        if credentials is not None and credentials.scheme.casefold() == "bearer"
        else ""
    )
    repository: Repository = request.app.state.repository
    profile = (
        await repository.friend_profile_for_token(_secret_hash(supplied))
        if supplied.startswith("noop_member_")
        else None
    )
    if profile is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="invalid or missing member token",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return profile


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
        retention_task: asyncio.Task[None] | None = None
        if runtime_settings.retention_days is not None:
            retention_task = asyncio.create_task(
                _retention_worker(runtime_repository, runtime_settings),
                name="noop-retention",
            )
        try:
            yield
        finally:
            if retention_task is not None:
                retention_task.cancel()
                with suppress(asyncio.CancelledError):
                    await retention_task
            await runtime_repository.shutdown()

    app = FastAPI(
        title="Noop Self-Hosted",
        summary="Private, opt-in storage for your Noop biometric data",
        version=__version__,
        lifespan=lifespan,
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
        max_keys=runtime_settings.rate_limit_max_keys,
    )

    @app.exception_handler(RequestValidationError)
    async def redact_request_validation_secrets(
        _: Request, exc: RequestValidationError
    ) -> JSONResponse:
        return JSONResponse(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            content=jsonable_encoder(
                {"detail": _validation_errors_without_inputs(exc.errors())}
            ),
        )

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
        request: Request,
        credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(security)],
    ) -> None:
        expected = runtime_settings.api_token or ""
        supplied = (
            credentials.credentials
            if credentials is not None and credentials.scheme.casefold() == "bearer"
            else ""
        )
        is_admin = bool(expected) and hmac.compare_digest(
            supplied.encode("utf-8"), expected.encode("utf-8")
        )
        if is_admin:
            request.state.auth_scope = "admin"
            return
        if request.url.path in {"/v1/sync", "/v1/status"} and supplied.startswith(
            "noop_member_"
        ):
            profile = await runtime_repository.friend_profile_for_token(
                _secret_hash(supplied)
            )
            if profile is not None:
                request.state.auth_scope = "social_member"
                request.state.friend_profile = profile
                return
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="invalid or missing bearer token",
            headers={"WWW-Authenticate": "Bearer"},
        )

    def raise_social_error(exc: Exception) -> None:
        if isinstance(exc, FriendNotFoundError):
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        if isinstance(exc, FriendConflictError):
            raise HTTPException(status_code=409, detail=str(exc)) from exc
        if isinstance(exc, FriendForbiddenError):
            raise HTTPException(status_code=403, detail=str(exc)) from exc
        raise exc

    @app.get("/healthz", tags=["operations"])
    async def health() -> dict[str, str]:
        # Public and intentionally contains no database/user information.
        return {"status": "ok"}

    @app.get("/readyz", tags=["operations"])
    async def readiness() -> Response:
        # Keep the public response intentionally generic while making an
        # orchestrator's traffic decision depend on an actual database query.
        try:
            ready = await runtime_repository.ready()
        except Exception:
            ready = False
        if not ready:
            return JSONResponse(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                content={"status": "not_ready"},
                headers={"Cache-Control": "no-store"},
            )
        return JSONResponse(
            content={"status": "ready"},
            headers={"Cache-Control": "no-store"},
        )

    router = APIRouter(
        prefix="/v1",
        dependencies=[Depends(require_api_token)],
    )

    @router.get("/status", tags=["operations"])
    async def service_status(request: Request) -> dict[str, Any]:
        if getattr(request.state, "auth_scope", None) == "social_member":
            return {
                "status": "ok",
                "version": __version__,
                "scope": "social_member",
                "notice": (
                    "This credential can upload its exact computed daily producer "
                    "and use invitation-only social summary routes."
                ),
            }
        stats = await runtime_repository.stats()
        return {
            "status": "ok",
            "version": __version__,
            "retention_days": runtime_settings.retention_days,
            "retention_interval_hours": (
                runtime_settings.retention_interval_hours
                if runtime_settings.retention_days is not None
                else None
            ),
            "stats": stats,
            "notice": RAW_NOTICE,
        }

    @router.post(
        "/social/bootstrap",
        status_code=status.HTTP_201_CREATED,
        tags=["friends-admin"],
    )
    async def bootstrap_friend_profile(body: FriendProfileCreate) -> dict[str, Any]:
        token = _new_friend_token()
        profile_id = str(uuid4())
        try:
            profile = await runtime_repository.create_friend_profile(
                profile_id,
                str(uuid4()),
                body.display_name,
                body.installation_id,
                body.daily_device_id,
                _secret_hash(token),
            )
        except (FriendNotFoundError, FriendConflictError) as exc:
            raise_social_error(exc)
            raise AssertionError("unreachable")
        return {
            "profile": profile,
            "member_token": token,
            "token_notice": (
                "Store this member token securely. It is returned only once and "
                "can access computed daily sync and social summary routes only."
            ),
        }

    @router.get("/social/admin/profiles", tags=["friends-admin"])
    async def friend_profiles() -> dict[str, Any]:
        return {"profiles": await runtime_repository.list_friend_profiles()}

    @router.patch(
        "/social/admin/profiles/{profile_id}",
        tags=["friends-admin"],
    )
    async def update_friend_profile(
        profile_id: UUID, body: FriendProfileUpdate
    ) -> dict[str, Any]:
        try:
            profile = await runtime_repository.update_friend_profile(
                str(profile_id), body.model_dump(exclude_unset=True)
            )
        except (FriendNotFoundError, FriendConflictError) as exc:
            raise_social_error(exc)
            raise AssertionError("unreachable")
        return {"profile": profile}

    @router.post(
        "/social/admin/profiles/{profile_id}/rotate-token",
        tags=["friends-admin"],
    )
    async def rotate_friend_profile_token(profile_id: UUID) -> dict[str, Any]:
        token = _new_friend_token()
        try:
            profile = await runtime_repository.rotate_friend_token(
                str(profile_id), _secret_hash(token)
            )
        except (FriendNotFoundError, FriendConflictError) as exc:
            raise_social_error(exc)
            raise AssertionError("unreachable")
        return {
            "profile": profile,
            "member_token": token,
            "token_notice": "The previous member token is no longer valid.",
        }

    @router.delete(
        "/social/admin/profiles/{profile_id}",
        status_code=status.HTTP_204_NO_CONTENT,
        tags=["friends-admin"],
    )
    async def disable_friend_profile(
        profile_id: UUID,
        confirmation: Annotated[str | None, Header(alias="X-Noop-Confirm")] = None,
    ) -> Response:
        expected = f"DISABLE {profile_id}"
        if confirmation != expected:
            raise HTTPException(
                status_code=412,
                detail=f"set X-Noop-Confirm to {expected!r}",
            )
        try:
            await runtime_repository.disable_friend_profile(str(profile_id))
        except FriendNotFoundError as exc:
            raise_social_error(exc)
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    social_router = APIRouter(prefix="/v1/social")

    @social_router.get("/me", tags=["friends"])
    async def social_profile(
        member: Annotated[dict[str, Any], Depends(require_friend_profile)],
    ) -> dict[str, Any]:
        return {
            "profile": member,
            "privacy": (
                "Friend credentials can upload only their scoped computed daily "
                "summary and cannot access exports, raw streams, location, "
                "workouts, or journal entries."
            ),
        }

    @social_router.delete(
        "/me",
        status_code=status.HTTP_204_NO_CONTENT,
        tags=["friends"],
    )
    async def delete_social_profile(
        member: Annotated[dict[str, Any], Depends(require_friend_profile)],
        confirmation: Annotated[str | None, Header(alias="X-Noop-Confirm")] = None,
    ) -> Response:
        if confirmation != "DELETE MY SOCIAL PROFILE":
            raise HTTPException(
                status_code=412,
                detail=("set X-Noop-Confirm to 'DELETE MY SOCIAL PROFILE'"),
            )
        try:
            await runtime_repository.delete_friend_profile_data(
                str(member["profile_id"]),
                str(member["daily_device_id"]),
            )
        except FriendForbiddenError as exc:
            raise HTTPException(status_code=403, detail=str(exc)) from exc
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    @social_router.post(
        "/invites",
        status_code=status.HTTP_201_CREATED,
        tags=["friends"],
    )
    async def create_friend_invite(
        body: FriendInviteCreate,
        member: Annotated[dict[str, Any], Depends(require_friend_profile)],
    ) -> dict[str, Any]:
        display_code, compact_code = _new_invite_code()
        expires_at = datetime.now(UTC) + timedelta(hours=body.expires_in_hours)
        try:
            invite = await runtime_repository.create_friend_invite(
                str(uuid4()),
                str(member["profile_id"]),
                _secret_hash(compact_code),
                expires_at,
            )
        except (FriendNotFoundError, FriendConflictError) as exc:
            raise_social_error(exc)
            raise AssertionError("unreachable")
        return {
            "invite": invite,
            "code": display_code,
            "code_notice": (
                "This one-time code expires at expires_at. It contains no server "
                "or member credential."
            ),
        }

    @social_router.post(
        "/invites/join",
        status_code=status.HTTP_201_CREATED,
        tags=["friends"],
    )
    async def join_with_friend_invite(body: FriendInviteJoin) -> dict[str, Any]:
        try:
            joined = await runtime_repository.join_friend_invite(
                _secret_hash(body.code),
                str(uuid4()),
                str(body.enrollment_id),
                body.display_name,
                body.installation_id,
                body.daily_device_id,
                _secret_hash(body.member_token.get_secret_value()),
                str(uuid4()),
                datetime.now(UTC),
            )
        except (FriendNotFoundError, FriendConflictError) as exc:
            raise_social_error(exc)
            raise AssertionError("unreachable")
        request_row = joined["request"]
        return {
            "profile": joined["profile"],
            "request": {
                "request_id": request_row["request_id"],
                "status": request_row["status"],
                "created_at": request_row["created_at"],
                "decided_at": request_row["decided_at"],
                "recipient": {
                    "display_name": joined["inviter_display_name"],
                },
            },
            "idempotent_replay": joined["idempotent_replay"],
            "token_notice": (
                "The supplied member token was stored only as a digest; "
                "the request field contains the current friendship decision state."
            ),
        }

    @social_router.delete(
        "/invites/{invite_id}",
        status_code=status.HTTP_204_NO_CONTENT,
        tags=["friends"],
    )
    async def revoke_friend_invite(
        invite_id: UUID,
        member: Annotated[dict[str, Any], Depends(require_friend_profile)],
    ) -> Response:
        try:
            await runtime_repository.revoke_friend_invite(
                str(member["profile_id"]), str(invite_id)
            )
        except (FriendNotFoundError, FriendConflictError) as exc:
            raise_social_error(exc)
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    @social_router.post(
        "/invites/redeem",
        status_code=status.HTTP_201_CREATED,
        tags=["friends"],
    )
    async def redeem_friend_invite(
        body: FriendInviteRedeem,
        member: Annotated[dict[str, Any], Depends(require_friend_profile)],
    ) -> dict[str, Any]:
        try:
            request_row = await runtime_repository.redeem_friend_invite(
                _secret_hash(body.code),
                str(member["profile_id"]),
                str(uuid4()),
                datetime.now(UTC),
            )
        except (FriendNotFoundError, FriendConflictError) as exc:
            raise_social_error(exc)
            raise AssertionError("unreachable")
        return {"request": request_row}

    @social_router.get("/requests", tags=["friends"])
    async def friend_requests(
        member: Annotated[dict[str, Any], Depends(require_friend_profile)],
    ) -> dict[str, Any]:
        return {
            "requests": await runtime_repository.list_friend_requests(
                str(member["profile_id"])
            )
        }

    @social_router.post("/requests/{request_id}", tags=["friends"])
    async def decide_friend_request(
        request_id: UUID,
        body: FriendRequestDecision,
        member: Annotated[dict[str, Any], Depends(require_friend_profile)],
    ) -> dict[str, Any]:
        try:
            request_row = await runtime_repository.decide_friend_request(
                str(member["profile_id"]),
                str(request_id),
                body.decision,
                datetime.now(UTC),
            )
        except (FriendNotFoundError, FriendConflictError) as exc:
            raise_social_error(exc)
            raise AssertionError("unreachable")
        return {"request": request_row}

    @social_router.get("/friends", tags=["friends"])
    async def list_friends(
        member: Annotated[dict[str, Any], Depends(require_friend_profile)],
    ) -> dict[str, Any]:
        return {
            "friends": await runtime_repository.list_friends(str(member["profile_id"]))
        }

    @social_router.patch("/friends/{friend_id}/privacy", tags=["friends"])
    async def update_friend_privacy(
        friend_id: UUID,
        body: FriendVisibilityPatch,
        member: Annotated[dict[str, Any], Depends(require_friend_profile)],
    ) -> dict[str, Any]:
        changes = body.model_dump(exclude_unset=True)
        try:
            visibility = await runtime_repository.update_friend_visibility(
                str(member["profile_id"]),
                str(friend_id),
                changes,
            )
        except FriendNotFoundError as exc:
            raise_social_error(exc)
            raise AssertionError("unreachable")
        return {
            "friend_id": friend_id,
            "sharing": visibility,
            "privacy": "This allowlist is applied by the server to every feed read.",
        }

    @social_router.delete(
        "/friends/{friend_id}",
        status_code=status.HTTP_204_NO_CONTENT,
        tags=["friends"],
    )
    async def remove_friend(
        friend_id: UUID,
        member: Annotated[dict[str, Any], Depends(require_friend_profile)],
    ) -> Response:
        try:
            await runtime_repository.remove_friend(
                str(member["profile_id"]), str(friend_id)
            )
        except FriendNotFoundError as exc:
            raise_social_error(exc)
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    @social_router.post(
        "/blocks/{profile_id}",
        status_code=status.HTTP_204_NO_CONTENT,
        tags=["friends"],
    )
    async def block_friend(
        profile_id: UUID,
        member: Annotated[dict[str, Any], Depends(require_friend_profile)],
    ) -> Response:
        try:
            await runtime_repository.block_friend(
                str(member["profile_id"]), str(profile_id)
            )
        except (FriendNotFoundError, FriendConflictError) as exc:
            raise_social_error(exc)
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    @social_router.delete(
        "/blocks/{profile_id}",
        status_code=status.HTTP_204_NO_CONTENT,
        tags=["friends"],
    )
    async def unblock_friend(
        profile_id: UUID,
        member: Annotated[dict[str, Any], Depends(require_friend_profile)],
    ) -> Response:
        try:
            await runtime_repository.unblock_friend(
                str(member["profile_id"]), str(profile_id)
            )
        except FriendNotFoundError as exc:
            raise_social_error(exc)
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    @social_router.get("/feed", tags=["friends"])
    async def friend_feed(
        member: Annotated[dict[str, Any], Depends(require_friend_profile)],
        start: date | None = None,
        end: date | None = None,
    ) -> dict[str, Any]:
        finish = end or datetime.now(UTC).date()
        beginning = start or finish - timedelta(days=6)
        if beginning > finish:
            raise HTTPException(status_code=422, detail="start must not be after end")
        if (finish - beginning).days > 89:
            raise HTTPException(
                status_code=422,
                detail="friend feed date range cannot exceed 90 days",
            )
        return {
            "start": beginning,
            "end": finish,
            "days": await runtime_repository.friend_feed(
                str(member["profile_id"]), beginning, finish
            ),
            "units": {
                "charge": "score_0_to_100",
                "effort": "score_0_to_100",
                "rest": "score_0_to_100",
                "sleep_duration": "minutes",
                "hrv": "milliseconds",
                "rhr": "beats_per_minute",
            },
            "privacy": (
                "Only the owner's enabled daily summary fields are returned. "
                "Raw streams, location, journal, sleep stages, and workouts are "
                "never part of this endpoint."
            ),
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
                content={
                    "detail": jsonable_encoder(
                        _validation_errors_without_inputs(exc.errors())
                    )
                },
            )
        if getattr(request.state, "auth_scope", None) == "social_member":
            member = request.state.friend_profile
            metadata = payload.source.metadata
            has_streams = bool(payload.streams.events) or any(
                samples for _, samples in payload.streams.numeric_items()
            )
            daily_keys = {
                metric
                for metrics in payload.daily_metrics.values()
                for metric in metrics
            }
            daily_values_allowed = all(
                SOCIAL_SYNC_DAILY_RANGES[metric][0]
                <= value
                <= SOCIAL_SYNC_DAILY_RANGES[metric][1]
                for metrics in payload.daily_metrics.values()
                for metric, value in metrics.items()
                if metric in SOCIAL_SYNC_DAILY_RANGES
            )
            member_payload_allowed = (
                payload.source.device_id == member["daily_device_id"]
                and metadata.get("installation_id") == member["installation_id"]
                and metadata.get("namespace") == "noop_computed"
                and not has_streams
                and not payload.sleep_sessions
                and not payload.workouts
                and not payload.journal
                and daily_keys <= SOCIAL_SYNC_DAILY_METRICS
                and daily_values_allowed
            )
            if not member_payload_allowed:
                raise HTTPException(
                    status_code=status.HTTP_403_FORBIDDEN,
                    detail=(
                        "member sync is limited to this profile's exact "
                        "noop_computed daily producer and social summary fields"
                    ),
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
                payload,
                _canonical_payload_hash(payload),
                (
                    str(request.state.friend_profile["profile_id"])
                    if getattr(request.state, "auth_scope", None) == "social_member"
                    else None
                ),
            )
        except SyncConflictError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc
        except SyncRetiredError as exc:
            raise HTTPException(status_code=410, detail=str(exc)) from exc
        except FriendForbiddenError as exc:
            raise HTTPException(status_code=403, detail=str(exc)) from exc

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
        counts = await runtime_repository.delete_device(
            device_id,
            datetime.now(UTC)
            + timedelta(days=runtime_settings.idempotency_replay_guard_days),
        )
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
        counts = await runtime_repository.purge_before(
            cutoff,
            body.device_id,
            datetime.now(UTC)
            + timedelta(days=runtime_settings.idempotency_replay_guard_days),
        )
        return {
            "status": "purged",
            "cutoff": cutoff,
            "retention_days": runtime_settings.retention_days,
            "device_id": body.device_id,
            "counts": counts,
        }

    app.include_router(router)
    app.include_router(social_router)

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
