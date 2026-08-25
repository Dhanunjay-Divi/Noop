#!/usr/bin/env python3
"""Provision disposable shared-mode installation credentials for k6."""

from __future__ import annotations

import argparse
import json
import os
import secrets
import tempfile
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from uuid import uuid4


def _write_private(path: Path, rows: list[dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(
        prefix=f".{path.name}.",
        dir=path.parent,
        text=True,
    )
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(rows, handle, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--admin-token", required=True)
    parser.add_argument("--count", type=int, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    if (
        os.getenv("NOOP_LOAD_ALLOW_ENROLLMENT")
        != "I_UNDERSTAND_THIS_CREATES_DISPOSABLE_CREDENTIALS"
    ):
        parser.error(
            "set NOOP_LOAD_ALLOW_ENROLLMENT="
            "I_UNDERSTAND_THIS_CREATES_DISPOSABLE_CREDENTIALS"
        )
    if arguments.count < 1 or arguments.count > 10_000:
        parser.error("--count must be from 1 through 10000")
    base_url = arguments.base_url.rstrip("/")
    if not base_url.startswith("https://") and not base_url.startswith(
        ("http://127.0.0.1", "http://localhost")
    ):
        parser.error("--base-url must use HTTPS except on loopback")
    rows: list[dict[str, str]] = []
    if arguments.output.exists():
        loaded = json.loads(arguments.output.read_text(encoding="utf-8"))
        if not isinstance(loaded, list):
            parser.error("--output must contain a JSON array")
        rows = loaded
    for _ in range(len(rows), arguments.count):
        installation_id = str(uuid4())
        token = f"noop_install_{secrets.token_urlsafe(32)}"
        body = json.dumps(
            {
                "installation_id": installation_id,
                "enrollment_id": str(uuid4()),
                "installation_token": token,
            }
        ).encode("utf-8")
        request = Request(
            f"{base_url}/v1/admin/installations",
            data=body,
            method="POST",
            headers={
                "Authorization": f"Bearer {arguments.admin_token}",
                "Content-Type": "application/json",
            },
        )
        try:
            with urlopen(request, timeout=15) as response:
                if response.status != 201:
                    raise RuntimeError(
                        f"installation enrollment returned HTTP {response.status}"
                    )
        except HTTPError as exc:
            raise RuntimeError(
                f"installation enrollment returned HTTP {exc.code}"
            ) from exc
        rows.append({"installation_id": installation_id, "token": token})
        _write_private(arguments.output, rows)
    print(
        f"provisioned {len(rows)} disposable installation credentials in "
        f"{arguments.output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
