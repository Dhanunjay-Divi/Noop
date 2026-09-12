from __future__ import annotations

import re
from datetime import UTC, datetime
from typing import Literal
from uuid import UUID

from pydantic import Field, SecretStr, field_validator, model_validator

from app.managed_models import StrictModel

MANAGED_PUSH_TOKEN_PATTERN = r"^[A-Za-z0-9:_-]{16,4096}$"
MANAGED_SAFETY_INVITE_PATTERN = r"^noopsafety_[A-Za-z0-9_-]{43}$"


def _utc(value: datetime) -> datetime:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("timestamp must include a UTC offset")
    return value.astimezone(UTC)


class ManagedPushRegistration(StrictModel):
    platform: Literal["ios", "android"]
    environment: Literal["development", "production"]
    target_kind: Literal["token", "fid"]
    token: SecretStr

    @field_validator("token")
    @classmethod
    def valid_token(cls, value: SecretStr) -> SecretStr:
        if (
            re.fullmatch(
                MANAGED_PUSH_TOKEN_PATTERN,
                value.get_secret_value(),
            )
            is None
        ):
            raise ValueError("push token is invalid")
        return value

    @model_validator(mode="after")
    def valid_target_kind(self) -> ManagedPushRegistration:
        if self.platform == "android" and self.target_kind != "token":
            raise ValueError("android push registrations must use token")
        return self


class ManagedSafetyInviteCreate(StrictModel):
    request_id: UUID
    capability: SecretStr
    expires_in_hours: int = Field(default=72, ge=1, le=168)

    @field_validator("capability")
    @classmethod
    def valid_capability(cls, value: SecretStr) -> SecretStr:
        if (
            re.fullmatch(
                MANAGED_SAFETY_INVITE_PATTERN,
                value.get_secret_value(),
            )
            is None
        ):
            raise ValueError("managed Safety invite is invalid")
        return value


class ManagedSafetyInviteRedeem(StrictModel):
    request_id: UUID
    capability: SecretStr

    @field_validator("capability")
    @classmethod
    def valid_capability(cls, value: SecretStr) -> SecretStr:
        if (
            re.fullmatch(
                MANAGED_SAFETY_INVITE_PATTERN,
                value.get_secret_value(),
            )
            is None
        ):
            raise ValueError("managed Safety invite is invalid")
        return value


class ManagedSafetyRequestCreate(StrictModel):
    request_id: UUID
    noop_id: str = Field(
        pattern=(
            r"^NOOP-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}-"
            r"[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$"
        )
    )

    @field_validator("noop_id", mode="before")
    @classmethod
    def canonical_noop_id(cls, value: object) -> object:
        return value.upper() if isinstance(value, str) else value


class ManagedSafetyRequestDecision(StrictModel):
    decision: Literal["accept", "decline"]


class ManagedSafetyIncidentCreate(StrictModel):
    request_id: UUID
    trigger: Literal["manual_sos", "band_sos"] = "manual_sos"
    duration_hours: Literal[8, 12] = 8
    share_location: bool = True


class ManagedSafetyLocationUpdate(StrictModel):
    sequence: int = Field(ge=1, le=9_223_372_036_854_775_807)
    latitude: float = Field(ge=-90.0, le=90.0)
    longitude: float = Field(ge=-180.0, le=180.0)
    horizontal_accuracy_m: float = Field(ge=0.0, le=10_000.0)
    captured_at: datetime

    @field_validator("captured_at")
    @classmethod
    def normalized_captured_at(cls, value: datetime) -> datetime:
        return _utc(value)


class ManagedSafetyResponse(StrictModel):
    decision: Literal["responding", "cannot_respond"]


class ManagedSafetyIncidentEnd(StrictModel):
    outcome: Literal["resolved", "canceled"]
