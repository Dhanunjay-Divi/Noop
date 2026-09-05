from __future__ import annotations

import json
import math
import re
import sys
import threading
import time
from datetime import UTC, datetime
from typing import Any, Callable
from uuid import uuid4

from fastapi import Request, status
from fastapi.responses import JSONResponse

REQUEST_ID_HEADER = b"x-noop-request-id"
REQUEST_ID_HEADER_TEXT = "X-Noop-Request-ID"
_MAX_FIELDS = 32
_MAX_TOKEN_LENGTH = 192
_TOKEN_RE = re.compile(r"[^A-Za-z0-9_./:{}@+-]")
_SENSITIVE_FIELD_FRAGMENTS = (
    "account_id",
    "account_scope",
    "address",
    "authorization",
    "biometric",
    "body",
    "contact_id",
    "cookie",
    "credential",
    "delivery_id",
    "device_id",
    "dispatch_id",
    "email",
    "endpoint",
    "health_value",
    "installation_id",
    "invite",
    "journal",
    "latitude",
    "location",
    "longitude",
    "member_id",
    "message",
    "note",
    "object_key",
    "otp",
    "password",
    "path",
    "payload",
    "phone",
    "profile_id",
    "query",
    "serial",
    "session_id",
    "secret",
    "signed_url",
    "source_id",
    "text",
    "token",
    "url",
    "user_id",
    "uuid",
)
_OUTPUT_LOCK = threading.Lock()


def _safe_token(value: object, *, fallback: str = "unknown") -> str:
    try:
        text = str(value)[:_MAX_TOKEN_LENGTH]
    except Exception:
        return fallback
    token = _TOKEN_RE.sub("_", text)
    return token or fallback


def _safe_fields(fields: dict[str, object]) -> dict[str, object]:
    result: dict[str, object] = {}
    redacted = 0
    for raw_key, raw_value in list(fields.items())[:_MAX_FIELDS]:
        key = _safe_token(raw_key)
        lowered = key.casefold()
        if any(fragment in lowered for fragment in _SENSITIVE_FIELD_FRAGMENTS):
            redacted += 1
            continue
        if raw_value is None:
            continue
        if isinstance(raw_value, bool | int):
            result[key] = raw_value
        elif isinstance(raw_value, float):
            result[key] = raw_value if math.isfinite(raw_value) else "non_finite"
        else:
            result[key] = _safe_token(raw_value)
    if redacted:
        result["redacted_fields"] = redacted
    return result


def emit_operational_event(
    event: str,
    *,
    severity: str = "INFO",
    service: str = "noop-server",
    **fields: object,
) -> None:
    """Write one Cloud Logging-compatible JSON line containing fixed operational facts."""

    try:
        record: dict[str, object] = {
            "schema": "noop.operations.v1",
            "timestamp": datetime.now(UTC).isoformat(),
            "severity": _safe_token(severity.upper()),
            "service": _safe_token(service),
            "event": _safe_token(event),
        }
        record.update(_safe_fields(fields))
        line = json.dumps(
            record,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        )
        with _OUTPUT_LOCK:
            sys.stdout.write(line + "\n")
            sys.stdout.flush()
    except Exception:
        # Operational evidence is best-effort and must never change request or
        # worker success when the process log sink itself is unavailable.
        return


OperationalSink = Callable[..., None]


async def internal_server_error_response(
    request: Request,
    _: Exception,
) -> JSONResponse:
    """Return a generic 500 with the correlation id created by request middleware."""

    return _internal_server_error_response(request.scope.get("noop_request_id"))


def _internal_server_error_response(request_id: object) -> JSONResponse:
    headers = {
        "Cache-Control": "no-store",
        "Referrer-Policy": "no-referrer",
        "X-Content-Type-Options": "nosniff",
        "X-Frame-Options": "DENY",
    }
    if isinstance(request_id, str) and re.fullmatch(r"[0-9a-f]{32}", request_id):
        headers[REQUEST_ID_HEADER_TEXT] = request_id
    return JSONResponse(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        content={"detail": "internal server error"},
        headers=headers,
    )


class RequestObservabilityMiddleware:
    """Emit payload-free request summaries and return a bounded correlation id."""

    def __init__(
        self,
        app: Any,
        *,
        service: str,
        sink: OperationalSink = emit_operational_event,
    ) -> None:
        self.app = app
        self.service = _safe_token(service)
        self.sink = sink

    async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> None:
        if scope.get("type") != "http":
            await self.app(scope, receive, send)
            return

        request_id = uuid4().hex
        scope["noop_request_id"] = request_id
        started = time.perf_counter()
        status_code = 500
        response_bytes = 0
        response_started = False
        response_complete = False

        async def observed_send(message: dict[str, Any]) -> None:
            nonlocal status_code, response_bytes, response_started, response_complete
            if message.get("type") == "http.response.start":
                response_started = True
                status_code = int(message.get("status", 500))
                headers = [
                    (name, value)
                    for name, value in message.get("headers", [])
                    if name.lower() != REQUEST_ID_HEADER
                ]
                headers.append((REQUEST_ID_HEADER, request_id.encode("ascii")))
                message = {**message, "headers": headers}
            elif message.get("type") == "http.response.body":
                response_bytes += len(message.get("body", b""))
                response_complete = not bool(message.get("more_body", False))
            await send(message)

        failure_kind: str | None = None
        try:
            await self.app(scope, receive, observed_send)
        except Exception as error:
            failure_kind = type(error).__name__
            if not response_started:
                response = _internal_server_error_response(request_id)
                await response(scope, receive, observed_send)
            elif not response_complete:
                # The status cannot change after a streaming response starts.
                # Close it without rethrowing arbitrary exception text into the
                # process log; the request event still records the failure.
                await send(
                    {
                        "type": "http.response.body",
                        "body": b"",
                        "more_body": False,
                    }
                )
        finally:
            route = scope.get("route")
            route_template = getattr(route, "path", "unrouted")
            if not (
                failure_kind is None
                and status_code < 400
                and route_template in {"/healthz", "/readyz"}
            ):
                state = scope.get("state")
                state_fields = state if isinstance(state, dict) else {}
                fields: dict[str, object] = {
                    "service": self.service,
                    "request_id": request_id,
                    "method": scope.get("method", "UNKNOWN"),
                    "route": route_template,
                    "status_code": status_code,
                    "status_family": f"{status_code // 100}xx",
                    "duration_ms": max(
                        0,
                        int((time.perf_counter() - started) * 1_000),
                    ),
                    "response_bytes_bucket": _byte_bucket(response_bytes),
                    "outcome": "exception" if failure_kind else "completed",
                    "auth_scope": state_fields.get("auth_scope"),
                    "auth_result": state_fields.get("auth_result"),
                    "failure_kind": failure_kind,
                }
                severity = (
                    "ERROR"
                    if status_code >= 500 or failure_kind
                    else "WARNING"
                    if status_code >= 400
                    else "INFO"
                )
                try:
                    self.sink("http.request", severity=severity, **fields)
                except Exception:
                    # A diagnostic sink must not replace the response or mask
                    # the application exception already in flight.
                    pass


def _byte_bucket(value: int) -> str:
    if value <= 0:
        return "empty"
    if value < 1_024:
        return "lt_1_kib"
    if value < 10 * 1_024:
        return "lt_10_kib"
    if value < 100 * 1_024:
        return "lt_100_kib"
    if value < 1_024 * 1_024:
        return "lt_1_mib"
    return "gte_1_mib"
