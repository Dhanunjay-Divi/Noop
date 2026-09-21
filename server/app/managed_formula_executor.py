from __future__ import annotations

import hashlib
import json
import math
import re
from dataclasses import dataclass
from datetime import UTC, date, datetime, time
from typing import Any, Literal, Mapping
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from app.managed_formula_registry import (
    CANONICAL_FORMULA_REGISTRY,
    FormulaContract,
    FormulaRegistry,
)

FormulaValueStatus = Literal["present", "missing", "not_supplied"]
FormulaParityStatus = Literal[
    "match",
    "mismatch",
    "both_missing",
    "server_missing",
    "client_missing",
    "not_compared",
    "revision_mismatch",
]

_SOURCE_KIND = re.compile(r"^[a-z][a-z0-9_]{1,63}$")
_REVISION = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_TIME_ZONE = re.compile(r"^[A-Za-z0-9_+.-]+(?:/[A-Za-z0-9_+.-]+)*$")


class FormulaInputContractError(ValueError):
    """Raised when an execution does not match a registered input contract."""


@dataclass(frozen=True, slots=True)
class FormulaDayContext:
    account_id: UUID
    local_day: date
    timezone_name: str
    day_start_at: datetime
    day_end_at: datetime
    utc_offset_start_minutes: int
    utc_offset_end_minutes: int

    @classmethod
    def create(
        cls,
        *,
        account_id: UUID,
        local_day: date,
        timezone_name: str,
    ) -> FormulaDayContext:
        if not _TIME_ZONE.fullmatch(timezone_name):
            raise FormulaInputContractError("timezone_name is invalid")
        try:
            zone = ZoneInfo(timezone_name)
        except ZoneInfoNotFoundError as exc:
            raise FormulaInputContractError("timezone_name is unknown") from exc
        local_start = datetime.combine(local_day, time.min, tzinfo=zone)
        try:
            next_local_day = date.fromordinal(local_day.toordinal() + 1)
        except ValueError as exc:
            raise FormulaInputContractError(
                "local_day is outside the supported range"
            ) from exc
        local_end = datetime.combine(
            next_local_day,
            time.min,
            tzinfo=zone,
        )
        start_offset = local_start.utcoffset()
        end_offset = local_end.utcoffset()
        if start_offset is None or end_offset is None:
            raise FormulaInputContractError("timezone offsets are unavailable")
        try:
            day_start_at = local_start.astimezone(UTC)
            day_end_at = local_end.astimezone(UTC)
        except (OverflowError, ValueError) as exc:
            raise FormulaInputContractError(
                "local_day is outside the supported range"
            ) from exc
        return cls(
            account_id=account_id,
            local_day=local_day,
            timezone_name=timezone_name,
            day_start_at=day_start_at,
            day_end_at=day_end_at,
            utc_offset_start_minutes=int(start_offset.total_seconds() / 60),
            utc_offset_end_minutes=int(end_offset.total_seconds() / 60),
        )


@dataclass(frozen=True, slots=True)
class FormulaProvenance:
    source_kind: str
    source_revision: str
    input_manifest_sha256: str
    calibration_revision: str | None = None

    def __post_init__(self) -> None:
        if not _SOURCE_KIND.fullmatch(self.source_kind):
            raise FormulaInputContractError("source_kind is invalid")
        if not _REVISION.fullmatch(self.source_revision):
            raise FormulaInputContractError("source_revision is invalid")
        if not _SHA256.fullmatch(self.input_manifest_sha256):
            raise FormulaInputContractError(
                "input_manifest_sha256 must be a lowercase SHA-256 digest"
            )
        if self.calibration_revision is not None and not _REVISION.fullmatch(
            self.calibration_revision
        ):
            raise FormulaInputContractError("calibration_revision is invalid")


@dataclass(frozen=True, slots=True)
class ClientFormulaObservation:
    status: FormulaValueStatus
    formula_revision: str | None = None
    value: float | None = None

    def __post_init__(self) -> None:
        if self.status == "not_supplied":
            if self.formula_revision is not None or self.value is not None:
                raise FormulaInputContractError(
                    "an omitted client observation cannot carry result fields"
                )
            return
        if self.formula_revision is None or not _REVISION.fullmatch(
            self.formula_revision
        ):
            raise FormulaInputContractError(
                "client formula revision is required for a compared result"
            )
        if self.status == "missing":
            if self.value is not None:
                raise FormulaInputContractError(
                    "a missing client observation cannot carry a value"
                )
            return
        if self.status != "present" or not _finite_number(self.value):
            raise FormulaInputContractError(
                "a present client observation requires a finite value"
            )


CLIENT_NOT_SUPPLIED = ClientFormulaObservation(status="not_supplied")


@dataclass(frozen=True, slots=True)
class DriverBaseline:
    mean: float
    spread: float
    usable: bool


