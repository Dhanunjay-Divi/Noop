#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import sys
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any, Literal
from uuid import UUID, uuid5


ROOT = Path(__file__).resolve().parents[1]
SERVER_ROOT = ROOT / "server"
sys.path.insert(0, str(SERVER_ROOT))

from app.managed_push import (  # noqa: E402
    FirebaseCloudMessagingProvider,
    ManagedPushResult,
    ManagedPushTokenCodec,
)
from app.managed_safety_repository import ManagedSafetyPushService  # noqa: E402


NAMESPACE = UUID("77650a5e-e608-5bda-b5aa-1a297d54a33d")
TOKEN_SECRET = "noop-synthetic-safety-smoke-" + ("s" * 32)
ROLE_ORDER = (
    "owner_test_confirmation",
    "emergency_contact_1",
    "emergency_contact_2",
)


@dataclass(frozen=True, slots=True)
class SyntheticTarget:
    role: str
    platform: Literal["ios", "android"]
    target_kind: Literal["token", "fid"] = "token"


class SyntheticDeliveryRepository:
    def __init__(
        self,
        *,
        incident_id: UUID,
        expires_at: datetime,
        targets: tuple[SyntheticTarget, ...],
        codec: ManagedPushTokenCodec,
    ) -> None:
        self.incident_id = incident_id
        self.targets = targets
        self._claimed = False
        self._completed: dict[UUID, dict[str, Any]] = {}
        self._deliveries: list[dict[str, Any]] = []
        for target in targets:
            account_id = uuid5(NAMESPACE, f"account:{target.role}")
            installation_id = f"synthetic-{target.platform}-{target.role}"
            token = f"fcm-token:synthetic_{target.role}_{target.platform}"
            delivery_id = uuid5(NAMESPACE, f"delivery:{target.role}")
            self._deliveries.append(
                {
                    "delivery_id": delivery_id,
                    "claim_id": uuid5(NAMESPACE, f"claim:{target.role}"),
                    "incident_id": incident_id,
                    "account_id": account_id,
                    "installation_id": installation_id,
                    "platform": target.platform,
                    "target_kind": target.target_kind,
                    "token_hash": codec.token_hash(token),
                    "token_ciphertext": codec.seal(
                        token,
                        account_id=account_id,
                        installation_id=installation_id,
                    ),
                    "expires_at": expires_at,
                    "attempt": 1,
                    "role": target.role,
                }
            )

    async def claim_push_deliveries(
        self,
        *,
        exclude_delivery_ids: set[UUID] | tuple[UUID, ...],
        **_: Any,
    ) -> list[dict[str, Any]]:
        if self._claimed:
            return []
        excluded = set(exclude_delivery_ids)
        self._claimed = True
        return [
            delivery
            for delivery in self._deliveries
            if delivery["delivery_id"] not in excluded
        ]

    async def complete_push_delivery(self, **values: Any) -> None:
        self._completed[values["delivery_id"]] = dict(values)

    async def reencrypt_push_installation_token(self, **_: Any) -> bool:
        return True

    async def delivery_summary(self, **_: Any) -> dict[str, int]:
        sent = sum(
            values.get("outcome") == "sent" for values in self._completed.values()
        )
        contacts = sum(
            target.role.startswith("emergency_contact_") for target in self.targets
        )
        reached_contacts = sum(
            target.role.startswith("emergency_contact_")
            and self._completed.get(
                uuid5(NAMESPACE, f"delivery:{target.role}"),
                {},
            ).get("outcome")
            == "sent"
            for target in self.targets
        )
        return {
            "contacts_targeted": contacts,
            "contacts_reached": reached_contacts,
            "installations_targeted": len(self.targets),
            "installations_reached": sent,
        }


