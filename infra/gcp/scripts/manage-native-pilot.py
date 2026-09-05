#!/usr/bin/env python3
"""Operate the private synthetic native NOOP+ pilot without printing credentials.

The retained Firebase user is a fictional, claim-scoped tester. It is never an
application administrator or a Google Cloud principal. App Check debug tokens
are temporary and tracked only in a mode-0600 ignored state file for cleanup.
"""

from __future__ import annotations

import argparse
import json
import os
import stat
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any
from uuid import UUID, uuid4

SCRIPT_DIR = Path(__file__).resolve().parent
INFRA_DIR = SCRIPT_DIR.parent
REPO_ROOT = INFRA_DIR.parent.parent
PILOT_DIR = REPO_ROOT / ".noop-pilot"
DEBUG_STATE = PILOT_DIR / "debug-resources.json"
EXPECTED_OPT_IN = "private-synthetic-staging"
POLICY_VERSION = "synthetic-v1"
POLICY_SHA256 = "e9324e49b411f124635c24b2de509f4e459cb164b7bdd23519c65c778d12d7ef"
CONTROL_OPERATIONS = frozenset(
    {
        "app_check_cleanup",
        "app_check_exchange",
        "app_check_register",
        "identity_config",
        "identity_lookup",
        "phone_sign_in",
        "phone_verification_start",
        "pilot_claim_update",
    }
)


class PilotFailure(RuntimeError):
    """A bounded operator failure that contains no identity or credential."""


