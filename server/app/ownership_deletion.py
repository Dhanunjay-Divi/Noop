from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Literal, Protocol

VERSION_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$")


@dataclass(frozen=True, slots=True)
class OwnershipBandRetirementCandidate:
    hardware_revision: str
    protocol_version: str
    firmware_version: str


@dataclass(frozen=True, slots=True)
class OwnershipBandRetirementEligibility:
    state: Literal[
        "blocked_policy",
        "blocked_hardware",
        "eligible_pending_operator",
    ]
    policy_version: str | None = None
    hardware_capability_version: str | None = None


class OwnershipBandRetirementEvaluating(Protocol):
    def evaluate(
        self,
        *,
        candidate: OwnershipBandRetirementCandidate,
        reason: Literal["deletion"],
    ) -> OwnershipBandRetirementEligibility: ...


class UnavailableOwnershipBandRetirementEvaluator:
    """Default production posture until policy and hardware are approved."""

    def evaluate(
        self,
        *,
        candidate: OwnershipBandRetirementCandidate,
        reason: Literal["deletion"],
    ) -> OwnershipBandRetirementEligibility:
        del candidate, reason
        return OwnershipBandRetirementEligibility(state="blocked_policy")


def safe_band_retirement_eligibility(
    evaluator: OwnershipBandRetirementEvaluating,
    *,
    candidate: OwnershipBandRetirementCandidate,
) -> OwnershipBandRetirementEligibility:
    """Normalize every unavailable or malformed policy result to fail-closed."""

    try:
        result = evaluator.evaluate(candidate=candidate, reason="deletion")
    except Exception:
        return OwnershipBandRetirementEligibility(state="blocked_policy")

    policy_valid = (
        result.policy_version is not None
        and VERSION_PATTERN.fullmatch(result.policy_version) is not None
    )
    capability_valid = (
        result.hardware_capability_version is not None
        and VERSION_PATTERN.fullmatch(result.hardware_capability_version) is not None
    )
    if result.state == "blocked_policy":
        return OwnershipBandRetirementEligibility(state="blocked_policy")
    if result.state == "blocked_hardware":
        if not policy_valid:
            return OwnershipBandRetirementEligibility(state="blocked_policy")
        return OwnershipBandRetirementEligibility(
            state="blocked_hardware",
            policy_version=result.policy_version,
        )
    if result.state == "eligible_pending_operator":
        if not policy_valid or not capability_valid:
            return OwnershipBandRetirementEligibility(state="blocked_policy")
        return result
    return OwnershipBandRetirementEligibility(state="blocked_policy")
