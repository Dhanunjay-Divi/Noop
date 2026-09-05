#!/usr/bin/env python3
"""Exercise the private NOOP+ runtime with disposable synthetic identities.

The runner deliberately uses Firebase fictional phone numbers, generated
measurements, and an ephemeral App Check debug assertion. It never prints
credentials, identifiers, URLs, request bodies, response bodies, or values.
Temporary Identity Platform and App Check configuration is restored in a
finally block, and both synthetic accounts are queued for managed erasure.
"""

from __future__ import annotations

import gzip
import hashlib
import json
import os
import secrets
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any
from uuid import uuid4

SCRIPT_DIR = Path(__file__).resolve().parent
INFRA_DIR = SCRIPT_DIR.parent
EXPECTED_OPT_IN = "private-synthetic-staging"
POLICY_VERSION = "synthetic-v1"
POLICY_SHA256 = "e9324e49b411f124635c24b2de509f4e459cb164b7bdd23519c65c778d12d7ef"


class SmokeFailure(RuntimeError):
    """A bounded staging-smoke failure with no dynamic payload."""


@dataclass
class SyntheticAccount:
    phone: str
    code: str
    platform: str
    installation_id: str
    installation_token: str
    id_token: str = ""
    local_id: str = ""
    profile_id: str = ""
    account_erasure_requested: bool = False