def command(*arguments: str) -> str:
    try:
        return subprocess.check_output(
            list(arguments),
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        raise PilotFailure("required operator command failed") from None


def tofu_output(name: str, *, raw: bool = False) -> Any:
    value = command(
        "tofu",
        f"-chdir={INFRA_DIR}",
        "output",
        "-raw" if raw else "-json",
        name,
    )
    if raw:
        return value
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        raise PilotFailure("OpenTofu output was invalid") from None


def preflight() -> tuple[str, dict[str, Any], dict[str, Any]]:
    if os.getenv("NOOP_ALLOW_PRIVATE_NATIVE_PILOT") != EXPECTED_OPT_IN:
        raise PilotFailure("explicit private synthetic pilot opt-in is required")
    project_id = str(tofu_output("project_id", raw=True))
    identity = tofu_output("managed_identity")
    managed_api = tofu_output("managed_api")
    if (
        not project_id
        or not isinstance(identity, dict)
        or not isinstance(managed_api, dict)
        or managed_api.get("public") is not False
        or not str(managed_api.get("uri") or "").startswith("https://")
    ):
        raise PilotFailure("private staging outputs are incomplete")
    if command("gcloud", "config", "get-value", "project") != project_id:
        raise PilotFailure("active Google Cloud project does not match staging")
    return project_id, identity, managed_api


def google_request(
    host: str,
    path: str,
    *,
    operation: str,
    method: str,
    body: dict[str, Any] | None = None,
    oauth_token: str | None = None,
    quota_project: str | None = None,
    api_key: str | None = None,
    app_check_token: str | None = None,
    apple_bundle_id: str | None = None,
    expected: set[int] | None = None,
) -> dict[str, Any]:
    if operation not in CONTROL_OPERATIONS:
        raise PilotFailure("Google control operation is not allowed")
    if host not in {
        "firebaseappcheck.googleapis.com",
        "identitytoolkit.googleapis.com",
    }:
        raise PilotFailure("Google control host is not allowed")
    payload = (
        None
        if body is None
        else json.dumps(
            body,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
    )
    headers = {"Accept": "application/json"}
    if payload is not None:
        headers["Content-Type"] = "application/json"
    if oauth_token:
        if not quota_project:
            raise PilotFailure("Google control quota project is required")
        headers["Authorization"] = f"Bearer {oauth_token}"
        headers["X-Goog-User-Project"] = quota_project
    if app_check_token:
        headers["X-Firebase-AppCheck"] = app_check_token
    if apple_bundle_id:
        headers["X-Ios-Bundle-Identifier"] = apple_bundle_id
    query = f"?{urllib.parse.urlencode({'key': api_key})}" if api_key else ""
    request = urllib.request.Request(
        f"https://{host}{path}{query}",
        data=payload,
        method=method,
        headers=headers,
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            status = response.status
            raw = response.read(2 * 1024 * 1024)
    except urllib.error.HTTPError as error:
        status = error.code
        raw = error.read(2 * 1024 * 1024)
    except (OSError, TimeoutError, ValueError):
        raise PilotFailure(f"Google {operation} was unavailable") from None
    if status not in (expected or set(range(200, 300))):
        raise PilotFailure(f"Google {operation} returned HTTP {status}")
    if not raw:
        return {}
    try:
        decoded = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise PilotFailure("Google control response was invalid") from None
    if not isinstance(decoded, dict):
        raise PilotFailure("Google control response had an invalid envelope")
    return decoded


def api_key(uid: str, project_id: str) -> str:
    value = command(
        "gcloud",
        "services",
        "api-keys",
        "get-key-string",
        uid,
        f"--project={project_id}",
        "--format=value(keyString)",
    )
    if len(value) < 20:
        raise PilotFailure("staging Firebase API key is unavailable")
    return value


def identity_config(
    project_id: str,
    access_token: str,
) -> dict[str, Any]:
    return google_request(
        "identitytoolkit.googleapis.com",
        f"/admin/v2/projects/{urllib.parse.quote(project_id, safe='')}/config",
        operation="identity_config",
        method="GET",
        oauth_token=access_token,
        quota_project=project_id,
    )


def fictional_tester(config: dict[str, Any]) -> tuple[str, str]:
    phone = config.get("signIn", {}).get("phoneNumber", {})
    values = phone.get("testPhoneNumbers")
    if (
        phone.get("enabled") is not True
        or not isinstance(values, dict)
        or len(values) != 1
    ):
        raise PilotFailure("expected exactly one fictional test phone")
    number, code = next(iter(values.items()))
    if (
        not isinstance(number, str)
        or not isinstance(code, str)
        or not number.startswith("+")
        or not code.isdigit()
    ):
        raise PilotFailure("fictional test phone configuration is invalid")
    return number, code


def create_debug_token(
    *,
    project_id: str,
    app_id: str,
    access_token: str,
    token: str,
    display_name: str,
) -> str:
    created = google_request(
        "firebaseappcheck.googleapis.com",
        (
            f"/v1/projects/{urllib.parse.quote(project_id, safe='')}"
            f"/apps/{urllib.parse.quote(app_id, safe=':')}/debugTokens"
        ),
        operation="app_check_register",
        method="POST",
        oauth_token=access_token,
        quota_project=project_id,
        body={"displayName": display_name, "token": token},
    )
    resource = str(created.get("name") or "")
    if not resource.startswith("projects/"):
        raise PilotFailure("App Check debug registration failed")
    return resource


def delete_debug_token(
    resource: str,
    access_token: str,
    project_id: str,
) -> None:
    if not resource.startswith("projects/") or "/debugTokens/" not in resource:
        raise PilotFailure("App Check debug resource is invalid")
    google_request(
        "firebaseappcheck.googleapis.com",
        f"/v1/{urllib.parse.quote(resource, safe='/')}",
        operation="app_check_cleanup",
        method="DELETE",
        oauth_token=access_token,
        quota_project=project_id,
        expected={200, 204, 404},
    )


def authenticate_tester(
    project_id: str,
    identity: dict[str, Any],
    access_token: str,
) -> tuple[str, str]:
    app_id = str(identity.get("apple_app_id") or "")
    bundle_id = str(identity.get("apple_bundle_id") or "")
    key_uid = str(identity.get("apple_api_key_uid") or "")
    if not app_id or not bundle_id or not key_uid:
        raise PilotFailure("Apple synthetic identity output is incomplete")
    key = api_key(key_uid, project_id)
    phone, code = fictional_tester(identity_config(project_id, access_token))
    debug_value = str(uuid4())
    resource = create_debug_token(
        project_id=project_id,
        app_id=app_id,
        access_token=access_token,
        token=debug_value,
        display_name="NOOP retained fictional pilot bootstrap",
    )
    try:
        exchange = google_request(
            "firebaseappcheck.googleapis.com",
            (
                f"/v1/projects/{urllib.parse.quote(project_id, safe='')}"
                f"/apps/{urllib.parse.quote(app_id, safe=':')}:exchangeDebugToken"
            ),
            operation="app_check_exchange",
            method="POST",
            api_key=key,
            apple_bundle_id=bundle_id,
            body={"debug_token": debug_value},
        )
        app_check = str(exchange.get("token") or "")
        if app_check.count(".") != 2:
            raise PilotFailure("App Check debug exchange failed")
        sent = google_request(
            "identitytoolkit.googleapis.com",
            "/v1/accounts:sendVerificationCode",
            operation="phone_verification_start",
            method="POST",
            api_key=key,
            app_check_token=app_check,
            apple_bundle_id=bundle_id,
            body={"phoneNumber": phone},
        )
        session = str(sent.get("sessionInfo") or "")
        if not session:
            raise PilotFailure("fictional phone verification did not start")
        signed_in = google_request(
            "identitytoolkit.googleapis.com",
            "/v1/accounts:signInWithPhoneNumber",
            operation="phone_sign_in",
            method="POST",
            api_key=key,
            app_check_token=app_check,
            apple_bundle_id=bundle_id,
            body={"sessionInfo": session, "code": code},
        )
        local_id = str(signed_in.get("localId") or "")
        id_token = str(signed_in.get("idToken") or "")
        if not local_id or id_token.count(".") != 2:
            raise PilotFailure("fictional pilot authentication failed")
        return local_id, id_token
    finally:
        delete_debug_token(resource, access_token, project_id)


def user_record(
    project_id: str,
    access_token: str,
    local_id: str,
) -> dict[str, Any]:
    response = google_request(
        "identitytoolkit.googleapis.com",
        (f"/v1/projects/{urllib.parse.quote(project_id, safe='')}/accounts:lookup"),
        operation="identity_lookup",
        method="POST",
        oauth_token=access_token,
        quota_project=project_id,
        body={"localId": [local_id]},
    )
    users = response.get("users")
    if not isinstance(users, list) or len(users) != 1 or not isinstance(users[0], dict):
        raise PilotFailure("fictional pilot identity lookup failed")
    return users[0]


def custom_attributes(user: dict[str, Any]) -> dict[str, Any]:
    raw = user.get("customAttributes")
    if raw in (None, ""):
        return {}
    if not isinstance(raw, str) or len(raw.encode("utf-8")) > 2048:
        raise PilotFailure("fictional pilot custom attributes are invalid")
    try:
        values = json.loads(raw)
    except json.JSONDecodeError:
        raise PilotFailure("fictional pilot custom attributes are invalid") from None
    if not isinstance(values, dict):
        raise PilotFailure("fictional pilot custom attributes are invalid")
    return values


def set_pilot_claim(enabled: bool) -> None:
    project_id, identity, _ = preflight()
    access_token = command("gcloud", "auth", "print-access-token")
    local_id, _ = authenticate_tester(project_id, identity, access_token)
    values = custom_attributes(user_record(project_id, access_token, local_id))
    if enabled:
        values["noop_managed_pilot"] = True
    else:
        values.pop("noop_managed_pilot", None)
    encoded = json.dumps(values, sort_keys=True, separators=(",", ":"))
    if len(encoded.encode("utf-8")) > 1000:
        raise PilotFailure("fictional pilot custom attributes exceed provider limits")
    google_request(
        "identitytoolkit.googleapis.com",
        (f"/v1/projects/{urllib.parse.quote(project_id, safe='')}/accounts:update"),
        operation="pilot_claim_update",
        method="POST",
        oauth_token=access_token,
        quota_project=project_id,
        body={"localId": local_id, "customAttributes": encoded},
    )
    observed = custom_attributes(user_record(project_id, access_token, local_id))
    if bool(observed.get("noop_managed_pilot")) is not enabled:
        raise PilotFailure("fictional pilot claim verification failed")
    print(
        "PASS fictional pilot claim provisioned"
        if enabled
        else "PASS pilot claim revoked"
    )


def write_private(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(content)
        os.replace(temporary, path)
        path.chmod(0o600)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def generate_configs(port: int) -> None:
    project_id, identity, managed_api = preflight()
    del managed_api
    access_token = command("gcloud", "auth", "print-access-token")
    test_phone, _ = fictional_tester(identity_config(project_id, access_token))
    apple_key = api_key(str(identity.get("apple_api_key_uid") or ""), project_id)
    android_key = api_key(str(identity.get("android_api_key_uid") or ""), project_id)
    apple_app_id = str(identity.get("apple_app_id") or "")
    android_app_id = str(identity.get("android_app_id") or "")
    project_number = str(identity.get("project_number") or "")
    if not apple_app_id or not android_app_id or not project_number:
        raise PilotFailure("native identity output is incomplete")
    apple = "\n".join(
        [
            "// Generated for the private synthetic simulator pilot. Do not commit.",
            f"NOOP_MANAGED_PROJECT_ID = {project_id}",
            f"NOOP_MANAGED_API_KEY = {apple_key}",
            f"NOOP_MANAGED_GOOGLE_APP_ID = {apple_app_id}",
            f"NOOP_MANAGED_GCM_SENDER_ID = {project_number}",
            "NOOP_MANAGED_ENCODED_APP_ID = app-" + apple_app_id.replace(":", "-"),
            f"NOOP_MANAGED_API_URL = http:/$()/127.0.0.1:{port}",
            f"NOOP_MANAGED_POLICY_VERSION = {POLICY_VERSION}",
            f"NOOP_MANAGED_POLICY_SHA256 = {POLICY_SHA256}",
            "NOOP_MANAGED_ALLOW_LOCAL_HTTP = YES",
            "NOOP_MANAGED_DISABLE_PHONE_APP_VERIFICATION = YES",
            f"NOOP_MANAGED_TEST_PHONE = {test_phone}",
            "",
        ]
    )
    android = "\n".join(
        [
            "# Generated for the private synthetic emulator pilot. Do not commit.",
            f"noopManagedApiUrl=http://10.0.2.2:{port}",
            f"noopManagedProjectId={project_id}",
            f"noopManagedApiKey={android_key}",
            f"noopManagedGoogleAppId={android_app_id}",
            f"noopManagedGcmSenderId={project_number}",
            f"noopManagedPolicyVersion={POLICY_VERSION}",
            f"noopManagedPolicySha256={POLICY_SHA256}",
            "noopManagedAllowLocalHttp=true",
            "noopManagedDisablePhoneAppVerification=true",
            f"noopManagedTestPhone={test_phone}",
            "",
        ]
    )
    write_private(REPO_ROOT / "Config/ManagedCloudSecrets.xcconfig", apple)
    write_private(REPO_ROOT / "android/managed-cloud.properties", android)
    print("PASS ignored native pilot configuration generated")


def debug_state() -> list[dict[str, str]]:
    if not DEBUG_STATE.exists():
        return []
    if stat.S_IMODE(DEBUG_STATE.stat().st_mode) != 0o600:
        raise PilotFailure("debug-token state must have mode 0600")
    try:
        decoded = json.loads(DEBUG_STATE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        raise PilotFailure("debug-token state is invalid") from None
    if not isinstance(decoded, list):
        raise PilotFailure("debug-token state is invalid")
    rows: list[dict[str, str]] = []
    resources: set[str] = set()
    for item in decoded:
        if (
            not isinstance(item, dict)
            or set(item) != {"platform", "resource"}
            or item.get("platform") not in {"apple", "android"}
            or not isinstance(item.get("resource"), str)
            or not item["resource"].startswith("projects/")
            or "/debugTokens/" not in item["resource"]
            or item["resource"] in resources
        ):
            raise PilotFailure("debug-token state is invalid")
        resources.add(item["resource"])
        rows.append(
            {
                "platform": str(item["platform"]),
                "resource": str(item["resource"]),
            }
        )
    return rows


def register_debug(platform: str, token_file: Path) -> None:
    project_id, identity, _ = preflight()
    if not token_file.is_file() or stat.S_IMODE(token_file.stat().st_mode) != 0o600:
        raise PilotFailure("debug token file must exist with mode 0600")
    token = token_file.read_text(encoding="utf-8").strip()
    try:
        UUID(token)
    except ValueError:
        raise PilotFailure("debug token file is invalid") from None
    app_key = "apple_app_id" if platform == "apple" else "android_app_id"
    app_id = str(identity.get(app_key) or "")
    if not app_id:
        raise PilotFailure("native App Check output is incomplete")
    access_token = command("gcloud", "auth", "print-access-token")
    rows = debug_state()
    if any(row["platform"] == platform for row in rows):
        raise PilotFailure("temporary platform assertion is already registered")
    resource = create_debug_token(
        project_id=project_id,
        app_id=app_id,
        access_token=access_token,
        token=token,
        display_name=f"NOOP private native {platform} pilot",
    )
    try:
        rows.append({"platform": platform, "resource": resource})
        write_private(
            DEBUG_STATE,
            json.dumps(rows, sort_keys=True, separators=(",", ":")),
        )
    except (OSError, PilotFailure):
        delete_debug_token(resource, access_token, project_id)
        raise PilotFailure("temporary assertion state could not be persisted") from None
    try:
        token_file.unlink()
    except OSError:
        raise PilotFailure("registered token file could not be removed") from None
    print(f"PASS temporary {platform} App Check assertion registered")


def cleanup_debug() -> None:
    project_id, _, _ = preflight()
    rows = debug_state()
    if not rows:
        print("PASS no temporary App Check assertions remain")
        return
    access_token = command("gcloud", "auth", "print-access-token")
    remaining: list[dict[str, str]] = []
    for row in rows:
        try:
            delete_debug_token(row["resource"], access_token, project_id)
        except PilotFailure:
            remaining.append(row)
    if remaining:
        write_private(
            DEBUG_STATE,
            json.dumps(remaining, sort_keys=True, separators=(",", ":")),
        )
        raise PilotFailure("temporary App Check assertion cleanup is incomplete")
    try:
        DEBUG_STATE.unlink(missing_ok=True)
    except OSError:
        raise PilotFailure("temporary assertion state could not be removed") from None
    print("PASS temporary App Check assertions removed")


def verify_pilot() -> None:
    project_id, identity, managed_api = preflight()
    access_token = command("gcloud", "auth", "print-access-token")
    local_id, _ = authenticate_tester(project_id, identity, access_token)
    attributes = custom_attributes(user_record(project_id, access_token, local_id))
    if attributes.get("noop_managed_pilot") is not True:
        raise PilotFailure("fictional pilot claim is not active")
    service = command(
        "gcloud",
        "run",
        "services",
        "describe",
        str(managed_api.get("name") or ""),
        f"--project={project_id}",
        f"--region={tofu_output('region', raw=True)}",
        "--format=json",
    )
    try:
        payload = json.loads(service)
        containers = payload["spec"]["template"]["spec"]["containers"]
        environment = containers[0].get("env", [])
    except (KeyError, IndexError, TypeError, json.JSONDecodeError):
        raise PilotFailure("managed runtime description is invalid") from None
    mode = next(
        (
            item.get("value")
            for item in environment
            if item.get("name") == "NOOP_MANAGED_ENTITLEMENT_MODE"
        ),
        None,
    )
    if mode != "pilot":
        raise PilotFailure("managed runtime is not in scoped pilot mode")
    private_check = subprocess.run(
        [str(SCRIPT_DIR / "verify-private-runtime.sh")],
        cwd=REPO_ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if private_check.returncode != 0:
        raise PilotFailure("private runtime verification failed")
    print("PASS scoped private native pilot verified")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    subcommands = result.add_subparsers(dest="command", required=True)
    subcommands.add_parser("provision")
    subcommands.add_parser("revoke")
    generated = subcommands.add_parser("generate-config")
    generated.add_argument("--port", type=int, default=8765)
    registered = subcommands.add_parser("register-debug-token")
    registered.add_argument("--platform", choices=("apple", "android"), required=True)
    registered.add_argument("--token-file", type=Path, required=True)
    subcommands.add_parser("cleanup-debug-tokens")
    subcommands.add_parser("verify")
    return result


def main() -> int:
    arguments = parser().parse_args()
    try:
        if arguments.command == "provision":
            set_pilot_claim(True)
        elif arguments.command == "revoke":
            set_pilot_claim(False)
        elif arguments.command == "generate-config":
            if not 1024 <= arguments.port <= 65535:
                raise PilotFailure("relay port must be 1024 through 65535")
            generate_configs(arguments.port)
        elif arguments.command == "register-debug-token":
            register_debug(arguments.platform, arguments.token_file)
        elif arguments.command == "cleanup-debug-tokens":
            cleanup_debug()
        elif arguments.command == "verify":
            verify_pilot()
    except PilotFailure as error:
        print(f"FAIL {error}", file=os.sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
