from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Protocol


class OwnershipPossessionError(Exception):
    """Base class for first-party band possession verification failures."""


class OwnershipPossessionRejectedError(OwnershipPossessionError):
    """The response is invalid, stale, replayed, or for another challenge."""


class OwnershipPossessionUnavailableError(OwnershipPossessionError):
    """No approved supplier possession verifier is available."""


@dataclass(frozen=True, slots=True)
class OwnershipPossessionEvidence:
    provisioned_identity_hash: str
    protocol_version: str
    firmware_version: str
    confirmed_at: datetime


class OwnershipPossessionVerifying(Protocol):
    async def verify(
        self,
        *,
        challenge: str,
        response: str,
    ) -> OwnershipPossessionEvidence: ...


class UnavailableOwnershipPossessionVerifier:
    """Fail closed until the approved supplier SDK supplies signed proof."""

    async def verify(
        self,
        *,
        challenge: str,
        response: str,
    ) -> OwnershipPossessionEvidence:
        del challenge, response
        raise OwnershipPossessionUnavailableError(
            "band possession verification is unavailable"
        )