@dataclass(frozen=True, slots=True)
class GravitySample:
    ts: int
    x: float
    y: float
    z: float


@dataclass(frozen=True, slots=True)
class FormulaExecution:
    context: FormulaDayContext
    provenance: FormulaProvenance
    metric_key: str
    formula_revision: str
    input_schema_revision: int
    output_unit: str
    input_set_sha256: str
    execution_sha256: str
    server_status: Literal["present", "missing"]
    server_value: float | None
    client_status: FormulaValueStatus
    client_formula_revision: str | None
    client_value: float | None
    parity_status: FormulaParityStatus
    absolute_delta: float | None
    parity_tolerance: float
    missing_inputs: tuple[str, ...]


class ManagedFormulaExecutor:
    _W_HRV = 0.55
    _W_RHR = 0.20
    _W_RESP = 0.05
    _W_SLEEP = 0.15
    _W_SKIN_TEMP = 0.05
    _W_RECOVERY_INDEX = 0.05
    _W_ACTIVITY_BALANCE = 0.05
    _SLEEP_CENTER = 0.85
    _SLEEP_SCALE = 0.12
    _RECOVERY_INDEX_SCALE = 2.0
    _LOGISTIC_SLOPE = 1.6
    _LOGISTIC_MIDPOINT = -0.20
    _SKIN_TEMP_MIN = -8.0
    _SKIN_TEMP_MAX = 8.0

    _WALKING_CADENCE = 100.0
    _LIGHT_MOVEMENT_WEIGHT = 0.25
    _MOTION_THRESHOLD_G = 0.15
    _MAX_MOTION_GAP_SECONDS = 120.0
    _MAX_CREDITED_MOTION_SECONDS = 60.0
    _EFFORT_DENOMINATOR = 7201.0

    def __init__(
        self,
        registry: FormulaRegistry = CANONICAL_FORMULA_REGISTRY,
    ) -> None:
        self._registry = registry

    def execute(
        self,
        *,
        metric_key: str,
        formula_revision: str,
        context: FormulaDayContext,
        inputs: Mapping[str, Any],
        provenance: FormulaProvenance,
        client_observation: ClientFormulaObservation = CLIENT_NOT_SUPPLIED,
    ) -> FormulaExecution:
        contract = self._registry.require(metric_key, formula_revision)
        unknown = sorted(set(inputs) - set(contract.input_by_name))
        if unknown:
            raise FormulaInputContractError(
                "unregistered formula inputs: " + ", ".join(unknown)
            )
        normalized = self._normalize_inputs(contract, inputs)
        required_missing = tuple(
            item.name
            for item in contract.inputs
            if item.required and item.name not in normalized
        )

        if required_missing:
            value = None
            missing_inputs = required_missing
        elif metric_key == "recovery":
            value = self._recovery(normalized)
            missing_inputs = () if value is not None else ("recovery_inputs",)
        elif metric_key == "daily_effort":
            value = self._daily_effort(normalized)
            missing_inputs = (
                () if value is not None else ("cardio_effort", "movement_evidence")
            )
        else:  # pragma: no cover - registry and dispatch evolve together
            raise FormulaInputContractError("registered formula has no executor")

        server_status: Literal["present", "missing"] = (
            "present" if value is not None else "missing"
        )
        parity_status, absolute_delta = self._compare(
            contract=contract,
            server_status=server_status,
            server_value=value,
            client=client_observation,
        )
        input_set_sha256 = _sha256_json(
            {
                "metric_key": metric_key,
                "formula_revision": formula_revision,
                "input_schema_revision": contract.input_schema_revision,
                "inputs": _wire_value(normalized),
            }
        )
        execution_sha256 = _sha256_json(
            {
                "account_id": str(context.account_id),
                "local_day": context.local_day.isoformat(),
                "timezone_name": context.timezone_name,
                "day_start_at": context.day_start_at.isoformat(),
                "day_end_at": context.day_end_at.isoformat(),
                "metric_key": metric_key,
                "formula_revision": formula_revision,
                "input_set_sha256": input_set_sha256,
                "provenance": {
                    "source_kind": provenance.source_kind,
                    "source_revision": provenance.source_revision,
                    "input_manifest_sha256": provenance.input_manifest_sha256,
                    "calibration_revision": provenance.calibration_revision,
                },
                "client": {
                    "status": client_observation.status,
                    "formula_revision": client_observation.formula_revision,
                    "value": client_observation.value,
                },
            }
        )
        return FormulaExecution(
            context=context,
            provenance=provenance,
            metric_key=metric_key,
            formula_revision=formula_revision,
            input_schema_revision=contract.input_schema_revision,
            output_unit=contract.output_unit,
            input_set_sha256=input_set_sha256,
            execution_sha256=execution_sha256,
            server_status=server_status,
            server_value=value,
            client_status=client_observation.status,
            client_formula_revision=client_observation.formula_revision,
            client_value=client_observation.value,
            parity_status=parity_status,
            absolute_delta=absolute_delta,
            parity_tolerance=contract.parity_absolute_tolerance,
            missing_inputs=missing_inputs,
        )

    def _normalize_inputs(
        self,
        contract: FormulaContract,
        inputs: Mapping[str, Any],
    ) -> dict[str, Any]:
        normalized: dict[str, Any] = {}
        for item in contract.inputs:
            if item.name not in inputs:
                continue
            raw = inputs[item.name]
            value: Any | None
            if item.value_kind == "number":
                value = float(raw) if _finite_number(raw) else None
            elif item.value_kind == "integer":
                value = _integer(raw)
            elif item.value_kind == "baseline":
                value = _baseline(raw)
            else:
                value = _gravity_samples(raw)
            if value is not None:
                normalized[item.name] = value
        return normalized

    @classmethod
    def _recovery(cls, inputs: Mapping[str, Any]) -> float | None:
        hrv = inputs["hrv"]
        rhr = inputs["rhr"]
        hrv_baseline: DriverBaseline = inputs["hrv_baseline"]
        if not hrv_baseline.usable:
            return None

        terms: list[tuple[float, float]] = [
            (
                cls._z_score(hrv, hrv_baseline.mean, hrv_baseline.spread),
                cls._W_HRV,
            )
        ]
        rhr_baseline = inputs.get("rhr_baseline")
        if rhr_baseline is not None and rhr_baseline.usable:
            terms.append(
                (
                    cls._z_score(
                        rhr_baseline.mean,
                        rhr,
                        rhr_baseline.spread,
                    ),
                    cls._W_RHR,
                )
            )
        resp = inputs.get("resp")
        resp_baseline = inputs.get("resp_baseline")
        if resp is not None and resp_baseline is not None and resp_baseline.usable:
            terms.append(
                (
                    cls._z_score(
                        resp_baseline.mean,
                        resp,
                        resp_baseline.spread,
                    ),
                    cls._W_RESP,
                )
            )
        sleep = inputs.get("sleep_performance_fraction")
        if sleep is not None and 0.0 <= sleep <= 1.0:
            rest_baseline = inputs.get("rest_quality_baseline")
            center = cls._SLEEP_CENTER
            if (
                rest_baseline is not None
                and rest_baseline.usable
                and 0.0 <= rest_baseline.mean <= 1.0
            ):
                center = rest_baseline.mean
            terms.append(((sleep - center) / cls._SLEEP_SCALE, cls._W_SLEEP))
        skin_temp = inputs.get("skin_temperature_deviation_c")
        if (
            skin_temp is not None
            and cls._SKIN_TEMP_MIN <= skin_temp <= cls._SKIN_TEMP_MAX
            and skin_temp < 20.0
        ):
            terms.append((-abs(skin_temp), cls._W_SKIN_TEMP))
        recovery_index = inputs.get("recovery_index_slope_bpm_per_hour")
        if recovery_index is not None:
            terms.append(
                (
                    -recovery_index / cls._RECOVERY_INDEX_SCALE,
                    cls._W_RECOVERY_INDEX,
                )
            )
        effort = inputs.get("prior_day_effort")
        effort_baseline = inputs.get("effort_baseline")
        if (
            effort is not None
            and effort_baseline is not None
            and effort_baseline.usable
        ):
            terms.append(
                (
                    cls._z_score(
                        effort_baseline.mean,
                        effort,
                        effort_baseline.spread,
                    ),
                    cls._W_ACTIVITY_BALANCE,
                )
            )

        total_weight = sum(weight for _, weight in terms)
        composite_z = sum(z * weight for z, weight in terms) / total_weight
        if not math.isfinite(composite_z):
            return None
        logistic_input = cls._LOGISTIC_SLOPE * (composite_z - cls._LOGISTIC_MIDPOINT)
        if logistic_input >= 0:
            score = 100.0 / (1.0 + math.exp(-logistic_input))
        else:
            exponential = math.exp(logistic_input)
            score = 100.0 * exponential / (1.0 + exponential)
        if not math.isfinite(score):
            return None
        return min(100.0, max(0.0, score))

    @classmethod
    def _daily_effort(cls, inputs: Mapping[str, Any]) -> float | None:
        cardio = inputs.get("cardio_effort")
        if cardio is not None and not 0.0 <= cardio <= 100.0:
            cardio = None
        movement = cls._movement_effort(inputs)
        if movement is None:
            return cardio
        if cardio is None:
            return movement
        return max(cardio, movement)

    @classmethod
    def _movement_effort(cls, inputs: Mapping[str, Any]) -> float | None:
        steps = inputs.get("steps")
        if steps is not None and steps > 0:
            minutes = steps / cls._WALKING_CADENCE
            return cls._movement_effort_from_minutes(minutes)
        samples: tuple[GravitySample, ...] = inputs.get("gravity_samples", ())
        if len(samples) < 2:
            return None
        active_seconds = 0.0
        ordered = sorted(samples, key=lambda sample: sample.ts)
        for previous, current in zip(ordered, ordered[1:]):
            gap = float(current.ts - previous.ts)
            if gap <= 0.0 or gap > cls._MAX_MOTION_GAP_SECONDS:
                continue
            dx = current.x - previous.x
            dy = current.y - previous.y
            dz = current.z - previous.z
            if math.sqrt(dx * dx + dy * dy + dz * dz) >= cls._MOTION_THRESHOLD_G:
                active_seconds += min(gap, cls._MAX_CREDITED_MOTION_SECONDS)
        if active_seconds <= 0:
            return None
        return cls._movement_effort_from_minutes(active_seconds / 60.0)

    @classmethod
    def _movement_effort_from_minutes(cls, minutes: float) -> float | None:
        if not math.isfinite(minutes) or minutes <= 0:
            return None
        low_intensity_trimp = minutes * cls._LIGHT_MOVEMENT_WEIGHT
        value = (
            100.0
            * math.log(low_intensity_trimp + 1.0)
            / math.log(cls._EFFORT_DENOMINATOR)
        )
        rounded = math.floor(value * 100.0 + 0.5) / 100.0
        return min(100.0, rounded)

    @staticmethod
    def _z_score(value: float, mean: float, spread: float) -> float:
        sigma = max(1.253 * spread, 1e-9)
        return (value - mean) / sigma

    @staticmethod
    def _compare(
        *,
        contract: FormulaContract,
        server_status: Literal["present", "missing"],
        server_value: float | None,
        client: ClientFormulaObservation,
    ) -> tuple[FormulaParityStatus, float | None]:
        if client.status == "not_supplied":
            return "not_compared", None
        if client.formula_revision != contract.formula_revision:
            return "revision_mismatch", None
        if server_status == "missing" and client.status == "missing":
            return "both_missing", None
        if server_status == "missing":
            return "server_missing", None
        if client.status == "missing":
            return "client_missing", None
        assert server_value is not None and client.value is not None
        delta = abs(server_value - client.value)
        status: FormulaParityStatus = (
            "match" if delta <= contract.parity_absolute_tolerance else "mismatch"
        )
        return status, delta


