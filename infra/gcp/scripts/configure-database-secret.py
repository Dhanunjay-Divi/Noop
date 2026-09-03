#!/usr/bin/env python3
"""Create/rotate the staging database user without exposing its password in argv."""

from __future__ import annotations

import argparse
import base64
import json
import secrets
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request


def google_token() -> str:
    return subprocess.check_output(
        ["gcloud", "auth", "print-access-token"],
        text=True,
    ).strip()


def api_request(
    token: str,
    method: str,
    url: str,
    payload: dict[str, object] | None = None,
) -> dict[str, object]:
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            result: dict[str, object] = json.load(response)
            return result
    except urllib.error.HTTPError as error:
        raise RuntimeError(
            f"Google API request failed with HTTP {error.code}"
        ) from None


def wait_for_sql_operation(
    token: str,
    project: str,
    operation_name: str,
) -> None:
    operation_url = (
        "https://sqladmin.googleapis.com/sql/v1beta4/projects/"
        f"{urllib.parse.quote(project, safe='')}/operations/"
        f"{urllib.parse.quote(operation_name, safe='')}"
    )
    for _ in range(120):
        operation = api_request(token, "GET", operation_url)
        if operation.get("status") == "DONE":
            if operation.get("error"):
                raise RuntimeError("Cloud SQL user operation failed")
            return
        time.sleep(2)
    raise RuntimeError("Cloud SQL user operation timed out")


def configure(args: argparse.Namespace) -> str:
    token = google_token()
    password = secrets.token_hex(32)
    project = urllib.parse.quote(args.project, safe="")
    instance = urllib.parse.quote(args.instance, safe="")
    user = urllib.parse.quote(args.user, safe="")
    users_url = (
        "https://sqladmin.googleapis.com/sql/v1beta4/projects/"
        f"{project}/instances/{instance}/users"
    )
    users = api_request(token, "GET", users_url)
    names = {
        item.get("name") for item in users.get("items", []) if isinstance(item, dict)
    }
    payload: dict[str, object] = {
        "name": args.user,
        "password": password,
    }
    if args.user in names:
        operation = api_request(
            token,
            "PUT",
            f"{users_url}?name={user}",
            payload,
        )
    else:
        operation = api_request(token, "POST", users_url, payload)
    operation_name = operation.get("name")
    if not isinstance(operation_name, str):
        raise RuntimeError("Cloud SQL user operation returned no identifier")
    wait_for_sql_operation(token, args.project, operation_name)

    database_url = (
        f"postgresql://{args.user}:{password}@/{args.database}?"
        f"host=%2Fcloudsql%2F{args.connection_name}"
    )
    secret_url = (
        "https://secretmanager.googleapis.com/v1/projects/"
        f"{project}/secrets/{urllib.parse.quote(args.secret, safe='')}:addVersion"
    )
    version = api_request(
        token,
        "POST",
        secret_url,
        {
            "payload": {
                "data": base64.b64encode(database_url.encode("utf-8")).decode("ascii")
            }
        },
    )
    password = ""
    database_url = ""
    version_name = version.get("name")
    if not isinstance(version_name, str):
        raise RuntimeError("Secret Manager returned no version identifier")
    return version_name.rsplit("/", 1)[-1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True)
    parser.add_argument("--instance", required=True)
    parser.add_argument("--connection-name", required=True)
    parser.add_argument("--database", default="noop")
    parser.add_argument("--user", default="noop_runtime")
    parser.add_argument("--secret", default="noop-staging-database-url")
    args = parser.parse_args()

    version = configure(args)
    print(f"Configured runtime database credential as secret version {version}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
