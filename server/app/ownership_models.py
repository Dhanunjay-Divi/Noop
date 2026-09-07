from __future__ import annotations

import re
from datetime import UTC, datetime
from typing import Literal
from urllib.parse import urlsplit
from uuid import UUID

from pydantic import Field, SecretStr, field_validator, model_validator

from app.models import INSTALLATION_ID_PATTERN, StrictModel

SHA256_PATTERN = r"^[0-9a-f]{64}$"
OWNERSHIP_INSTALLATION_TOKEN_PATTERN = r"^noopo_[A-Za-z0-9_-]{43}$"
OWNERSHIP_CHALLENGE_PATTERN = r"^[A-Za-z0-9_-]{43}$"
POLICY_VERSION_PATTERN = r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"
LOCALE_PATTERN = r"^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8}){0,2}$"


class OwnershipChallengeRequest(StrictModel):
    request_id: UUID
    platform: Literal["ios", "android"]


class OwnershipAccountRegistration(StrictModel):
    request_id: UUID
    installation_id: str = Field(
        min_length=1,
        max_length=64,
        pattern=INSTALLATION_ID_PATTERN,
    )
    installation_token: SecretStr
    platform: Literal["ios", "android"]
    policy_version: str = Field(
        min_length=1,
        max_length=64,
        pattern=POLICY_VERSION_PATTERN,
    )
    policy_sha256: str = Field(pattern=SHA256_PATTERN)
    locale: str = Field(
        min_length=2,
        max_length=32,
        pattern=LOCALE_PATTERN,
    )
    plan_selection: Literal["noop", "noop_plus"] = "noop"
    device_key_fingerprint: str | None = Field(
        default=None,
        pattern=SHA256_PATTERN,
    )

    @field_validator("installation_token")
    @classmethod
    def valid_installation_token(cls, value: SecretStr) -> SecretStr:
        if (
            re.fullmatch(
                OWNERSHIP_INSTALLATION_TOKEN_PATTERN,
                value.get_secret_value(),
            )
            is None
        ):
            raise ValueError("installation_token is invalid")
        return value


class OwnershipTermsAcceptance(StrictModel):
    request_id: UUID
    policy_version: str = Field(
        min_length=1,
        max_length=64,
        pattern=POLICY_VERSION_PATTERN,
    )
    policy_sha256: str = Field(pattern=SHA256_PATTERN)
    locale: str = Field(
        min_length=2,
        max_length=32,
        pattern=LOCALE_PATTERN,
    )


class OwnershipPossessionSubmission(StrictModel):
    request_id: UUID
    challenge_id: UUID
    challenge: SecretStr
    possession_response: SecretStr = Field(
        min_length=16,
        max_length=16_384,
    )

    @field_validator("challenge")
    @classmethod
    def valid_challenge(cls, value: SecretStr) -> SecretStr:
        if (
            re.fullmatch(
                OWNERSHIP_CHALLENGE_PATTERN,
                value.get_secret_value(),
            )
            is None
        ):
            raise ValueError("challenge is invalid")
        return value


class OwnershipInstallationAuthorization(OwnershipPossessionSubmission):
    new_installation_id: str = Field(
        min_length=1,
        max_length=64,
        pattern=INSTALLATION_ID_PATTERN,
    )
    new_installation_token: SecretStr
    new_platform: Literal["ios", "android"]
    device_key_fingerprint: str | None = Field(
        default=None,
        pattern=SHA256_PATTERN,
    )

    @field_validator("new_installation_token")
    @classmethod
    def valid_new_installation_token(cls, value: SecretStr) -> SecretStr:
        if (
            re.fullmatch(
                OWNERSHIP_INSTALLATION_TOKEN_PATTERN,
                value.get_secret_value(),
            )
            is None
        ):
            raise ValueError("new_installation_token is invalid")
        return value


class OwnershipPlanSelection(StrictModel):
    request_id: UUID
    selection: Literal["noop", "noop_plus"]


class OwnershipTermsManifest(StrictModel):
    policy_version: str = Field(pattern=POLICY_VERSION_PATTERN)
    locale: str = Field(pattern=LOCALE_PATTERN)
    document_sha256: str = Field(pattern=SHA256_PATTERN)
    document_uri: str = Field(
        min_length=12,
        max_length=1024,
        pattern=r"^https://[^\s]+$",
    )
    effective_at: datetime

    @field_validator("document_uri")
    @classmethod
    def static_document_uri(cls, value: str) -> str:
        try:
            components = urlsplit(value)
            _ = components.port
        except ValueError as error:
            raise ValueError("document_uri is invalid") from error
        if (
            components.scheme.casefold() != "https"
            or not components.hostname
            or components.port not in (None, 443)
            or components.username is not None
            or components.password is not None
            or "?" in value
            or "#" in value
        ):
            raise ValueError("document_uri must be a static public HTTPS URL")
        return value

    @model_validator(mode="after")
    def utc_effective_at(self) -> "OwnershipTermsManifest":
        if self.effective_at.tzinfo is None or self.effective_at.utcoffset() is None:
            raise ValueError("effective_at must include a UTC offset")
        self.effective_at = self.effective_at.astimezone(UTC)
        return self