def _finite_number(value: Any) -> bool:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    try:
        return math.isfinite(float(value))
    except OverflowError as error:
        raise FormulaInputContractError(
            "formula numeric input is outside the supported range"
        ) from error


def _integer(value: Any) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    if not -(2**63) <= value < 2**63:
        return None
    return value


def _baseline(value: Any) -> DriverBaseline | None:
    if not isinstance(value, Mapping):
        return None
    if set(value) - {"mean", "spread", "usable"}:
        return None
    if not _finite_number(value.get("mean")) or not _finite_number(value.get("spread")):
        return None
    spread = float(value["spread"])
    if spread < 0:
        return None
    usable = value.get("usable", True)
    if not isinstance(usable, bool):
        return None
    return DriverBaseline(
        mean=float(value["mean"]),
        spread=spread,
        usable=usable,
    )


def _gravity_samples(value: Any) -> tuple[GravitySample, ...] | None:
    if not isinstance(value, (list, tuple)) or len(value) > 86_400:
        return None
    samples: list[GravitySample] = []
    for raw in value:
        if not isinstance(raw, Mapping) or set(raw) != {"ts", "x", "y", "z"}:
            continue
        ts = _integer(raw["ts"])
        if ts is None or not all(_finite_number(raw[axis]) for axis in ("x", "y", "z")):
            continue
        samples.append(
            GravitySample(
                ts=ts,
                x=float(raw["x"]),
                y=float(raw["y"]),
                z=float(raw["z"]),
            )
        )
    return tuple(samples)


def _wire_value(value: Any) -> Any:
    if isinstance(value, DriverBaseline):
        return {
            "mean": value.mean,
            "spread": value.spread,
            "usable": value.usable,
        }
    if isinstance(value, GravitySample):
        return {"ts": value.ts, "x": value.x, "y": value.y, "z": value.z}
    if isinstance(value, Mapping):
        return {key: _wire_value(item) for key, item in sorted(value.items())}
    if isinstance(value, (tuple, list)):
        return [_wire_value(item) for item in value]
    return value


def _sha256_json(value: Any) -> str:
    payload = json.dumps(
        value,
        allow_nan=False,
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("ascii")
    return hashlib.sha256(payload).hexdigest()
