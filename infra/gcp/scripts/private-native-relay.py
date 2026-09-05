#!/usr/bin/env python3
"""Loopback-only IAM relay for private synthetic NOOP+ simulator testing."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Lock

SCRIPT_DIR = Path(__file__).resolve().parent
INFRA_DIR = SCRIPT_DIR.parent
EXPECTED_OPT_IN = "private-synthetic-staging"
MAX_REQUEST_BYTES = 12 * 1024 * 1024
HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
}


class RelayFailure(RuntimeError):
    """A bounded relay failure with no request data."""


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Return upstream redirects to the native client without following them."""

    def redirect_request(
        self,
        req: urllib.request.Request,
        fp: object,
        code: int,
        msg: str,
        headers: object,
        newurl: str,
    ) -> None:
        del req, fp, code, msg, headers, newurl
        return None


NO_REDIRECT_OPENER = urllib.request.build_opener(NoRedirectHandler())


def command(*arguments: str) -> str:
    try:
        return subprocess.check_output(
            list(arguments),
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        raise RelayFailure("operator credential refresh failed") from None


def validated_target(managed: dict[str, object]) -> str:
    raw = str(managed.get("uri") or "")
    parsed = urllib.parse.urlsplit(raw)
    try:
        port = parsed.port
    except ValueError:
        raise RelayFailure("managed runtime is not private") from None
    if (
        managed.get("public") is not False
        or parsed.scheme != "https"
        or parsed.hostname is None
        or parsed.hostname == ".run.app"
        or not parsed.hostname.endswith(".run.app")
        or parsed.username is not None
        or parsed.password is not None
        or port not in (None, 443)
        or parsed.path not in ("", "/")
        or parsed.query
        or parsed.fragment
    ):
        raise RelayFailure("managed runtime is not private")
    return raw.rstrip("/")


def allowed_request_target(value: str) -> bool:
    parsed = urllib.parse.urlsplit(value)
    return (
        len(value) <= 4096
        and not parsed.scheme
        and not parsed.netloc
        and not parsed.fragment
        and (
            parsed.path.startswith("/v1/managed/")
            or parsed.path in {"/healthz", "/readyz"}
        )
    )


class IdentityToken:
    def __init__(self) -> None:
        self._value = ""
        self._valid_until = 0.0
        self._lock = Lock()

    def value(self) -> str:
        with self._lock:
            if self._value and time.monotonic() < self._valid_until:
                return self._value
            value = command("gcloud", "auth", "print-identity-token")
            if value.count(".") != 2:
                raise RelayFailure("operator identity assertion is invalid")
            self._value = value
            self._valid_until = time.monotonic() + 45 * 60
            return value


class RelayHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    target = ""
    identity = IdentityToken()

    def do_GET(self) -> None:
        self._relay()

    def do_POST(self) -> None:
        self._relay()

    def do_PUT(self) -> None:
        self._relay()

    def do_PATCH(self) -> None:
        self._relay()

    def do_DELETE(self) -> None:
        self._relay()

    def do_OPTIONS(self) -> None:
        self._relay()

    def log_message(self, format: str, *args: object) -> None:
        del format, args

    def _relay(self) -> None:
        try:
            if not allowed_request_target(self.path):
                self._empty(400)
                return
            raw_length = self.headers.get("Content-Length", "0")
            try:
                length = int(raw_length)
            except ValueError:
                self._empty(400)
                return
            if length < 0 or length > MAX_REQUEST_BYTES:
                self._empty(413)
                return
            body = self.rfile.read(length) if length else None
            headers = {
                key: value
                for key, value in self.headers.items()
                if key.lower() not in HOP_BY_HOP
                and key.lower()
                not in {"host", "content-length", "x-serverless-authorization"}
            }
            headers["X-Serverless-Authorization"] = f"Bearer {self.identity.value()}"
            request = urllib.request.Request(
                self.target + self.path,
                data=body,
                method=self.command,
                headers=headers,
            )
            try:
                with NO_REDIRECT_OPENER.open(request, timeout=75) as response:
                    status = response.status
                    response_headers = response.headers
                    payload = response.read(MAX_REQUEST_BYTES + 1)
            except urllib.error.HTTPError as error:
                status = error.code
                response_headers = error.headers
                payload = error.read(MAX_REQUEST_BYTES + 1)
            if len(payload) > MAX_REQUEST_BYTES:
                self._empty(502)
                return
            self.send_response(status)
            for key, value in response_headers.items():
                if key.lower() not in HOP_BY_HOP and key.lower() != "content-length":
                    self.send_header(key, value)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            if payload:
                self.wfile.write(payload)
        except (OSError, TimeoutError, ValueError, RelayFailure):
            self._empty(502)

    def _empty(self, status: int) -> None:
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8765)
    arguments = parser.parse_args()
    if os.getenv("NOOP_ALLOW_PRIVATE_NATIVE_PILOT") != EXPECTED_OPT_IN:
        raise SystemExit("FAIL explicit private synthetic pilot opt-in is required")
    if not 1024 <= arguments.port <= 65535:
        raise SystemExit("FAIL relay port must be 1024 through 65535")
    try:
        managed = json.loads(
            command(
                "tofu",
                f"-chdir={INFRA_DIR}",
                "output",
                "-json",
                "managed_api",
            )
        )
    except json.JSONDecodeError:
        raise SystemExit("FAIL private staging output is invalid") from None
    try:
        target = validated_target(managed)
    except RelayFailure as error:
        raise SystemExit(f"FAIL {error}") from None
    RelayHandler.target = target
    server = ThreadingHTTPServer(("127.0.0.1", arguments.port), RelayHandler)
    print(f"PASS private native relay listening on loopback port {arguments.port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
