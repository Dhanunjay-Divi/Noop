from __future__ import annotations

import json
import re

from fastapi import FastAPI, HTTPException, Request
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app
from app.observability import (
    REQUEST_ID_HEADER_TEXT,
    RequestObservabilityMiddleware,
    emit_operational_event,
    internal_server_error_response,
)
from app.repository import MemoryRepository


TOKEN = "observability-test-token-abcdefghijklmnopqrstuvwxyz"
REQUEST_ID = re.compile(r"^[0-9a-f]{32}$")


def test_request_log_uses_route_template_and_server_correlation_id() -> None:
    records: list[tuple[str, dict[str, object]]] = []

    def sink(event: str, **fields: object) -> None:
        records.append((event, fields))

    app = FastAPI()
    app.add_middleware(
        RequestObservabilityMiddleware,
        service="test-api",
        sink=sink,
    )

    @app.get("/v1/items/{item_id}")
    async def item(item_id: str, request: Request) -> dict[str, str]:
        request.state.auth_scope = "installation"
        request.state.auth_result = "installation_accepted"
        return {"item": item_id}

    with TestClient(app) as client:
        response = client.get("/v1/items/private-user-value")

    request_id = response.headers[REQUEST_ID_HEADER_TEXT]
    assert REQUEST_ID.fullmatch(request_id)
    assert len(records) == 1
    event, fields = records[0]
    assert event == "http.request"
    assert fields["service"] == "test-api"
    assert fields["request_id"] == request_id
    assert fields["route"] == "/v1/items/{item_id}"
    assert fields["status_code"] == 200
    assert fields["auth_scope"] == "installation"
    assert fields["auth_result"] == "installation_accepted"
    assert "private-user-value" not in repr(records)


def test_request_log_covers_rejections_before_body_parsing() -> None:
    app = create_app(
        settings=Settings(
            api_token=TOKEN,
            database_url=None,
            max_request_bytes=64,
        ),
        repository=MemoryRepository(),
    )

    with TestClient(app) as client:
        response = client.post(
            "/v1/social/invites/join",
            content=b"x" * 65,
            headers={"Content-Type": "application/json"},
        )

    assert response.status_code == 413
    assert REQUEST_ID.fullmatch(response.headers[REQUEST_ID_HEADER_TEXT])


def test_successful_health_probe_is_not_logged() -> None:
    records: list[tuple[str, dict[str, object]]] = []

    def sink(event: str, **fields: object) -> None:
        records.append((event, fields))

    app = FastAPI()
    app.add_middleware(
        RequestObservabilityMiddleware,
        service="test-api",
        sink=sink,
    )

    @app.get("/healthz")
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    with TestClient(app) as client:
        response = client.get("/healthz")

    assert response.status_code == 200
    assert REQUEST_ID.fullmatch(response.headers[REQUEST_ID_HEADER_TEXT])
    assert records == []


def test_unhandled_error_returns_correlation_without_exception_detail() -> None:
    records: list[tuple[str, dict[str, object]]] = []

    def sink(event: str, **fields: object) -> None:
        records.append((event, fields))

    app = FastAPI()
    app.add_middleware(
        RequestObservabilityMiddleware,
        service="test-api",
        sink=sink,
    )
    app.add_exception_handler(Exception, internal_server_error_response)

    @app.get("/v1/fail")
    async def fail() -> None:
        raise RuntimeError("private exception detail")

    with TestClient(app) as client:
        response = client.get("/v1/fail")

    request_id = response.headers[REQUEST_ID_HEADER_TEXT]
    assert response.status_code == 500
    assert response.json() == {"detail": "internal server error"}
    assert REQUEST_ID.fullmatch(request_id)
    assert records[0][1]["request_id"] == request_id
    assert records[0][1]["failure_kind"] == "RuntimeError"
    assert "private exception detail" not in repr(records)
    assert "private exception detail" not in response.text


def test_structured_event_drops_sensitive_fields(capsys) -> None:
    identity = "identity-token-that-must-never-appear"
    phone = "+15555550123"
    installation = "noop-private-installation"
    signed_url = "https://private.example/signed"
    user_note = "private user text"
    emit_operational_event(
        "test.event",
        route="/v1/managed/chunks/{chunk_id}",
        request_id="a" * 32,
        authorization=identity,
        phone_number=phone,
        installation_id=installation,
        request_url=signed_url,
        user_note=user_note,
        status_code=503,
    )

    record = json.loads(capsys.readouterr().out)
    serialized = json.dumps(record)
    assert record["schema"] == "noop.operations.v1"
    assert record["service"] == "noop-server"
    assert record["route"] == "/v1/managed/chunks/{chunk_id}"
    assert record["request_id"] == "a" * 32
    assert record["status_code"] == 503
    assert record["redacted_fields"] == 5
    assert identity not in serialized
    assert phone not in serialized
    assert installation not in serialized
    assert signed_url not in serialized
    assert user_note not in serialized


def test_structured_event_is_best_effort_and_normalizes_non_finite(
    capsys,
    monkeypatch,
) -> None:
    emit_operational_event("test.non_finite", ratio=float("nan"))
    record = json.loads(capsys.readouterr().out)
    assert record["ratio"] == "non_finite"

    class BrokenOutput:
        def write(self, _: str) -> None:
            raise OSError("sink unavailable")

        def flush(self) -> None:
            raise OSError("sink unavailable")

    monkeypatch.setattr("app.observability.sys.stdout", BrokenOutput())
    emit_operational_event("test.sink_failure", outcome="completed")


def test_request_sink_failure_does_not_change_response() -> None:
    def broken_sink(_: str, **__: object) -> None:
        raise RuntimeError("diagnostic sink failed")

    app = FastAPI()
    app.add_middleware(
        RequestObservabilityMiddleware,
        service="test-api",
        sink=broken_sink,
    )

    @app.get("/v1/ok")
    async def ok() -> dict[str, str]:
        return {"status": "ok"}

    with TestClient(app) as client:
        response = client.get("/v1/ok")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}
    assert REQUEST_ID.fullmatch(response.headers[REQUEST_ID_HEADER_TEXT])


def test_error_response_keeps_fixed_auth_category_without_credentials() -> None:
    records: list[tuple[str, dict[str, object]]] = []

    def sink(event: str, **fields: object) -> None:
        records.append((event, fields))

    app = FastAPI()
    app.add_middleware(
        RequestObservabilityMiddleware,
        service="test-api",
        sink=sink,
    )

    @app.get("/v1/private")
    async def private(request: Request) -> None:
        request.state.auth_result = "identity_rejected"
        raise HTTPException(status_code=401, detail="rejected")

    with TestClient(app) as client:
        response = client.get(
            "/v1/private",
            headers={"Authorization": "Bearer private-credential"},
        )

    assert response.status_code == 401
    assert records[0][1]["auth_result"] == "identity_rejected"
    assert records[0][1]["severity"] == "WARNING"
    assert "private-credential" not in repr(records)