class ManagedStagingSmoke:
    def __init__(self) -> None:
        self.project_id = self._tofu_output("project_id")
        self.region = self._tofu_output("region")
        self.managed_api = self._tofu_output_json("managed_api")
        self.identity = self._tofu_output_json("managed_identity")
        self.lifecycle_job = self._tofu_output("managed_lifecycle_job")
        self.api_url = str(self.managed_api.get("uri") or "").rstrip("/")
        self.bundle_id = str(self.identity.get("apple_bundle_id") or "")
        self.apple_app_id = str(self.identity.get("apple_app_id") or "")
        self.access_token = ""
        self.iam_token = ""
        self.api_key = ""
        self.app_check_token = ""
        self.debug_resource = ""
        self.original_test_numbers: dict[str, str] = {}
        self.identity_config_changed = False
        self.accounts: list[SyntheticAccount] = []

    def run(self) -> None:
        started = time.monotonic()
        self._preflight()
        try:
            self.access_token = self._command("gcloud", "auth", "print-access-token")
            self.iam_token = self._command(
                "gcloud",
                "auth",
                "print-identity-token",
            )
            self.api_key = self._apple_api_key()
            self._prepare_identities()
            self._prepare_app_check()
            self._authenticate_accounts()
            self._enroll_accounts()
            self._exercise_storage()
            self._erase_raw_storage()
            self._exercise_social()
            self._delete_social_profiles()
            self._request_account_erasure()
            self._delete_provider_identities()
        finally:
            self._best_effort_cleanup()
        elapsed = max(0, round(time.monotonic() - started))
        print(f"PASS private managed runtime smoke ({elapsed}s)")

    def _preflight(self) -> None:
        if os.getenv("NOOP_ALLOW_SYNTHETIC_STAGING_SMOKE") != EXPECTED_OPT_IN:
            raise SmokeFailure("explicit synthetic staging opt-in is required")
        if self.region not in {"asia-south1", "asia-south2"}:
            raise SmokeFailure("unexpected staging region")
        if (
            not self.project_id
            or not self.api_url.startswith("https://")
            or "staging" not in self.api_url
            or self.managed_api.get("public") is not False
            or not self.apple_app_id
            or not self.bundle_id
            or "staging" not in self.lifecycle_job
        ):
            raise SmokeFailure("private staging outputs are incomplete")
        active_project = self._command("gcloud", "config", "get-value", "project")
        if active_project != self.project_id:
            raise SmokeFailure("active gcloud project does not match OpenTofu")
        tfvars = INFRA_DIR / "staging.auto.tfvars"
        if not tfvars.exists() or stat.S_IMODE(tfvars.stat().st_mode) != 0o600:
            raise SmokeFailure("staging variables must exist with mode 0600")
        private_check = subprocess.run(
            [str(SCRIPT_DIR / "verify-private-runtime.sh")],
            cwd=INFRA_DIR.parent.parent,
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if private_check.returncode != 0:
            raise SmokeFailure("private runtime verification failed")
        print("PASS preflight and private invocation boundary")

    def _prepare_identities(self) -> None:
        config = self._identity_admin_request("GET")
        phone = config.get("signIn", {}).get("phoneNumber", {})
        original = phone.get("testPhoneNumbers")
        if (
            phone.get("enabled") is not True
            or not isinstance(original, dict)
            or len(original) != 1
            or not all(
                isinstance(key, str) and isinstance(value, str)
                for key, value in original.items()
            )
        ):
            raise SmokeFailure("expected exactly one configured fictional phone")
        self.original_test_numbers = dict(original)
        first_phone, first_code = next(iter(original.items()))
        second_phone = self._new_synthetic_phone(set(original))
        second_code = f"{secrets.randbelow(1_000_000):06d}"
        updated = {**original, second_phone: second_code}
        self._patch_test_numbers(updated)
        self.identity_config_changed = True
        suffix = secrets.token_hex(4)
        self.accounts = [
            SyntheticAccount(
                phone=first_phone,
                code=first_code,
                platform="ios",
                installation_id=f"ios-staging-smoke-{suffix}",
                installation_token=self._installation_token(),
            ),
            SyntheticAccount(
                phone=second_phone,
                code=second_code,
                platform="ios",
                installation_id=f"ios-staging-peer-{suffix}",
                installation_token=self._installation_token(),
            ),
        ]
        print("PASS disposable fictional identity configuration")

    def _prepare_app_check(self) -> None:
        debug_token = str(uuid4())
        path = (
            f"/v1/projects/{urllib.parse.quote(self.project_id, safe='')}"
            f"/apps/{urllib.parse.quote(self.apple_app_id, safe=':')}/debugTokens"
        )
        created = self._google_json_request(
            "firebaseappcheck.googleapis.com",
            path,
            method="POST",
            oauth=True,
            body={
                "displayName": "NOOP private synthetic runtime smoke",
                "token": debug_token,
            },
        )
        self.debug_resource = str(created.get("name") or "")
        if not self.debug_resource.startswith("projects/"):
            raise SmokeFailure("App Check debug registration failed")
        exchange_path = (
            f"/v1/projects/{urllib.parse.quote(self.project_id, safe='')}"
            f"/apps/{urllib.parse.quote(self.apple_app_id, safe=':')}"
            f":exchangeDebugToken?{urllib.parse.urlencode({'key': self.api_key})}"
        )
        exchanged = self._google_json_request(
            "firebaseappcheck.googleapis.com",
            exchange_path,
            method="POST",
            body={"debug_token": debug_token},
            ios_headers=True,
        )
        self.app_check_token = str(exchanged.get("token") or "")
        if self.app_check_token.count(".") != 2:
            raise SmokeFailure("App Check debug exchange failed")
        print("PASS App Check assertion")

    def _authenticate_accounts(self) -> None:
        for account in self.accounts:
            self._authenticate(account)
        if len({account.local_id for account in self.accounts}) != 2:
            raise SmokeFailure("fictional phone identities are not isolated")
        print("PASS two fictional phone OTP identities")

    def _authenticate(self, account: SyntheticAccount) -> None:
        query = urllib.parse.urlencode({"key": self.api_key})
        sent = self._google_json_request(
            "identitytoolkit.googleapis.com",
            f"/v1/accounts:sendVerificationCode?{query}",
            method="POST",
            body={"phoneNumber": account.phone},
            ios_headers=True,
            app_check=True,
        )
        session = str(sent.get("sessionInfo") or "")
        if not session:
            raise SmokeFailure("fictional phone verification did not start")
        signed_in = self._google_json_request(
            "identitytoolkit.googleapis.com",
            f"/v1/accounts:signInWithPhoneNumber?{query}",
            method="POST",
            body={"sessionInfo": session, "code": account.code},
            ios_headers=True,
            app_check=True,
        )
        account.id_token = str(signed_in.get("idToken") or "")
        account.local_id = str(signed_in.get("localId") or "")
        if account.id_token.count(".") != 2 or not account.local_id:
            raise SmokeFailure("fictional phone sign-in failed")

    def _enroll_accounts(self) -> None:
        for account in self.accounts:
            response = self._managed_request(
                account,
                "POST",
                "/v1/managed/enroll",
                body={
                    "installation_id": account.installation_id,
                    "platform": account.platform,
                    "installation_token": account.installation_token,
                    "enrollment_request_id": str(uuid4()),
                    "policy_version": POLICY_VERSION,
                    "policy_sha256": POLICY_SHA256,
                    "data_classes": [
                        "essential_timeseries",
                        "derived_summaries",
                        "user_documents",
                    ],
                },
                include_installation=False,
                expected={201},
            )
            boundary = response.get("product_boundary", {})
            if (
                boundary.get("account_optional") is not True
                or boundary.get("local_metrics_available") is not True
                or boundary.get("storage_only_entitlement") is not True
            ):
                raise SmokeFailure("managed product boundary is incorrect")
            overview = self._managed_request(account, "GET", "/v1/managed/me")
            entitlements = overview.get("entitlements", {})
            if (
                entitlements.get("managed_storage") is not True
                or entitlements.get("feature_restrictions") != []
            ):
                raise SmokeFailure("managed storage entitlement is incorrect")
        print("PASS enrollment and storage-only product boundary")

    def _exercise_storage(self) -> None:
        owner, outsider = self.accounts
        source_id = str(uuid4())
        self._managed_request(
            owner,
            "POST",
            "/v1/managed/sources",
            body={
                "source_id": source_id,
                "source_kind": "synthetic_staging",
                "platform": "ios",
                "logical_source_hash": hashlib.sha256(
                    b"noop-private-synthetic-staging"
                ).hexdigest(),
            },
            expected={201},
        )
        now = datetime.now(UTC).replace(microsecond=0)
        event_start = now - timedelta(minutes=2)
        event_end = now - timedelta(minutes=1)
        chunk_id = str(uuid4())
        payload = {
            "chunk_id": chunk_id,
            "source_id": source_id,
            "data_class": "essential_timeseries",
            "schema_version": 1,
            "event_start_ms": round(event_start.timestamp() * 1000),
            "event_end_ms": round(event_end.timestamp() * 1000),
            "streams": [
                {
                    "stream_key": "heart_rate",
                    "schema_revision": 1,
                    "columns": ["event_at_ms", "bpm", "quality", "provenance"],
                    "rows": [
                        [
                            round(event_start.timestamp() * 1000),
                            68.0,
                            0.98,
                            "synthetic",
                        ],
                        [
                            round(event_end.timestamp() * 1000),
                            72.0,
                            0.97,
                            "synthetic",
                        ],
                    ],
                }
            ],
        }
        raw = json.dumps(
            payload,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
        compressed = gzip.compress(raw, mtime=0)
        digest = hashlib.sha256(compressed).hexdigest()
        reservation = {
            "chunk_id": chunk_id,
            "request_id": str(uuid4()),
            "source_id": source_id,
            "data_class": "essential_timeseries",
            "schema_version": 1,
            "content_mode": "server_readable",
            "client_key_id": None,
            "event_start": event_start.isoformat(),
            "event_end": event_end.isoformat(),
            "compression": "gzip",
            "content_type": "application/vnd.noop.chunk+json",
            "expected_sha256": digest,
            "expected_compressed_bytes": len(compressed),
            "expected_uncompressed_bytes": len(raw),
            "streams": [
                {
                    "stream_key": "heart_rate",
                    "sample_count": 2,
                    "first_event_at": event_start.isoformat(),
                    "last_event_at": event_end.isoformat(),
                    "encoded_bytes": min(128, len(raw)),
                    "schema_revision": 1,
                }
            ],
        }
        reserved = self._managed_request(
            owner,
            "POST",
            "/v1/managed/chunks:reserve",
            body=reservation,
            expected={201},
        )
        upload = reserved.get("upload")
        if not isinstance(upload, dict):
            raise SmokeFailure("chunk upload capability was not issued")
        self._signed_bytes_request(
            str(upload.get("url") or ""),
            method="PUT",
            body=compressed,
            headers=upload.get("headers") or {},
        )
        available = self._wait_for_chunk(owner, chunk_id)
        if str(available.get("chunk_id")) != chunk_id:
            raise SmokeFailure("processed chunk was not published")
        duplicate = self._managed_request(
            owner,
            "POST",
            "/v1/managed/chunks:reserve",
            body=reservation,
            expected={201},
        )
        if duplicate.get("upload") is not None:
            raise SmokeFailure("duplicate chunk issued another upload")
        self._managed_request(
            outsider,
            "POST",
            f"/v1/managed/chunks/{chunk_id}/download",
            body={"request_id": str(uuid4())},
            expected={404},
        )
        restore = self._managed_request(
            owner,
            "POST",
            "/v1/managed/restores",
            body={
                "request_id": str(uuid4()),
                "data_classes": ["essential_timeseries"],
                "document_kinds": [],
                "include_documents": False,
            },
            expected={201},
        ).get("restore", {})
        restore_id = str(restore.get("restore_job_id") or "")
        if not restore_id:
            raise SmokeFailure("restore snapshot was not created")
        download = self._managed_request(
            owner,
            "POST",
            f"/v1/managed/chunks/{chunk_id}/download",
            body={"request_id": str(uuid4())},
        )
        downloaded = self._signed_bytes_request(
            str(download.get("url") or ""),
            method="GET",
            headers=download.get("headers") or {},
        )
        if downloaded != compressed or hashlib.sha256(downloaded).hexdigest() != digest:
            raise SmokeFailure("restored chunk failed integrity verification")
        completed = self._managed_request(
            owner,
            "POST",
            f"/v1/managed/restores/{restore_id}/complete",
            body={
                "delivered_objects": 1,
                "delivered_bytes": len(downloaded),
            },
        ).get("restore", {})
        if completed.get("status") != "completed":
            raise SmokeFailure("restore did not complete")
        print("PASS upload, processing, idempotency, isolation, and restore")

    def _erase_raw_storage(self) -> None:
        owner = self.accounts[0]
        self._authenticate(owner)
        job = self._managed_request(
            owner,
            "POST",
            "/v1/managed/erasure",
            body={
                "request_id": str(uuid4()),
                "scope": "raw_chunks",
                "confirmation_sha256": hashlib.sha256(
                    b"delete-noop-plus-raw-chunks-v1"
                ).hexdigest(),
            },
            expected={202},
        ).get("erasure", {})
        erasure_job_id = str(job.get("erasure_job_id") or "")
        if not erasure_job_id:
            raise SmokeFailure("raw storage erasure was not created")
        for _ in range(2):
            self._command(
                "gcloud",
                "run",
                "jobs",
                "execute",
                self.lifecycle_job,
                f"--region={self.region}",
                "--wait",
                "--format=value(metadata.name)",
            )
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                result = self._managed_request(
                    owner,
                    "GET",
                    f"/v1/managed/erasure/{erasure_job_id}",
                ).get("erasure", {})
                if result.get("status") == "completed":
                    remaining = self._managed_request(
                        owner,
                        "GET",
                        "/v1/managed/chunks?limit=20",
                    ).get("chunks", [])
                    if remaining:
                        raise SmokeFailure("erased chunks remain visible")
                    print("PASS object erasure and lifecycle execution")
                    return
                time.sleep(2)
        raise SmokeFailure("raw storage erasure did not complete")

    def _exercise_social(self) -> None:
        first, second = self.accounts
        for account, label in ((first, "Synthetic One"), (second, "Synthetic Two")):
            profile = self._managed_request(
                account,
                "POST",
                "/v1/managed/social/profile",
                body={"request_id": str(uuid4()), "display_name": label},
                expected={201},
            ).get("profile", {})
            account.profile_id = str(profile.get("profile_id") or "")
            if not account.profile_id or not str(
                profile.get("noop_id") or ""
            ).startswith("NOOP-"):
                raise SmokeFailure("managed social profile was not created")
        first_profile = self._managed_request(
            first,
            "GET",
            "/v1/managed/social/profile",
        ).get("profile", {})
        first_noop_id = str(first_profile.get("noop_id") or "")
        lookup = self._managed_request(
            second,
            "GET",
            "/v1/managed/social/lookup?"
            + urllib.parse.urlencode({"noop_id": first_noop_id}),
        ).get("profile", {})
        if str(lookup.get("profile_id")) != first.profile_id:
            raise SmokeFailure("exact NOOP ID lookup failed")
        capability = "noopinvite_" + secrets.token_urlsafe(32)
        invite_request = str(uuid4())
        self._managed_request(
            first,
            "POST",
            "/v1/managed/social/invites",
            body={
                "request_id": invite_request,
                "capability": capability,
                "expires_in_hours": 1,
            },
            expected={201},
        ).get("invite", {})
        replay = self._managed_request(
            first,
            "POST",
            "/v1/managed/social/invites",
            body={
                "request_id": invite_request,
                "capability": capability,
                "expires_in_hours": 1,
            },
            expected={201},
        ).get("invite", {})
        if replay.get("duplicate") is not True:
            raise SmokeFailure("social invite is not idempotent")
        request = self._managed_request(
            second,
            "POST",
            "/v1/managed/social/invites:redeem",
            body={"request_id": str(uuid4()), "capability": capability},
        ).get("request", {})
        request_id = str(request.get("request_id") or "")
        accepted = self._managed_request(
            first,
            "POST",
            f"/v1/managed/social/requests/{request_id}",
            body={"decision": "accept"},
        ).get("request", {})
        if accepted.get("status") != "accepted":
            raise SmokeFailure("managed friendship was not accepted")
        self._managed_request(
            first,
            "PATCH",
            f"/v1/managed/social/friends/{second.profile_id}/privacy",
            body={
                "charge": True,
                "effort": True,
                "rest": True,
                "sleep_duration": True,
                "hrv": True,
                "rhr": True,
            },
        )
        self._managed_request(
            second,
            "PATCH",
            "/v1/managed/social/profile",
            body={
                "poke_opt_in": True,
                "quiet_start_minute": 0,
                "quiet_end_minute": 0,
                "time_zone": "UTC",
            },
        )
        self._managed_request(
            second,
            "PATCH",
            f"/v1/managed/social/friends/{first.profile_id}/privacy",
            body={"poke_allowed": True},
        )
        today = datetime.now(UTC).date()
        for offset in range(7):
            day = today - timedelta(days=offset)
            self._managed_request(
                first,
                "PUT",
                f"/v1/managed/social/summaries/{day.isoformat()}",
                body={
                    "request_id": str(uuid4()),
                    "summary": {
                        "charge": 70.0 + offset,
                        "effort": 42.0 + offset,
                        "rest": 75.0 - offset,
                        "sleep_duration": 440.0 + offset,
                        "hrv": 58.0 + offset,
                        "rhr": 61.0 - (offset / 2.0),
                    },
                },
            )
        friends = self._managed_request(
            second,
            "GET",
            "/v1/managed/social/friends",
        ).get("friends", [])
        if len(friends) != 1:
            raise SmokeFailure("accepted friend is missing")
        badges = {str(row.get("code")) for row in friends[0].get("badges", [])}
        latest = friends[0].get("latest", {}).get("summary", {})
        if not {"connected", "steady_week"}.issubset(badges) or set(latest) != {
            "charge",
            "effort",
            "rest",
            "sleep_duration",
            "hrv",
            "rhr",
        }:
            raise SmokeFailure("badges or directional projection are incomplete")
        feed = self._managed_request(
            second,
            "GET",
            "/v1/managed/social/feed?"
            + urllib.parse.urlencode(
                {
                    "start": (today - timedelta(days=6)).isoformat(),
                    "end": today.isoformat(),
                }
            ),
        )
        if len(feed.get("days", [])) != 7:
            raise SmokeFailure("social feed did not return the consented week")
        poke_request = str(uuid4())
        poke_body = {
            "request_id": poke_request,
            "recipient_profile_id": second.profile_id,
        }
        poke = self._managed_request(
            first,
            "POST",
            "/v1/managed/social/pokes",
            body=poke_body,
            expected={202},
        ).get("poke", {})
        replayed = self._managed_request(
            first,
            "POST",
            "/v1/managed/social/pokes",
            body=poke_body,
            expected={202},
        ).get("poke", {})
        if replayed.get("duplicate") is not True or poke.get("status") != "queued":
            raise SmokeFailure("poke idempotency failed")
        self._managed_request(
            first,
            "POST",
            "/v1/managed/social/pokes",
            body={
                "request_id": str(uuid4()),
                "recipient_profile_id": second.profile_id,
            },
            expected={409},
        )
        claims = self._managed_request(
            second,
            "POST",
            "/v1/managed/social/pokes:claim?limit=3",
        ).get("pokes", [])
        if len(claims) != 1:
            raise SmokeFailure("poke was not claimable")
        acknowledged = self._managed_request(
            second,
            "POST",
            f"/v1/managed/social/pokes/{claims[0]['poke_id']}:ack",
            body={
                "claim_id": claims[0]["claim_id"],
                "notification_outcome": "not_authorized",
                "haptic_outcome": "band_unavailable",
            },
        ).get("poke", {})
        if acknowledged.get("status") != "acknowledged":
            raise SmokeFailure("poke acknowledgement failed")
        self._managed_request(
            second,
            "POST",
            f"/v1/managed/social/blocks/{first.profile_id}",
            expected={204},
        )
        self._managed_request(
            first,
            "GET",
            "/v1/managed/social/lookup?"
            + urllib.parse.urlencode(
                {
                    "noop_id": str(
                        self._managed_request(
                            second,
                            "GET",
                            "/v1/managed/social/profile",
                        )
                        .get("profile", {})
                        .get("noop_id", "")
                    )
                }
            ),
            expected={404},
        )
        self._managed_request(
            second,
            "DELETE",
            f"/v1/managed/social/blocks/{first.profile_id}",
            expected={204},
        )
        print("PASS exact IDs, invites, consent, badges, feed, pokes, and blocks")

    def _delete_social_profiles(self) -> None:
        for account in self.accounts:
            self._managed_request(
                account,
                "DELETE",
                "/v1/managed/social/profile",
                expected={204},
            )
            account.profile_id = ""
        print("PASS managed social projection cleanup")

    def _request_account_erasure(self) -> None:
        for account in self.accounts:
            self._authenticate(account)
            response = self._managed_request(
                account,
                "POST",
                "/v1/managed/erasure",
                body={
                    "request_id": str(uuid4()),
                    "scope": "account",
                    "confirmation_sha256": hashlib.sha256(
                        b"delete-noop-plus-managed-account-v1"
                    ).hexdigest(),
                },
                expected={202},
            ).get("erasure", {})
            if response.get("status") not in {"cooling_off", "pending"}:
                raise SmokeFailure("account erasure was not scheduled")
            account.account_erasure_requested = True
        print("PASS managed account erasure scheduling")

    def _delete_provider_identities(self) -> None:
        for account in self.accounts:
            self._identity_admin_request(
                "POST",
                suffix="/accounts:delete",
                body={
                    "localId": account.local_id,
                    "targetProjectId": self.project_id,
                },
                expected={200, 404},
                api_version="v1",
            )
            account.local_id = ""
            account.id_token = ""
        print("PASS synthetic provider identity cleanup")

    def _wait_for_chunk(
        self, account: SyntheticAccount, chunk_id: str
    ) -> dict[str, Any]:
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            response = self._managed_request(
                account,
                "GET",
                "/v1/managed/chunks?limit=20",
            )
            for chunk in response.get("chunks", []):
                if str(chunk.get("chunk_id")) == chunk_id:
                    return chunk
            time.sleep(2)
        raise SmokeFailure("processor did not publish the synthetic chunk")

    def _managed_request(
        self,
        account: SyntheticAccount,
        method: str,
        path: str,
        *,
        body: dict[str, Any] | None = None,
        include_installation: bool = True,
        expected: set[int] | None = None,
    ) -> dict[str, Any]:
        if not path.startswith("/") or "://" in path:
            raise SmokeFailure("managed request path is invalid")
        headers = {
            "Authorization": f"Bearer {account.id_token}",
            "X-Firebase-AppCheck": self.app_check_token,
            "X-Serverless-Authorization": f"Bearer {self.iam_token}",
            "Accept": "application/json",
        }
        if include_installation:
            headers.update(
                {
                    "X-Noop-Installation-ID": account.installation_id,
                    "X-Noop-Installation-Token": account.installation_token,
                }
            )
        status_code, payload = self._json_request(
            self.api_url + path,
            method=method,
            headers=headers,
            body=body,
        )
        allowed = expected or {200}
        if status_code not in allowed:
            raise SmokeFailure(f"managed request returned HTTP {status_code}")
        return payload

    def _signed_bytes_request(
        self,
        url: str,
        *,
        method: str,
        headers: dict[str, Any],
        body: bytes | None = None,
    ) -> bytes:
        if not url.startswith("https://storage.googleapis.com/"):
            raise SmokeFailure("signed object capability has an unexpected origin")
        request = urllib.request.Request(
            url,
            data=body,
            method=method,
            headers={str(key): str(value) for key, value in headers.items()},
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                if not 200 <= response.status < 300:
                    raise SmokeFailure("signed object request failed")
                return response.read(20 * 1024 * 1024)
        except urllib.error.HTTPError as error:
            error.read(16_384)
            raise SmokeFailure(
                f"signed object request returned HTTP {error.code}"
            ) from None
        except (OSError, TimeoutError, ValueError):
            raise SmokeFailure("signed object request was unavailable") from None

    def _identity_admin_request(
        self,
        method: str,
        *,
        suffix: str = "/config",
        body: dict[str, Any] | None = None,
        expected: set[int] | None = None,
        api_version: str = "admin/v2",
    ) -> dict[str, Any]:
        path = (
            f"/{api_version}/projects/{urllib.parse.quote(self.project_id, safe='')}"
            f"{suffix}"
        )
        status_code, payload = self._google_json_request_with_status(
            "identitytoolkit.googleapis.com",
            path,
            method=method,
            oauth=True,
            body=body,
        )
        if status_code not in (expected or {200}):
            raise SmokeFailure(
                f"Identity Platform admin request returned HTTP {status_code}"
            )
        return payload

    def _patch_test_numbers(self, values: dict[str, str]) -> None:
        query = urllib.parse.urlencode(
            {"updateMask": "signIn.phoneNumber.testPhoneNumbers"}
        )
        self._identity_admin_request(
            "PATCH",
            suffix=f"/config?{query}",
            body={"signIn": {"phoneNumber": {"testPhoneNumbers": values}}},
        )

    def _google_json_request(
        self,
        host: str,
        path: str,
        *,
        method: str,
        body: dict[str, Any] | None = None,
        oauth: bool = False,
        ios_headers: bool = False,
        app_check: bool = False,
    ) -> dict[str, Any]:
        status_code, payload = self._google_json_request_with_status(
            host,
            path,
            method=method,
            body=body,
            oauth=oauth,
            ios_headers=ios_headers,
            app_check=app_check,
        )
        if not 200 <= status_code < 300:
            raise SmokeFailure(f"Google control request returned HTTP {status_code}")
        return payload

    def _google_json_request_with_status(
        self,
        host: str,
        path: str,
        *,
        method: str,
        body: dict[str, Any] | None = None,
        oauth: bool = False,
        ios_headers: bool = False,
        app_check: bool = False,
    ) -> tuple[int, dict[str, Any]]:
        if host not in {
            "firebaseappcheck.googleapis.com",
            "identitytoolkit.googleapis.com",
        }:
            raise SmokeFailure("Google control host is not allowed")
        headers: dict[str, str] = {"Accept": "application/json"}
        if oauth:
            headers["Authorization"] = f"Bearer {self.access_token}"
            headers["X-Goog-User-Project"] = self.project_id
        if ios_headers:
            headers["X-Ios-Bundle-Identifier"] = self.bundle_id
        if app_check:
            headers["X-Firebase-AppCheck"] = self.app_check_token
        return self._json_request(
            f"https://{host}{path}",
            method=method,
            headers=headers,
            body=body,
        )

    @staticmethod
    def _json_request(
        url: str,
        *,
        method: str,
        headers: dict[str, str],
        body: dict[str, Any] | None,
    ) -> tuple[int, dict[str, Any]]:
        payload = (
            json.dumps(
                body,
                sort_keys=True,
                separators=(",", ":"),
                allow_nan=False,
            ).encode("utf-8")
            if body is not None
            else None
        )
        request_headers = dict(headers)
        if payload is not None:
            request_headers["Content-Type"] = "application/json"
        request = urllib.request.Request(
            url,
            data=payload,
            method=method,
            headers=request_headers,
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                raw = response.read(2 * 1024 * 1024)
                status_code = response.status
        except urllib.error.HTTPError as error:
            status_code = error.code
            raw = error.read(2 * 1024 * 1024)
        except (OSError, TimeoutError, ValueError):
            raise SmokeFailure("HTTP boundary was unavailable") from None
        if not raw:
            return status_code, {}
        try:
            decoded = json.loads(raw)
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise SmokeFailure("HTTP boundary returned invalid JSON") from None
        if not isinstance(decoded, dict):
            raise SmokeFailure("HTTP boundary returned an invalid envelope")
        return status_code, decoded

    def _best_effort_cleanup(self) -> None:
        for account in self.accounts:
            if account.id_token and account.profile_id:
                try:
                    self._managed_request(
                        account,
                        "DELETE",
                        "/v1/managed/social/profile",
                        expected={204, 404},
                    )
                except SmokeFailure:
                    pass
            if account.id_token and not account.account_erasure_requested:
                try:
                    self._authenticate(account)
                    self._managed_request(
                        account,
                        "POST",
                        "/v1/managed/erasure",
                        body={
                            "request_id": str(uuid4()),
                            "scope": "account",
                            "confirmation_sha256": hashlib.sha256(
                                b"delete-noop-plus-managed-account-v1"
                            ).hexdigest(),
                        },
                        expected={202, 403, 409},
                    )
                    account.account_erasure_requested = True
                except SmokeFailure:
                    pass
            if account.local_id and self.access_token:
                try:
                    self._identity_admin_request(
                        "POST",
                        suffix="/accounts:delete",
                        body={
                            "localId": account.local_id,
                            "targetProjectId": self.project_id,
                        },
                        expected={200, 404},
                        api_version="v1",
                    )
                except SmokeFailure:
                    pass
                account.local_id = ""
                account.id_token = ""
        if self.identity_config_changed and self.original_test_numbers:
            try:
                self._patch_test_numbers(self.original_test_numbers)
            except SmokeFailure:
                print(
                    "FAIL temporary fictional identity configuration needs review",
                    file=sys.stderr,
                )
            self.identity_config_changed = False
        if self.debug_resource and self.access_token:
            path = f"/v1/{urllib.parse.quote(self.debug_resource, safe='/')}"
            try:
                self._google_json_request(
                    "firebaseappcheck.googleapis.com",
                    path,
                    method="DELETE",
                    oauth=True,
                )
            except SmokeFailure:
                print(
                    "FAIL temporary App Check debug assertion needs review",
                    file=sys.stderr,
                )
            self.debug_resource = ""

    def _apple_api_key(self) -> str:
        rows = json.loads(
            self._command(
                "gcloud",
                "services",
                "api-keys",
                "list",
                "--format=json",
            )
        )
        names = [
            str(row.get("name") or "").rsplit("/", 1)[-1]
            for row in rows
            if row.get("displayName") == "NOOP iOS synthetic staging"
        ]
        if len(names) != 1:
            raise SmokeFailure("staging iOS API key metadata is ambiguous")
        value = self._command(
            "gcloud",
            "services",
            "api-keys",
            "get-key-string",
            names[0],
            "--format=value(keyString)",
        )
        if len(value) < 20:
            raise SmokeFailure("staging iOS API key is unavailable")
        return value

    @staticmethod
    def _new_synthetic_phone(existing: set[str]) -> str:
        for _ in range(100):
            candidate = f"+1650555{secrets.randbelow(10_000):04d}"
            if candidate not in existing:
                return candidate
        raise SmokeFailure("could not allocate a fictional phone")

    @staticmethod
    def _installation_token() -> str:
        token = "noopm_" + secrets.token_urlsafe(32)
        if len(token) != 49:
            raise SmokeFailure("installation credential generation failed")
        return token

    @staticmethod
    def _command(*arguments: str) -> str:
        try:
            result = subprocess.run(
                list(arguments),
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
        except (OSError, subprocess.CalledProcessError):
            raise SmokeFailure("required operator command failed") from None
        return result.stdout.strip()

    @staticmethod
    def _tofu_output(name: str) -> str:
        return ManagedStagingSmoke._command(
            "tofu",
            f"-chdir={INFRA_DIR}",
            "output",
            "-raw",
            name,
        )

    @staticmethod
    def _tofu_output_json(name: str) -> dict[str, Any]:
        raw = ManagedStagingSmoke._command(
            "tofu",
            f"-chdir={INFRA_DIR}",
            "output",
            "-json",
            name,
        )
        value = json.loads(raw)
        if not isinstance(value, dict):
            raise SmokeFailure("OpenTofu output has an invalid shape")
        return value


def main() -> int:
    try:
        ManagedStagingSmoke().run()
    except SmokeFailure as error:
        print(f"FAIL {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
