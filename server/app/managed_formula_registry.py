from __future__ import annotations

import re
from dataclasses import dataclass, field
from types import MappingProxyType
from typing import Mapping

_KEY = re.compile(r"^[a-z][a-z0-9_]{1,63}$")
_REVISION = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


@dataclass(frozen=True, slots=True)
class FormulaInputField:
    name: str
    value_kind: str
    required: bool

    def __post_init__(self) -> None:
        if not _KEY.fullmatch(self.name):
            raise ValueError("formula input names must be stable snake_case keys")
        if self.value_kind not in {
            "number",
            "integer",
            "baseline",
            "gravity_samples",
        }:
            raise ValueError("unsupported formula input value kind")


@dataclass(frozen=True, slots=True)
class FormulaContract:
    metric_key: str
    formula_revision: str
    input_schema_revision: int
    output_unit: str
    parity_absolute_tolerance: float
    inputs: tuple[FormulaInputField, ...]
    _input_by_name: Mapping[str, FormulaInputField] = field(
        init=False,
        repr=False,
        compare=False,
    )

    def __post_init__(self) -> None:
        object.__setattr__(self, "inputs", tuple(self.inputs))
        if not _KEY.fullmatch(self.metric_key):
            raise ValueError("formula metric keys must be stable snake_case keys")
        if not _REVISION.fullmatch(self.formula_revision):
            raise ValueError("formula revisions must be stable wire identifiers")
        if self.input_schema_revision < 1:
            raise ValueError("input schema revisions must be positive")
        if not self.output_unit or len(self.output_unit) > 32:
            raise ValueError("formula output units must be bounded")
        if (
            not self.parity_absolute_tolerance >= 0
            or not self.parity_absolute_tolerance < float("inf")
        ):
            raise ValueError("parity tolerance must be finite and non-negative")
        by_name = {item.name: item for item in self.inputs}
        if len(by_name) != len(self.inputs):
            raise ValueError("formula input names must be unique")
        object.__setattr__(self, "_input_by_name", MappingProxyType(by_name))

    @property
    def input_by_name(self) -> Mapping[str, FormulaInputField]:
        return self._input_by_name


@dataclass(frozen=True, slots=True)
class FormulaRegistry:
    _contracts: Mapping[tuple[str, str], FormulaContract]

    def __post_init__(self) -> None:
        object.__setattr__(
            self,
            "_contracts",
            MappingProxyType(dict(self._contracts)),
        )

    @classmethod
    def build(cls, contracts: tuple[FormulaContract, ...]) -> FormulaRegistry:
        by_key = {
            (contract.metric_key, contract.formula_revision): contract
            for contract in contracts
        }
        if len(by_key) != len(contracts):
            raise ValueError("formula metric and revision pairs must be unique")
        return cls(MappingProxyType(by_key))

    @property
    def contracts(self) -> tuple[FormulaContract, ...]:
        return tuple(self._contracts.values())

    def require(self, metric_key: str, formula_revision: str) -> FormulaContract:
        try:
            return self._contracts[(metric_key, formula_revision)]
        except KeyError as exc:
            raise KeyError(
                f"unregistered formula contract: {metric_key}@{formula_revision}"
            ) from exc


RECOVERY_CONTRACT = FormulaContract(
    metric_key="recovery",
    formula_revision="noop-charge-v2",
    input_schema_revision=1,
    output_unit="percent",
    parity_absolute_tolerance=1e-9,
    inputs=(
        FormulaInputField("hrv", "number", True),
        FormulaInputField("rhr", "number", True),
        FormulaInputField("hrv_baseline", "baseline", True),
        FormulaInputField("rhr_baseline", "baseline", False),
        FormulaInputField("resp", "number", False),
        FormulaInputField("resp_baseline", "baseline", False),
        FormulaInputField("sleep_performance_fraction", "number", False),
        FormulaInputField("rest_quality_baseline", "baseline", False),
        FormulaInputField("skin_temperature_deviation_c", "number", False),
        FormulaInputField(
            "recovery_index_slope_bpm_per_hour",
            "number",
            False,
        ),
        FormulaInputField("effort_baseline", "baseline", False),
        FormulaInputField("prior_day_effort", "number", False),
    ),
)

DAILY_EFFORT_CONTRACT = FormulaContract(
    metric_key="daily_effort",
    formula_revision="noop-effort-v2",
    input_schema_revision=1,
    output_unit="score_0_100",
    parity_absolute_tolerance=1e-9,
    inputs=(
        FormulaInputField("cardio_effort", "number", False),
        FormulaInputField("steps", "integer", False),
        FormulaInputField("gravity_samples", "gravity_samples", False),
    ),
)

CANONICAL_FORMULA_REGISTRY = FormulaRegistry.build(
    (RECOVERY_CONTRACT, DAILY_EFFORT_CONTRACT)
)