class CapturingPushProvider:
    def __init__(
        self,
        *,
        targets_by_token: dict[str, SyntheticTarget],
        now: datetime,
    ) -> None:
        self.targets_by_token = targets_by_token
        self.now = now
        self.captures: list[dict[str, Any]] = []

    @property
    def available(self) -> bool:
        return True

    @property
    def maximum_delivery_seconds(self) -> int:
        return 1

    async def send_safety_incident(
        self,
        *,
        token: str,
        platform: Literal["ios", "android"],
        target_kind: Literal["token", "fid"],
        incident_id: UUID,
        expires_at: datetime,
    ) -> ManagedPushResult:
        target = self.targets_by_token[token]
        if target.platform != platform or target.target_kind != target_kind:
            raise AssertionError("synthetic target metadata changed")
        payload = FirebaseCloudMessagingProvider.payload(
            token=token,
            platform=platform,
            incident_id=incident_id,
            expires_at=expires_at,
            now=self.now,
        )
        serialized = json.dumps(payload, sort_keys=True).casefold()
        forbidden = (
            "latitude",
            "longitude",
            "location",
            "display_name",
            "health",
            "heart",
            "sleep",
            "recovery",
        )
        if any(value in serialized for value in forbidden):
            raise AssertionError("sensitive material entered a Safety push")
        message = payload["message"]
        self.captures.append(
            {
                "role": target.role,
                "platform": platform,
                "target_kind": target_kind,
                "kind": message["data"]["kind"],
                "route": message["data"]["route"],
                "priority": (
                    message.get("android", {}).get("priority")
                    if platform == "android"
                    else message["apns"]["headers"]["apns-priority"]
                ),
                "generic_alert": (
                    None
                    if platform == "android"
                    else message["apns"]["payload"]["aps"]["alert"]
                ),
                "contains_sensitive_values": False,
            }
        )
        return ManagedPushResult(
            outcome="sent",
            provider_reference_hash=hashlib.sha256(
                f"synthetic:{target.role}".encode("utf-8")
            ).hexdigest(),
        )


def synthetic_targets() -> tuple[SyntheticTarget, ...]:
    return (
        SyntheticTarget(role=ROLE_ORDER[0], platform="ios"),
        SyntheticTarget(role=ROLE_ORDER[1], platform="ios"),
        SyntheticTarget(role=ROLE_ORDER[2], platform="android"),
    )


async def run_smoke() -> dict[str, Any]:
    now = datetime(2026, 9, 19, 12, 0, tzinfo=UTC)
    expires_at = now + timedelta(hours=8)
    incident_id = uuid5(NAMESPACE, "incident")
    codec = ManagedPushTokenCodec(TOKEN_SECRET, write_version="v2")
    targets = synthetic_targets()
    repository = SyntheticDeliveryRepository(
        incident_id=incident_id,
        expires_at=expires_at,
        targets=targets,
        codec=codec,
    )
    tokens = {
        f"fcm-token:synthetic_{target.role}_{target.platform}": target
        for target in targets
    }
    provider = CapturingPushProvider(targets_by_token=tokens, now=now)
    service = ManagedSafetyPushService(
        repository=repository,  # type: ignore[arg-type]
        token_codec=codec,
        provider=provider,
        max_concurrency=3,
    )
    summary = await service.dispatch(
        principal=object(),  # type: ignore[arg-type]
        incident_id=incident_id,
    )
    captures = sorted(
        provider.captures,
        key=lambda capture: ROLE_ORDER.index(capture["role"]),
    )
    if summary != {
        "contacts_targeted": 2,
        "contacts_reached": 2,
        "installations_targeted": 3,
        "installations_reached": 3,
    }:
        raise AssertionError("synthetic Safety delivery summary changed")
    if [capture["role"] for capture in captures] != list(ROLE_ORDER):
        raise AssertionError("synthetic Safety recipient roles changed")
    return {
        "mode": "synthetic_capture_only",
        "external_network_requests": 0,
        "emergency_services_contacted": False,
        "real_people_contacted": False,
        "recipient_scope": (
            "Preselected dummy recipients only. Accepted-contact eligibility "
            "is verified by the PostgreSQL integration test."
        ),
        "location_scope": (
            "No location is created or sent by this transport capture. "
            "Latest-only retention and terminal deletion are verified by "
            "separate PostgreSQL lifecycle tests."
        ),
        "owner_test_behavior": "Test-only self confirmation notification preview.",
        "real_incident_owner_behavior": (
            "The owner sees incident and delivery status in-app and is not "
            "treated as an emergency-contact responder."
        ),
        "summary": summary,
        "deliveries": captures,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Capture a synthetic NOOP app-to-app Safety page for the owner and "
            "two dummy emergency contacts without making a network request."
        )
    )
    parser.add_argument(
        "--compact",
        action="store_true",
        help="emit one-line JSON",
    )
    arguments = parser.parse_args(argv)
    report = asyncio.run(run_smoke())
    print(
        json.dumps(
            report,
            indent=None if arguments.compact else 2,
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
