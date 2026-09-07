#!/usr/bin/env python3
"""Verify the release calibration contract matches Apple and Android source."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONTRACT = ROOT / "release" / "metrics" / "reference-calibration-v1.json"
SWIFT_PATH = (
    "Packages/StrandAnalytics/Sources/StrandAnalytics/WhoopReferenceCalibration.swift"
)
KOTLIN_PATH = (
    "android/app/src/main/java/com/noop/analytics/WhoopReferenceCalibration.kt"
)


class AuditError(RuntimeError):
    """The platform implementations drifted from the reviewed contract."""


def _number(value: str) -> float:
    return float(value.replace("_", ""))


def _object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise AuditError(f"{label} must be an object")
    return value


def _load_contract(path: Path) -> dict[str, Any]:
    try:
        contract = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise AuditError("calibration contract is missing or invalid") from error
    required = {
        "schemaVersion",
        "algorithmRevisions",
        "modelVersion",
        "metrics",
        "configuration",
    }
    if not isinstance(contract, dict) or set(contract) != required:
        raise AuditError("calibration contract fields do not match schema version 1")
    if contract["schemaVersion"] != 1:
        raise AuditError("unsupported calibration contract schema")
    algorithms = _object(contract["algorithmRevisions"], "algorithmRevisions")
    if set(algorithms) != {"charge", "effort", "rest"}:
        raise AuditError("algorithm revision contract is incomplete")
    if any(not isinstance(value, str) or not value for value in algorithms.values()):
        raise AuditError("algorithm revisions must be non-empty strings")
    if not isinstance(contract["modelVersion"], str) or not contract["modelVersion"]:
        raise AuditError("modelVersion must be a non-empty string")
    metrics = contract["metrics"]
    if not isinstance(metrics, list) or not metrics:
        raise AuditError("metrics must be a non-empty list")
    seen_swift: set[str] = set()
    seen_kotlin: set[str] = set()
    seen_series: set[str] = set()
    for metric in metrics:
        item = _object(metric, "metric")
        if set(item) != {"swift", "kotlin", "seriesKey", "minimum", "maximum"}:
            raise AuditError("metric contract entry is incomplete")
        for key in ("swift", "kotlin", "seriesKey"):
            if not isinstance(item[key], str) or not item[key]:
                raise AuditError(f"metric {key} must be a non-empty string")
        minimum = item["minimum"]
        maximum = item["maximum"]
        if (
            not isinstance(minimum, (int, float))
            or not isinstance(maximum, (int, float))
            or minimum >= maximum
        ):
            raise AuditError("metric range is invalid")
        if item["swift"] in seen_swift or item["kotlin"] in seen_kotlin:
            raise AuditError("metric identifiers must be unique")
        seen_swift.add(item["swift"])
        seen_kotlin.add(item["kotlin"])
        seen_series.add(item["seriesKey"])
    if len(seen_series) != len(metrics):
        raise AuditError("metric series keys must be unique")
    configuration = _object(contract["configuration"], "configuration")
    expected_configuration = {
        "minimumPairs",
        "minimumTrainingPairs",
        "minimumHoldoutPairs",
        "holdoutFraction",
        "holdoutFractionMinimum",
        "holdoutFractionMaximum",
        "minimumTrainingCorrelation",
        "minimumRelativeMAEImprovement",
        "minimumSlope",
        "maximumSlope",
        "strongConfidencePairs",
        "strongConfidenceCorrelation",
        "strongConfidenceMAEImprovement",
    }
    if set(configuration) != expected_configuration:
        raise AuditError("calibration configuration contract is incomplete")
    if any(not isinstance(value, (int, float)) for value in configuration.values()):
        raise AuditError("calibration configuration values must be numeric")
    if (
        configuration["minimumPairs"]
        < configuration["minimumTrainingPairs"] + configuration["minimumHoldoutPairs"]
        or not 0
        < configuration["holdoutFractionMinimum"]
        <= configuration["holdoutFraction"]
        <= configuration["holdoutFractionMaximum"]
        <= 0.5
        or not 0 < configuration["minimumTrainingCorrelation"] <= 1
        or not 0 < configuration["minimumRelativeMAEImprovement"] <= 1
        or not 0 < configuration["minimumSlope"] <= configuration["maximumSlope"]
        or configuration["strongConfidencePairs"] < configuration["minimumPairs"]
        or not configuration["minimumTrainingCorrelation"]
        <= configuration["strongConfidenceCorrelation"]
        <= 1
        or not configuration["minimumRelativeMAEImprovement"]
        <= configuration["strongConfidenceMAEImprovement"]
        <= 1
    ):
        raise AuditError("calibration configuration weakens the safety contract")
    return contract


def _slice(text: str, start: str, end: str) -> str:
    try:
        begin = text.index(start)
        finish = text.index(end, begin)
    except ValueError as error:
        raise AuditError("calibration source structure is not recognized") from error
    return text[begin:finish]


def _swift_ranges(text: str) -> dict[str, tuple[float, float]]:
    block = _slice(text, "var plausibleRange:", "fileprivate func dailyValue")
    ranges: dict[str, tuple[float, float]] = {}
    pending: list[str] = []
    for raw in block.splitlines():
        line = raw.strip()
        if line.startswith("case "):
            pending = re.findall(r"\.([A-Za-z0-9_]+)", line)
        match = re.search(r"return\s+([0-9_.]+)\.\.\.([0-9_.]+)", line)
        if match and pending:
            value = (_number(match.group(1)), _number(match.group(2)))
            for name in pending:
                ranges[name] = value
            pending = []
    return ranges


def _swift_series(text: str) -> dict[str, str]:
    block = _slice(text, "var seriesKey:", "var plausibleRange:")
    return {
        name: key
        for name, key in re.findall(
            r"case\s+\.([A-Za-z0-9_]+):\s*return\s+\"([^\"]+)\"",
            block,
        )
    }


def _swift_config(text: str) -> dict[str, float]:
    block = _slice(
        text,
        "public init(minimumPairs:",
        "public static let conservative",
    )
    values = {
        name: _number(value)
        for name, value in re.findall(
            r"([A-Za-z0-9_]+):\s+(?:Int|Double)\s*=\s*([0-9.]+)",
            block,
        )
    }
    slope = re.search(
        r"allowedSlope:\s+ClosedRange<Double>\s*=\s*([0-9.]+)\.\.\.([0-9.]+)",
        block,
    )
    if slope is None:
        raise AuditError("Swift slope contract is missing")
    values["minimumSlope"] = _number(slope.group(1))
    values["maximumSlope"] = _number(slope.group(2))
    return values


def _kotlin_metrics(text: str) -> dict[str, tuple[str, float, float]]:
    block = _slice(text, "enum class WhoopComparableMetric(", "fun plausible")
    metrics: dict[str, tuple[str, float, float]] = {}
    for name, key, minimum, maximum in re.findall(
        r"^\s*([A-Z][A-Z0-9_]+)\(\"([^\"]+)\",\s*"
        r"([0-9_.]+),\s*([0-9_.]+)\)[,;]",
        block,
        flags=re.MULTILINE,
    ):
        metrics[name] = (key, _number(minimum), _number(maximum))
    return metrics


def _kotlin_config(text: str) -> dict[str, float]:
    block = _slice(
        text,
        "data class PersonalCalibrationConfiguration(",
        "data class WhoopReferenceComparisonReport(",
    )
    return {
        name: _number(value)
        for name, value in re.findall(
            r"val\s+([A-Za-z0-9_]+):\s+(?:Int|Double)\s*=\s*([0-9.]+)",
            block,
        )
    }


def _normalized(text: str) -> str:
    return " ".join(text.split())


def _require_fragments(text: str, fragments: tuple[str, ...], platform: str) -> None:
    normalized = _normalized(text)
    for fragment in fragments:
        if _normalized(fragment) not in normalized:
            raise AuditError(f"{platform} calibration guard is missing")


def audit(
    root: Path = ROOT,
    contract_path: Path | None = None,
) -> dict[str, int]:
    contract = _load_contract(
        contract_path or root / DEFAULT_CONTRACT.relative_to(ROOT)
    )
    try:
        swift = (root / SWIFT_PATH).read_text(encoding="utf-8")
        kotlin = (root / KOTLIN_PATH).read_text(encoding="utf-8")
    except OSError as error:
        raise AuditError("calibration platform source is missing") from error

    algorithms = contract["algorithmRevisions"]
    for name, revision in algorithms.items():
        swift_match = re.search(
            rf"public static let {re.escape(name)}\s*=\s*\"([^\"]+)\"",
            swift,
        )
        kotlin_match = re.search(
            rf"const val {name.upper()}\s*=\s*\"([^\"]+)\"",
            kotlin,
        )
        if swift_match is None or kotlin_match is None:
            raise AuditError(f"{name} algorithm revision is missing")
        if swift_match.group(1) != revision or kotlin_match.group(1) != revision:
            raise AuditError(f"{name} algorithm revision drift")

    model = contract["modelVersion"]
    swift_model = re.search(r'modelVersion\s*=\s*"([^"]+)"', swift)
    kotlin_model = re.search(r'MODEL_VERSION\s*=\s*"([^"]+)"', kotlin)
    if (
        swift_model is None
        or kotlin_model is None
        or swift_model.group(1) != model
        or kotlin_model.group(1) != model
    ):
        raise AuditError("personal calibration model revision drift")

    swift_series = _swift_series(swift)
    swift_ranges = _swift_ranges(swift)
    kotlin_metrics = _kotlin_metrics(kotlin)
    expected_swift = {metric["swift"] for metric in contract["metrics"]}
    expected_kotlin = {metric["kotlin"] for metric in contract["metrics"]}
    if set(swift_series) != expected_swift or set(swift_ranges) != expected_swift:
        raise AuditError("Swift comparable metric set drift")
    if set(kotlin_metrics) != expected_kotlin:
        raise AuditError("Kotlin comparable metric set drift")
    for metric in contract["metrics"]:
        swift_name = metric["swift"]
        kotlin_name = metric["kotlin"]
        expected = (
            metric["seriesKey"],
            float(metric["minimum"]),
            float(metric["maximum"]),
        )
        if swift_series.get(swift_name) != expected[0]:
            raise AuditError(f"{swift_name} series-key drift")
        if swift_ranges.get(swift_name) != expected[1:]:
            raise AuditError(f"{swift_name} range drift")
        if kotlin_metrics.get(kotlin_name) != expected:
            raise AuditError(f"{kotlin_name} metric contract drift")

    expected_config = {
        key: float(value)
        for key, value in contract["configuration"].items()
        if key not in {"holdoutFractionMinimum", "holdoutFractionMaximum"}
    }
    swift_config = _swift_config(swift)
    kotlin_config = _kotlin_config(kotlin)
    if set(swift_config) != set(expected_config):
        raise AuditError("Swift calibration configuration set drift")
    if set(kotlin_config) != set(expected_config):
        raise AuditError("Kotlin calibration configuration set drift")
    for name, value in expected_config.items():
        if swift_config.get(name) != value:
            raise AuditError(f"Swift {name} calibration threshold drift")
        if kotlin_config.get(name) != value:
            raise AuditError(f"Kotlin {name} calibration threshold drift")

    minimum_fraction = contract["configuration"]["holdoutFractionMinimum"]
    maximum_fraction = contract["configuration"]["holdoutFractionMaximum"]
    _require_fragments(
        swift,
        (
            f"let fraction = min({maximum_fraction}, "
            f"max({minimum_fraction}, c.holdoutFraction))",
            "for day in duplicateOfficial { officialByDay.removeValue(forKey: day) }",
            "for day in duplicateNoop { noopByDay.removeValue(forKey: day) }",
            "case .noopPersonalCalibration:",
            "let training = Array(pairs.prefix(trainingCount))",
            "let holdout = Array(pairs.suffix(holdoutCount))",
            "calibratedRMSE <= rawRMSE",
            "guard importedDeviceId != computedDeviceId",
        ),
        "Swift",
    )
    _require_fragments(
        kotlin,
        (
            f"val fraction = c.holdoutFraction.coerceIn("
            f"{minimum_fraction}, {maximum_fraction})",
            "duplicateOfficial.forEach(officialByDay::remove)",
            "duplicateNoop.forEach(noopByDay::remove)",
            "is ReferenceMetricProvenance.NoopPersonalCalibration -> invalid += 1",
            "val training = pairs.take(trainingCount)",
            "val holdout = pairs.takeLast(holdoutCount)",
            "calibratedRmse > rawRmse",
            "if (importedDeviceId == computedDeviceId)",
        ),
        "Kotlin",
    )

    return {
        "algorithmRevisions": len(algorithms),
        "metrics": len(contract["metrics"]),
        "thresholds": len(contract["configuration"]),
        "criticalGuards": 16,
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check",))
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--contract", type=Path)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        result = audit(args.root.resolve(), args.contract)
    except AuditError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(
        "Calibration parity: "
        f"{result['metrics']} metrics, "
        f"{result['algorithmRevisions']} revisions, "
        f"{result['thresholds']} thresholds, "
        f"{result['criticalGuards']} guards."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
