from __future__ import annotations

import asyncio
import hashlib
import hmac
import html as html_lib
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
from urllib.parse import parse_qs, quote
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
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse
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
    SafetyContactCreate,
    SafetyIncidentTransition,
    SafetyLocationUpdate,
    SafetyPageCreate,
    SafetyProfileBootstrap,
    STREAM_RANGES,
    StrictModel,
    SyncPayload,
    SyncResult,
)
from app.paging import (
    PagingProvider,
    PagingUnavailableError,
    TwilioPagingProvider,
    UnavailablePagingProvider,
    normalise_provider_status,
    validate_twilio_webhook,
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
from app.safety_repository import (
    MemorySafetyRepository,
    PostgresSafetyRepository,
    SafetyConflictError,
    SafetyNotFoundError,
    SafetyNotReadyError,
    SafetyRepository,
)
from app.safety_capabilities import SafetyCapabilitySigner
from app.safety_worker import SafetyDeliveryWorker

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


def _new_safety_invitation_token() -> str:
    # A browser-held one-time capability. Only its digest is stored.
    return secrets.token_urlsafe(32)


def _safe_provider_error(error: Exception) -> str:
    text = str(error).strip() or "paging provider request failed"
    return text[:240]


def _safety_contact_response(
    contact: dict[str, Any], *, now: datetime | None = None
) -> dict[str, Any]:
    response = dict(contact)
    reference = now or datetime.now(UTC)
    if (
        response.get("status") == "pending"
        and response.get("invite_expires_at") is not None
        and response["invite_expires_at"] <= reference
    ):
        response["status"] = "expired"
    return response


def _safety_dispatch_response(dispatch: dict[str, Any]) -> dict[str, Any]:
    response = dict(dispatch)
    response["deliveries"] = [
        {
            key: value
            for key, value in delivery.items()
            if key not in {"phone_e164", "provider_reference"}
        }
        for delivery in dispatch.get("deliveries", [])
    ]
    summary: dict[str, int] = {}
    for delivery in response["deliveries"]:
        delivery_status = str(delivery["status"])
        summary[delivery_status] = summary.get(delivery_status, 0) + 1
    response["delivery_summary"] = summary
    return response


def _safety_acceptance_headers() -> dict[str, str]:
    return {
        "Cache-Control": "no-store",
        "Content-Security-Policy": (
            "default-src 'none'; style-src 'unsafe-inline'; "
            "form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
        ),
        "Referrer-Policy": "no-referrer",
        "X-Content-Type-Options": "nosniff",
        "X-Frame-Options": "DENY",
    }


def _safety_acceptance_page(
    *,
    invitation_token: str,
    preview: dict[str, Any] | None,
    outcome: str | None = None,
) -> str:
    if outcome is not None:
        title = "Emergency contact response saved"
        body = html_lib.escape(outcome)
        actions = ""
    elif preview is None:
        title = "Invitation unavailable"
        body = "This invitation is invalid, expired, or has already been used."
        actions = ""
    else:
        contact = preview["contact"]
        owner = html_lib.escape(str(preview["owner_display_name"]))
        contact_name = html_lib.escape(str(contact["display_name"]))
        status_value = str(contact["status"])
        expires_at = contact["invite_expires_at"]
        expired = status_value != "pending" or expires_at <= datetime.now(UTC)
        title = f"{owner} invited you"
        if expired:
            body = (
                "This invitation is no longer active. Ask the NOOP user to "
                "send a new invitation."
            )
            actions = ""
        else:
            body = (
                f"{contact_name}, accept only if you agree to receive SMS and "
                f"automated voice safety pages for {owner}. NOOP does not "
                "dispatch emergency services."
            )
            safe_token = quote(invitation_token, safe="")
            actions = f"""
              <form method="post" action="/safety/accept/{safe_token}">
                <button class="accept" name="decision" value="accept">Accept invitation</button>
                <button class="decline" name="decision" value="decline">Decline</button>
              </form>
            """
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{html_lib.escape(title)}</title>
  <style>
    :root {{ color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }}
    body {{ margin: 0; min-height: 100vh; display: grid; place-items: center; background: #f4f5f6; color: #14171a; }}
    main {{ width: min(520px, calc(100% - 32px)); box-sizing: border-box; padding: 32px; background: #fff;
            border: 1px solid #dfe3e7; border-radius: 8px; box-shadow: 0 12px 36px rgba(0,0,0,.08); }}
    .mark {{ color: #9a6d00; font-size: 13px; font-weight: 700; letter-spacing: .08em; }}
    h1 {{ margin: 12px 0; font-size: 28px; line-height: 1.15; letter-spacing: 0; }}
    p {{ color: #4f5962; line-height: 1.55; }}
    form {{ display: grid; gap: 10px; margin-top: 24px; }}
    button {{ min-height: 48px; border-radius: 7px; font: inherit; font-weight: 650; cursor: pointer; }}
    .accept {{ border: 0; background: #14171a; color: #fff; }}
    .decline {{ border: 1px solid #c8cdd2; background: transparent; color: inherit; }}
    small {{ display: block; margin-top: 24px; color: #727b83; line-height: 1.45; }}
    @media (prefers-color-scheme: dark) {{
      body {{ background: #090a0b; color: #f4f5f6; }}
      main {{ background: #151719; border-color: #303438; box-shadow: none; }}
      p, small {{ color: #abb2b8; }}
      .accept {{ background: #f4f5f6; color: #14171a; }}
      .decline {{ border-color: #4b5157; }}
    }}
  </style>
</head>
<body>
  <main>
    <div class="mark">NOOP SAFETY</div>
    <h1>{html_lib.escape(title)}</h1>
    <p>{body}</p>
    {actions}
    <small>Safety pages contain generic safety wording, not biometric readings. In an emergency, contact local emergency services directly.</small>
  </main>
</body>
</html>"""


def _safety_response_page(
    *,
    preview: dict[str, Any] | None,
    action_url: str,
    outcome: str | None = None,
) -> str:
    refresh = ""
    location_block = ""
    if preview is not None:
        status_value = str(preview["status"])
        if status_value in {"open", "acknowledged"}:
            refresh = '<meta http-equiv="refresh" content="15">'
        location = preview.get("latest_location")
        if location is not None:
            latitude = float(location["latitude"])
            longitude = float(location["longitude"])
            captured_at = location["captured_at"]
            age_seconds = max(
                int((datetime.now(UTC) - captured_at).total_seconds()),
                0,
            )
            if age_seconds < 60:
                age_label = f"{age_seconds} seconds ago"
            else:
                age_label = f"{age_seconds // 60} minutes ago"
            accuracy = location.get("horizontal_accuracy_meters")
            accuracy_label = (
                f" · about {round(float(accuracy))} m accuracy"
                if accuracy is not None
                else ""
            )
            map_url = (
                "https://www.openstreetmap.org/"
                f"?mlat={latitude:.6f}&mlon={longitude:.6f}"
                f"#map=17/{latitude:.6f}/{longitude:.6f}"
            )
            location_block = f"""
              <section class="location">
                <strong>Latest shared location</strong>
                <span>Updated {html_lib.escape(age_label)}{html_lib.escape(accuracy_label)}</span>
                <a href="{html_lib.escape(map_url, quote=True)}" target="_blank"
                   rel="noopener noreferrer">Open map</a>
              </section>
            """
    if outcome is not None:
        title = "Safety response saved"
        body = html_lib.escape(outcome)
        actions = ""
    elif preview is None:
        title = "Safety page unavailable"
        body = "This response link is invalid or has expired."
        actions = ""
    else:
        owner = html_lib.escape(str(preview["owner_display_name"]))
        status_value = str(preview["status"])
        title = f"Respond to {owner}"
        if status_value == "open":
            body = (
                f"{owner} sent an urgent Safety page. Call them now, then "
                "tell the rest of their Safety Network whether you can respond."
            )
            safe_action = html_lib.escape(action_url, quote=True)
            actions = f"""
              <form method="post" action="{safe_action}">
                <button class="accept" name="decision" value="responding">I’m responding</button>
                <button class="decline" name="decision" value="cannot_respond">I cannot respond</button>
              </form>
            """
        elif status_value == "acknowledged":
            body = (
                "A Safety Network contact has acknowledged this page. Call "
                f"{owner} directly if you can still help."
            )
            actions = ""
        else:
            body = (
                f"This Safety page is {html_lib.escape(status_value)} and is "
                "no longer accepting responses."
            )
            actions = ""
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  {refresh}
  <title>{html_lib.escape(title)}</title>
  <style>
    :root {{ color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }}
    body {{ margin: 0; min-height: 100vh; display: grid; place-items: center; background: #f4f5f6; color: #14171a; }}
    main {{ width: min(520px, calc(100% - 32px)); box-sizing: border-box; padding: 32px; background: #fff;
            border: 1px solid #dfe3e7; border-radius: 8px; box-shadow: 0 12px 36px rgba(0,0,0,.08); }}
    .mark {{ color: #9a6d00; font-size: 13px; font-weight: 700; letter-spacing: .08em; }}
    h1 {{ margin: 12px 0; font-size: 28px; line-height: 1.15; letter-spacing: 0; }}
    p {{ color: #4f5962; line-height: 1.55; }}
    .location {{ display: grid; gap: 7px; margin: 20px 0; padding: 16px;
                 border: 1px solid #dfe3e7; border-radius: 7px; }}
    .location span {{ color: #4f5962; font-size: 14px; }}
    .location a {{ color: #087e57; font-weight: 650; }}
    form {{ display: grid; gap: 10px; margin-top: 24px; }}
    button {{ min-height: 48px; border-radius: 7px; font: inherit; font-weight: 650; cursor: pointer; }}
    .accept {{ border: 0; background: #14171a; color: #fff; }}
    .decline {{ border: 1px solid #c8cdd2; background: transparent; color: inherit; }}
    small {{ display: block; margin-top: 24px; color: #727b83; line-height: 1.45; }}
    @media (prefers-color-scheme: dark) {{
      body {{ background: #090a0b; color: #f4f5f6; }}
      main {{ background: #151719; border-color: #303438; box-shadow: none; }}
      p, small {{ color: #abb2b8; }}
      .location {{ border-color: #303438; }}
      .location span {{ color: #abb2b8; }}
      .location a {{ color: #43d6a3; }}
      .accept {{ background: #f4f5f6; color: #14171a; }}
      .decline {{ border-color: #4b5157; }}
    }}
  </style>
</head>
<body>
  <main>
    <div class="mark">NOOP SAFETY NETWORK</div>
    <h1>{html_lib.escape(title)}</h1>
    <p>{body}</p>
    {location_block}
    {actions}
    <small>NOOP has not contacted emergency services. In immediate danger, call local emergency services directly.</small>
  </main>
</body>
</html>"""


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


async def require_safety_profile(
    request: Request,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(security)],
) -> dict[str, Any]:
    supplied = (
        credentials.credentials
        if credentials is not None and credentials.scheme.casefold() == "bearer"
        else ""
    )
    repository: SafetyRepository = request.app.state.safety_repository
    profile = (
        await repository.profile_for_token(_secret_hash(supplied))
        if supplied.startswith("noop_safety_")
        else None
    )
    if profile is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="invalid or missing safety token",
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
    safety_repository: SafetyRepository | None = None,
    paging_provider: PagingProvider | None = None,
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

    if safety_repository is not None:
        runtime_safety_repository = safety_repository
    elif isinstance(runtime_repository, PostgresRepository):
        runtime_safety_repository = PostgresSafetyRepository(runtime_repository)
    else:
        runtime_safety_repository = MemorySafetyRepository()

    runtime_twilio_callback_url: str | None = None
    if paging_provider is not None:
        runtime_paging_provider = paging_provider
    elif runtime_settings.paging_configured:
        callback_secret = quote(
            runtime_settings.twilio_status_callback_secret or "", safe=""
        )
        runtime_twilio_callback_url = (
            f"{(runtime_settings.public_base_url or '').rstrip('/')}"
            "/v1/safety/provider/twilio/status"
            f"?token={callback_secret}"
        )
        runtime_paging_provider = TwilioPagingProvider(
            account_sid=runtime_settings.twilio_account_sid or "",
            auth_token=runtime_settings.twilio_auth_token or "",
            from_phone=runtime_settings.twilio_from_phone or "",
            status_callback_url=runtime_twilio_callback_url,
        )
    else:
        runtime_paging_provider = UnavailablePagingProvider()

    capability_secret = (
        runtime_settings.safety_capability_secret
        or runtime_settings.api_token
        or secrets.token_urlsafe(32)
    )
    runtime_safety_signer = SafetyCapabilitySigner(capability_secret)
    runtime_safety_worker = SafetyDeliveryWorker(
        repository=runtime_safety_repository,
        provider=runtime_paging_provider,
        public_base_url=runtime_settings.public_base_url or "http://localhost",
        capability_signer=runtime_safety_signer,
        poll_seconds=runtime_settings.safety_worker_poll_seconds,
        lease_seconds=runtime_settings.safety_delivery_lease_seconds,
        retry_base_seconds=runtime_settings.safety_retry_base_seconds,
        provider_receipt_timeout_seconds=(
            runtime_settings.safety_provider_receipt_timeout_seconds
        ),
    )

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        runtime_settings.validate_for_startup(
            needs_database=isinstance(runtime_repository, PostgresRepository)
            or repository is None
        )
        await runtime_repository.startup()
        retention_task: asyncio.Task[None] | None = None
        safety_task: asyncio.Task[None] | None = None
        if runtime_settings.retention_days is not None:
            retention_task = asyncio.create_task(
                _retention_worker(runtime_repository, runtime_settings),
                name="noop-retention",
            )
        if runtime_paging_provider.available:
            safety_task = asyncio.create_task(
                runtime_safety_worker.run(),
                name="noop-safety-delivery",
            )
        try:
            yield
        finally:
            if safety_task is not None:
                safety_task.cancel()
                with suppress(asyncio.CancelledError):
                    await safety_task
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
    app.state.safety_repository = runtime_safety_repository
    app.state.paging_provider = runtime_paging_provider
    app.state.safety_worker = runtime_safety_worker
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

    def raise_safety_error(exc: Exception) -> None:
        if isinstance(exc, SafetyNotFoundError):
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        if isinstance(exc, SafetyConflictError):
            raise HTTPException(status_code=409, detail=str(exc)) from exc
        if isinstance(exc, SafetyNotReadyError):
            raise HTTPException(status_code=412, detail=str(exc)) from exc
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

    @app.get(
        "/safety/accept/{invitation_token}",
        response_class=HTMLResponse,
        include_in_schema=False,
    )
    async def safety_invitation_page(invitation_token: str) -> HTMLResponse:
        preview = None
        if re.fullmatch(r"[A-Za-z0-9_-]{43,86}", invitation_token):
            preview = await runtime_safety_repository.invitation_preview(
                _secret_hash(invitation_token)
            )
        return HTMLResponse(
            _safety_acceptance_page(
                invitation_token=invitation_token,
                preview=preview,
            ),
            status_code=200 if preview is not None else 404,
            headers=_safety_acceptance_headers(),
        )

    @app.post(
        "/safety/accept/{invitation_token}",
        response_class=HTMLResponse,
        include_in_schema=False,
    )
    async def decide_safety_invitation(
        request: Request, invitation_token: str
    ) -> HTMLResponse:
        if re.fullmatch(r"[A-Za-z0-9_-]{43,86}", invitation_token) is None:
            return HTMLResponse(
                _safety_acceptance_page(
                    invitation_token=invitation_token,
                    preview=None,
                ),
                status_code=404,
                headers=_safety_acceptance_headers(),
            )
        raw = await request.body()
        if len(raw) > 2_048:
            raise HTTPException(status_code=413, detail="form body is too large")
        try:
            values = parse_qs(
                raw.decode("utf-8"),
                keep_blank_values=False,
                max_num_fields=4,
            )
        except (UnicodeDecodeError, ValueError) as exc:
            raise HTTPException(status_code=400, detail="invalid form body") from exc
        decision = values.get("decision", [""])[0]
        if decision not in {"accept", "decline"}:
            raise HTTPException(status_code=422, detail="choose accept or decline")
        try:
            contact = await runtime_safety_repository.decide_invitation(
                invite_token_hash=_secret_hash(invitation_token),
                decision=decision,
                now=datetime.now(UTC),
            )
        except SafetyNotFoundError:
            return HTMLResponse(
                _safety_acceptance_page(
                    invitation_token=invitation_token,
                    preview=None,
                ),
                status_code=410,
                headers=_safety_acceptance_headers(),
            )
        outcome = (
            f"You are now an accepted emergency contact for "
            f"{contact['display_name']}'s invitation. You may close this page."
            if decision == "accept"
            else "The invitation was declined. You may close this page."
        )
        return HTMLResponse(
            _safety_acceptance_page(
                invitation_token=invitation_token,
                preview=None,
                outcome=outcome,
            ),
            headers=_safety_acceptance_headers(),
        )

    async def safety_response_preview(
        *,
        dispatch_id: UUID,
        contact_id: UUID,
        expires: int,
        signature: str,
    ) -> dict[str, Any] | None:
        now = datetime.now(UTC)
        if not runtime_safety_signer.verify(
            dispatch_id=str(dispatch_id),
            contact_id=str(contact_id),
            expires_at_unix=expires,
            signature=signature,
            now=now,
        ):
            return None
        preview = await runtime_safety_repository.responder_preview(
            dispatch_id=str(dispatch_id),
            contact_id=str(contact_id),
            now=now,
        )
        if preview is None or int(preview["expires_at"].timestamp()) != expires:
            return None
        return preview

    def twilio_webhook_is_valid(
        request: Request,
        values: dict[str, list[str]],
        *,
        canonical_url: str | None = None,
    ) -> bool:
        public_url = canonical_url
        if public_url is None:
            public_url = (
                f"{(runtime_settings.public_base_url or '').rstrip('/')}"
                f"{request.url.path}"
            )
            if request.url.query:
                public_url += f"?{request.url.query}"
        return validate_twilio_webhook(
            url=public_url,
            parameters=values,
            signature=request.headers.get("X-Twilio-Signature", ""),
            auth_token=runtime_settings.twilio_auth_token or "",
        )

    @app.get(
        "/safety/respond/{dispatch_id}/{contact_id}",
        response_class=HTMLResponse,
        include_in_schema=False,
    )
    async def safety_response_page(
        request: Request,
        dispatch_id: UUID,
        contact_id: UUID,
        expires: int = Query(..., gt=0),
        signature: str = Query(..., min_length=43, max_length=43),
    ) -> HTMLResponse:
        preview = await safety_response_preview(
            dispatch_id=dispatch_id,
            contact_id=contact_id,
            expires=expires,
            signature=signature,
        )
        action_url = request.url.path
        if request.url.query:
            action_url += f"?{request.url.query}"
        return HTMLResponse(
            _safety_response_page(
                preview=preview,
                action_url=action_url,
            ),
            status_code=200 if preview is not None else 404,
            headers=_safety_acceptance_headers(),
        )

    @app.post(
        "/safety/respond/{dispatch_id}/{contact_id}",
        response_class=HTMLResponse,
        include_in_schema=False,
    )
    async def decide_safety_response(
        request: Request,
        dispatch_id: UUID,
        contact_id: UUID,
        expires: int = Query(..., gt=0),
        signature: str = Query(..., min_length=43, max_length=43),
    ) -> HTMLResponse:
        preview = await safety_response_preview(
            dispatch_id=dispatch_id,
            contact_id=contact_id,
            expires=expires,
            signature=signature,
        )
        if preview is None:
            return HTMLResponse(
                _safety_response_page(
                    preview=None,
                    action_url="",
                ),
                status_code=404,
                headers=_safety_acceptance_headers(),
            )
        raw = await request.body()
        if len(raw) > 2_048:
            raise HTTPException(status_code=413, detail="form body is too large")
        try:
            values = parse_qs(
                raw.decode("utf-8"),
                keep_blank_values=False,
                max_num_fields=4,
            )
        except (UnicodeDecodeError, ValueError) as exc:
            raise HTTPException(status_code=400, detail="invalid form body") from exc
        decision = values.get("decision", [""])[0]
        if decision not in {"responding", "cannot_respond"}:
            raise HTTPException(
                status_code=422,
                detail="choose whether you can respond",
            )
        try:
            await runtime_safety_repository.record_responder_decision(
                dispatch_id=str(dispatch_id),
                contact_id=str(contact_id),
                decision=decision,
                source="sms_link",
                now=datetime.now(UTC),
            )
        except SafetyConflictError as exc:
            return HTMLResponse(
                _safety_response_page(
                    preview=preview,
                    action_url="",
                    outcome=str(exc),
                ),
                status_code=409,
                headers=_safety_acceptance_headers(),
            )
        outcome = (
            "Your response is saved. Call them now and coordinate with their "
            "Safety Network."
            if decision == "responding"
            else "Your response is saved. Their other Safety Network contacts "
            "can still respond."
        )
        return HTMLResponse(
            _safety_response_page(
                preview=preview,
                action_url="",
                outcome=outcome,
            ),
            headers=_safety_acceptance_headers(),
        )

    @app.post(
        "/v1/safety/provider/twilio/respond/{dispatch_id}/{contact_id}",
        include_in_schema=False,
    )
    async def twilio_safety_voice_response(
        request: Request,
        dispatch_id: UUID,
        contact_id: UUID,
        expires: int = Query(..., gt=0),
        signature: str = Query(..., min_length=43, max_length=43),
    ) -> Response:
        preview = await safety_response_preview(
            dispatch_id=dispatch_id,
            contact_id=contact_id,
            expires=expires,
            signature=signature,
        )
        if preview is None:
            return Response(
                "<Response><Say>This Safety response link is no longer valid."
                "</Say></Response>",
                status_code=403,
                media_type="application/xml",
            )
        raw = await request.body()
        if len(raw) > 16_384:
            raise HTTPException(status_code=413, detail="callback body is too large")
        try:
            values = parse_qs(
                raw.decode("utf-8"),
                keep_blank_values=False,
                max_num_fields=32,
            )
        except (UnicodeDecodeError, ValueError) as exc:
            raise HTTPException(
                status_code=400, detail="invalid callback body"
            ) from exc
        if runtime_settings.paging_configured and not twilio_webhook_is_valid(
            request, values
        ):
            return Response(
                "<Response><Say>This Safety response could not be verified."
                "</Say></Response>",
                status_code=403,
                media_type="application/xml",
            )
        digit = values.get("Digits", [""])[0]
        decision = {"1": "responding", "2": "cannot_respond"}.get(digit)
        if decision is None:
            return Response(
                "<Response><Say>No valid response was recorded. Please call "
                "the person directly.</Say></Response>",
                media_type="application/xml",
            )
        try:
            await runtime_safety_repository.record_responder_decision(
                dispatch_id=str(dispatch_id),
                contact_id=str(contact_id),
                decision=decision,
                source="voice_dtmf",
                now=datetime.now(UTC),
            )
        except SafetyConflictError:
            message = "This Safety page is already closed."
        else:
            message = (
                "Your response is recorded. Please call them now."
                if decision == "responding"
                else "Your response is recorded. Thank you."
            )
        return Response(
            f"<Response><Say>{html_lib.escape(message)}</Say></Response>",
            media_type="application/xml",
        )

    @app.post(
        "/v1/safety/provider/twilio/status",
        status_code=status.HTTP_204_NO_CONTENT,
        include_in_schema=False,
    )
    async def twilio_safety_delivery_receipt(
        request: Request,
        token: str = Query(default=""),
    ) -> Response:
        expected = runtime_settings.twilio_status_callback_secret or ""
        if not expected or not hmac.compare_digest(
            token.encode("utf-8"), expected.encode("utf-8")
        ):
            raise HTTPException(status_code=401, detail="invalid callback token")
        raw = await request.body()
        if len(raw) > 16_384:
            raise HTTPException(status_code=413, detail="callback body is too large")
        try:
            values = parse_qs(
                raw.decode("utf-8"),
                keep_blank_values=False,
                max_num_fields=32,
            )
        except (UnicodeDecodeError, ValueError) as exc:
            raise HTTPException(
                status_code=400, detail="invalid callback body"
            ) from exc
        if not twilio_webhook_is_valid(
            request,
            values,
            canonical_url=runtime_twilio_callback_url,
        ):
            raise HTTPException(
                status_code=401,
                detail="invalid callback signature",
            )
        provider_reference = (
            values.get("MessageSid", [""])[0] or values.get("CallSid", [""])[0]
        )
        provider_status = (
            values.get("MessageStatus", [""])[0] or values.get("CallStatus", [""])[0]
        )
        if provider_reference and provider_status:
            now = datetime.now(UTC)
            updated = await runtime_safety_repository.update_provider_receipt(
                provider_reference=provider_reference,
                status=normalise_provider_status(provider_status),
                now=now,
                retry_at=now
                + timedelta(seconds=runtime_settings.safety_retry_base_seconds),
            )
            if updated:
                runtime_safety_worker.wake()
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    router = APIRouter(
        prefix="/v1",
        dependencies=[Depends(require_api_token)],
    )

    @router.get("/safety/operations", tags=["operations"])
    async def safety_operations() -> dict[str, Any]:
        return {
            "paging_configured": runtime_paging_provider.available,
            **await runtime_safety_repository.monitoring_snapshot(
                now=datetime.now(UTC)
            ),
        }

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

    @router.post(
        "/safety/bootstrap",
        status_code=status.HTTP_201_CREATED,
        tags=["safety-admin"],
    )
    async def bootstrap_safety_profile(
        body: SafetyProfileBootstrap,
    ) -> dict[str, Any]:
        try:
            profile = await runtime_safety_repository.create_profile(
                profile_id=str(uuid4()),
                enrollment_id=str(body.enrollment_id),
                display_name=body.display_name,
                installation_id=body.installation_id,
                token_hash=_secret_hash(body.safety_token.get_secret_value()),
            )
        except (SafetyNotFoundError, SafetyConflictError) as exc:
            raise_safety_error(exc)
            raise AssertionError("unreachable")
        return {
            "profile": profile,
            "credential_notice": (
                "The supplied safety token was stored only as a digest. It can "
                "manage this installation's emergency contacts and manual "
                "pages, but cannot read biometric data."
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

    @social_router.delete(
        "/enrollments/{enrollment_id}",
        status_code=status.HTTP_204_NO_CONTENT,
        tags=["friends"],
    )
    async def delete_social_enrollment(
        enrollment_id: UUID,
        credentials: Annotated[
            HTTPAuthorizationCredentials | None,
            Depends(security),
        ],
        confirmation: Annotated[str | None, Header(alias="X-Noop-Confirm")] = None,
    ) -> Response:
        if confirmation != "DELETE PENDING SOCIAL ENROLLMENT":
            raise HTTPException(
                status_code=412,
                detail=("set X-Noop-Confirm to 'DELETE PENDING SOCIAL ENROLLMENT'"),
            )
        supplied = (
            credentials.credentials
            if credentials is not None and credentials.scheme.casefold() == "bearer"
            else ""
        )
        if not supplied.startswith("noop_member_"):
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="invalid or missing member token",
                headers={"WWW-Authenticate": "Bearer"},
            )
        try:
            await runtime_repository.delete_friend_enrollment_data(
                str(enrollment_id),
                _secret_hash(supplied),
            )
        except FriendForbiddenError as exc:
            raise HTTPException(status_code=403, detail=str(exc)) from exc
        return Response(status_code=status.HTTP_204_NO_CONTENT)

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

    safety_router = APIRouter(prefix="/v1/safety")

    def safety_contacts_payload(
        contacts: list[dict[str, Any]],
    ) -> dict[str, Any]:
        now = datetime.now(UTC)
        public_contacts = [
            _safety_contact_response(contact, now=now) for contact in contacts
        ]
        accepted_count = sum(
            contact["status"] == "accepted" for contact in public_contacts
        )
        return {
            "contacts": public_contacts,
            "accepted_count": accepted_count,
            "minimum_accepted": 2,
            "maximum_contacts": 5,
            "paging_configured": runtime_paging_provider.available,
        }

    async def send_contact_invitation(
        *,
        request: Request,
        profile: dict[str, Any],
        contact: dict[str, Any],
        invitation_token: str,
    ) -> dict[str, Any]:
        base_url = (
            runtime_settings.public_base_url.rstrip("/")
            if runtime_settings.public_base_url
            else str(request.base_url).rstrip("/")
        )
        acceptance_url = f"{base_url}/safety/accept/{quote(invitation_token, safe='')}"
        try:
            submission = await runtime_paging_provider.send_invitation(
                to_phone=str(contact["phone_e164"]),
                contact_name=str(contact["display_name"]),
                owner_name=str(profile["display_name"]),
                acceptance_url=acceptance_url,
            )
            return await runtime_safety_repository.update_invitation_delivery(
                profile_id=str(profile["profile_id"]),
                contact_id=str(contact["contact_id"]),
                status=submission.status,
                provider_reference=submission.provider_reference,
                error=None,
            )
        except PagingUnavailableError as exc:
            return await runtime_safety_repository.update_invitation_delivery(
                profile_id=str(profile["profile_id"]),
                contact_id=str(contact["contact_id"]),
                status="failed",
                provider_reference=None,
                error=_safe_provider_error(exc),
            )

    @safety_router.get("/me", tags=["safety"])
    async def safety_profile(
        member: Annotated[dict[str, Any], Depends(require_safety_profile)],
    ) -> dict[str, Any]:
        contacts = await runtime_safety_repository.list_contacts(
            str(member["profile_id"])
        )
        return {
            "profile": member,
            **safety_contacts_payload(contacts),
            "automatic_escalation": {
                "enabled": False,
                "reason": (
                    "No validated critical-event detector is configured. "
                    "Wellness and anomaly estimates cannot trigger a page."
                ),
            },
        }

    @safety_router.get("/contacts", tags=["safety"])
    async def safety_contacts(
        member: Annotated[dict[str, Any], Depends(require_safety_profile)],
    ) -> dict[str, Any]:
        contacts = await runtime_safety_repository.list_contacts(
            str(member["profile_id"])
        )
        return safety_contacts_payload(contacts)

    @safety_router.post(
        "/contacts",
        status_code=status.HTTP_201_CREATED,
        tags=["safety"],
    )
    async def add_safety_contact(
        request: Request,
        body: SafetyContactCreate,
        member: Annotated[dict[str, Any], Depends(require_safety_profile)],
    ) -> dict[str, Any]:
        if not runtime_paging_provider.available:
            raise HTTPException(
                status_code=503,
                detail=("SMS and voice paging are not configured on this server"),
            )
        invitation_token = _new_safety_invitation_token()
        now = datetime.now(UTC)
        try:
            contact = await runtime_safety_repository.create_contact(
                contact_id=str(uuid4()),
                profile_id=str(member["profile_id"]),
                display_name=body.display_name,
                phone_e164=body.phone_e164,
                invite_token_hash=_secret_hash(invitation_token),
                invited_at=now,
                invite_expires_at=now + timedelta(days=7),
            )
        except (SafetyNotFoundError, SafetyConflictError) as exc:
            raise_safety_error(exc)
            raise AssertionError("unreachable")
        delivered = await send_contact_invitation(
            request=request,
            profile=member,
            contact=contact,
            invitation_token=invitation_token,
        )
        return {
            "contact": _safety_contact_response(delivered),
            "notice": (
                "The recipient must explicitly accept before this contact can "
                "receive a safety page."
            ),
        }

    @safety_router.post(
        "/contacts/{contact_id}/resend",
        tags=["safety"],
    )
    async def resend_safety_contact_invitation(
        request: Request,
        contact_id: UUID,
        member: Annotated[dict[str, Any], Depends(require_safety_profile)],
    ) -> dict[str, Any]:
        if not runtime_paging_provider.available:
            raise HTTPException(
                status_code=503,
                detail=("SMS and voice paging are not configured on this server"),
            )
        invitation_token = _new_safety_invitation_token()
        now = datetime.now(UTC)
        try:
            contact = await runtime_safety_repository.renew_invitation(
                profile_id=str(member["profile_id"]),
                contact_id=str(contact_id),
                invite_token_hash=_secret_hash(invitation_token),
                invited_at=now,
                invite_expires_at=now + timedelta(days=7),
            )
        except (SafetyNotFoundError, SafetyConflictError) as exc:
            raise_safety_error(exc)
            raise AssertionError("unreachable")
        delivered = await send_contact_invitation(
            request=request,
            profile=member,
            contact=contact,
            invitation_token=invitation_token,
        )
        return {"contact": _safety_contact_response(delivered)}

    @safety_router.delete(
        "/contacts/{contact_id}",
        status_code=status.HTTP_204_NO_CONTENT,
        tags=["safety"],
    )
    async def remove_safety_contact(
        contact_id: UUID,
        member: Annotated[dict[str, Any], Depends(require_safety_profile)],
    ) -> Response:
        try:
            await runtime_safety_repository.revoke_contact(
                profile_id=str(member["profile_id"]),
                contact_id=str(contact_id),
                now=datetime.now(UTC),
            )
        except SafetyNotFoundError as exc:
            raise_safety_error(exc)
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    @safety_router.post(
        "/pages",
        tags=["safety"],
        status_code=status.HTTP_202_ACCEPTED,
    )
    @safety_router.post(
        "/incidents",
        tags=["safety"],
        status_code=status.HTTP_202_ACCEPTED,
    )
    async def create_safety_page(
        body: SafetyPageCreate,
        member: Annotated[dict[str, Any], Depends(require_safety_profile)],
        idempotency_key: Annotated[str | None, Header(alias="Idempotency-Key")] = None,
    ) -> Any:
        if not runtime_paging_provider.available:
            raise HTTPException(
                status_code=503,
                detail=("SMS and voice paging are not configured on this server"),
            )
        if idempotency_key is None:
            raise HTTPException(
                status_code=400,
                detail="Idempotency-Key is required for a safety page",
            )
        try:
            idempotency_uuid = str(UUID(idempotency_key))
        except ValueError as exc:
            raise HTTPException(
                status_code=400,
                detail="Idempotency-Key must be a UUID",
            ) from exc
        request_hash = hashlib.sha256(
            json.dumps(
                body.model_dump(mode="json"),
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
        ).hexdigest()
        now = datetime.now(UTC)
        try:
            dispatch = await runtime_safety_repository.create_dispatch(
                dispatch_id=str(uuid4()),
                profile_id=str(member["profile_id"]),
                idempotency_key=idempotency_uuid,
                request_hash=request_hash,
                trigger=body.trigger,
                now=now,
                expires_at=now
                + timedelta(seconds=runtime_settings.safety_incident_ttl_seconds),
                voice_fallback_at=now
                + timedelta(
                    seconds=(runtime_settings.safety_acknowledgement_timeout_seconds)
                ),
            )
        except (SafetyConflictError, SafetyNotReadyError) as exc:
            raise_safety_error(exc)
            raise AssertionError("unreachable")
        if not dispatch["idempotent_replay"]:
            runtime_safety_worker.wake()
        return _safety_dispatch_response(dispatch)

    @safety_router.get("/incidents", tags=["safety"])
    async def safety_incidents(
        member: Annotated[dict[str, Any], Depends(require_safety_profile)],
        limit: int = Query(default=20, ge=1, le=100),
    ) -> dict[str, Any]:
        incidents = await runtime_safety_repository.list_dispatches(
            profile_id=str(member["profile_id"]),
            limit=limit,
        )
        return {
            "incidents": [_safety_dispatch_response(incident) for incident in incidents]
        }

    @safety_router.get("/pages/{dispatch_id}", tags=["safety"])
    @safety_router.get("/incidents/{dispatch_id}", tags=["safety"])
    async def safety_page_status(
        dispatch_id: UUID,
        member: Annotated[dict[str, Any], Depends(require_safety_profile)],
    ) -> dict[str, Any]:
        try:
            dispatch = await runtime_safety_repository.dispatch(
                profile_id=str(member["profile_id"]),
                dispatch_id=str(dispatch_id),
            )
        except SafetyNotFoundError as exc:
            raise_safety_error(exc)
            raise AssertionError("unreachable")
        return _safety_dispatch_response(dispatch)

    @safety_router.put(
        "/incidents/{dispatch_id}/location",
        tags=["safety"],
    )
    async def update_safety_incident_location(
        dispatch_id: UUID,
        body: SafetyLocationUpdate,
        member: Annotated[dict[str, Any], Depends(require_safety_profile)],
    ) -> dict[str, Any]:
        now = datetime.now(UTC)
        if body.captured_at < now - timedelta(minutes=5):
            raise HTTPException(
                status_code=422,
                detail="location fix is too old",
            )
        if body.captured_at > now + timedelta(minutes=1):
            raise HTTPException(
                status_code=422,
                detail="location fix is in the future",
            )
        try:
            location = await runtime_safety_repository.update_incident_location(
                profile_id=str(member["profile_id"]),
                dispatch_id=str(dispatch_id),
                sequence=body.sequence,
                latitude=body.latitude,
                longitude=body.longitude,
                horizontal_accuracy_meters=body.horizontal_accuracy_meters,
                captured_at=body.captured_at,
                received_at=now,
            )
        except (SafetyNotFoundError, SafetyConflictError) as exc:
            raise_safety_error(exc)
            raise AssertionError("unreachable")
        return {
            "location": location,
            "retention": "latest_only",
        }

    async def transition_safety_incident(
        *,
        action: str,
        dispatch_id: UUID,
        body: SafetyIncidentTransition,
        member: dict[str, Any],
    ) -> dict[str, Any]:
        try:
            incident = await runtime_safety_repository.transition_dispatch(
                profile_id=str(member["profile_id"]),
                dispatch_id=str(dispatch_id),
                action=action,
                note=body.note,
                now=datetime.now(UTC),
            )
        except (SafetyNotFoundError, SafetyConflictError) as exc:
            raise_safety_error(exc)
            raise AssertionError("unreachable")
        return _safety_dispatch_response(incident)

    @safety_router.post(
        "/incidents/{dispatch_id}/resolve",
        tags=["safety"],
    )
    async def resolve_safety_incident(
        dispatch_id: UUID,
        body: SafetyIncidentTransition,
        member: Annotated[dict[str, Any], Depends(require_safety_profile)],
    ) -> dict[str, Any]:
        return await transition_safety_incident(
            action="resolve",
            dispatch_id=dispatch_id,
            body=body,
            member=member,
        )

    @safety_router.post(
        "/incidents/{dispatch_id}/cancel",
        tags=["safety"],
    )
    async def cancel_safety_incident(
        dispatch_id: UUID,
        body: SafetyIncidentTransition,
        member: Annotated[dict[str, Any], Depends(require_safety_profile)],
    ) -> dict[str, Any]:
        return await transition_safety_incident(
            action="cancel",
            dispatch_id=dispatch_id,
            body=body,
            member=member,
        )

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
    app.include_router(safety_router)

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
