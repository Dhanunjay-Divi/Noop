from __future__ import annotations

import asyncio
import hashlib
import json
from collections import Counter
from datetime import UTC, date, datetime
from pathlib import Path
from typing import Any, Protocol
from uuid import UUID

from app.models import (
    FriendVisibility,
    SyncCounts,
    SyncPayload,
    SyncResult,
    sample_semantics,
)


class SyncConflictError(Exception):
    """Raised when a batch identifier is reused for different content."""


class FriendNotFoundError(Exception):
    """Raised when a social object is absent or intentionally undiscoverable."""


class FriendConflictError(Exception):
    """Raised when a social transition conflicts with its current state."""


class FriendForbiddenError(Exception):
    """Raised when a profile does not own the requested social transition."""


FRIEND_METRIC_ALIASES: dict[str, tuple[str, ...]] = {
    "charge": ("recovery",),
    "effort": ("effort",),
    "rest": ("sleep_performance",),
    "sleep_duration": ("total_sleep_min",),
    "hrv": ("avg_hrv",),
    "rhr": ("resting_hr",),
}
FRIEND_DAILY_METRICS = frozenset(
    metric for aliases in FRIEND_METRIC_ALIASES.values() for metric in aliases
)


def _friend_pair(first: str, second: str) -> tuple[str, str]:
    return tuple(sorted((first, second)))  # type: ignore[return-value]


def _friend_device_matches_installation(
    daily_device_id: str, installation_id: str
) -> bool:
    components = daily_device_id.split(":", 2)
    return (
        len(components) == 3
        and components[0] in {"ios", "android", "macos"}
        and components[1] == installation_id
        and bool(components[2])
    )


def _project_friend_metrics(
    metrics: dict[str, float], visibility: dict[str, bool]
) -> dict[str, float]:
    projected: dict[str, float] = {}
    for output_name, aliases in FRIEND_METRIC_ALIASES.items():
        if not visibility.get(output_name, False):
            continue
        for stored_name in aliases:
            if stored_name in metrics:
                projected[output_name] = metrics[stored_name]
                break
    return projected


class Repository(Protocol):
    async def startup(self) -> None: ...

    async def shutdown(self) -> None: ...

    async def sync(
        self,
        payload: SyncPayload,
        payload_hash: str,
        social_profile_id: str | None = None,
    ) -> SyncResult: ...

    async def list_devices(self) -> list[dict[str, Any]]: ...

    async def latest_metrics(
        self, device_id: str, metrics: list[str] | None
    ) -> dict[str, dict[str, Any]]: ...

    async def metric_range(
        self,
        device_id: str,
        metric: str,
        start: datetime,
        end: datetime,
        limit: int,
    ) -> list[dict[str, Any]]: ...

    async def daily_metrics(
        self, device_id: str, start: date, end: date
    ) -> list[dict[str, Any]]: ...

    async def events(
        self,
        device_id: str,
        start: datetime,
        end: datetime,
        limit: int,
    ) -> list[dict[str, Any]]: ...

    async def sleep_sessions(
        self,
        device_id: str,
        start: datetime,
        end: datetime,
        limit: int,
    ) -> list[dict[str, Any]]: ...

    async def workouts(
        self,
        device_id: str,
        start: datetime,
        end: datetime,
        limit: int,
    ) -> list[dict[str, Any]]: ...

    async def journal_entries(
        self, device_id: str, start: date, end: date
    ) -> list[dict[str, Any]]: ...

    async def stats(self) -> dict[str, Any]: ...

    async def export_device(
        self,
        device_id: str,
        start: datetime | None,
        end: datetime | None,
    ) -> dict[str, Any]: ...

    async def delete_device(self, device_id: str) -> dict[str, int]: ...

    async def purge_before(
        self, cutoff: datetime, device_id: str | None = None
    ) -> dict[str, int]: ...

    async def create_friend_profile(
        self,
        profile_id: str,
        enrollment_id: str,
        display_name: str,
        installation_id: str,
        daily_device_id: str,
        token_hash: str,
    ) -> dict[str, Any]: ...

    async def list_friend_profiles(self) -> list[dict[str, Any]]: ...

    async def friend_profile_for_token(
        self, token_hash: str
    ) -> dict[str, Any] | None: ...

    async def update_friend_profile(
        self,
        profile_id: str,
        changes: dict[str, Any],
    ) -> dict[str, Any]: ...

    async def rotate_friend_token(
        self, profile_id: str, token_hash: str
    ) -> dict[str, Any]: ...

    async def disable_friend_profile(self, profile_id: str) -> None: ...

    async def delete_friend_profile_data(
        self, profile_id: str, daily_device_id: str
    ) -> dict[str, int]: ...

    async def create_friend_invite(
        self,
        invite_id: str,
        inviter_id: str,
        code_hash: str,
        expires_at: datetime,
    ) -> dict[str, Any]: ...

    async def revoke_friend_invite(self, profile_id: str, invite_id: str) -> None: ...

    async def redeem_friend_invite(
        self,
        code_hash: str,
        requester_id: str,
        request_id: str,
        now: datetime,
    ) -> dict[str, Any]: ...

    async def join_friend_invite(
        self,
        code_hash: str,
        profile_id: str,
        enrollment_id: str,
        display_name: str,
        installation_id: str,
        daily_device_id: str,
        token_hash: str,
        request_id: str,
        now: datetime,
    ) -> dict[str, Any]: ...

    async def list_friend_requests(self, profile_id: str) -> list[dict[str, Any]]: ...

    async def decide_friend_request(
        self,
        profile_id: str,
        request_id: str,
        decision: str,
        now: datetime,
    ) -> dict[str, Any]: ...

    async def list_friends(self, profile_id: str) -> list[dict[str, Any]]: ...

    async def update_friend_visibility(
        self,
        owner_id: str,
        viewer_id: str,
        changes: dict[str, bool],
    ) -> dict[str, bool]: ...

    async def remove_friend(self, profile_id: str, friend_id: str) -> None: ...

    async def block_friend(self, profile_id: str, blocked_id: str) -> None: ...

    async def unblock_friend(self, profile_id: str, blocked_id: str) -> None: ...

    async def friend_feed(
        self, profile_id: str, start: date, end: date
    ) -> list[dict[str, Any]]: ...


class MemoryRepository:
    """Deterministic repository used by tests and local API experiments."""

    def __init__(self) -> None:
        self._lock = asyncio.Lock()
        self._batch_hashes: dict[str, tuple[str, str, datetime]] = {}
        self._devices: dict[str, dict[str, Any]] = {}
        self._metrics: dict[tuple[str, str, datetime, str], dict[str, Any]] = {}
        self._events: dict[tuple[str, str], dict[str, Any]] = {}
        self._daily: dict[tuple[str, date, str], dict[str, Any]] = {}
        self._sleep: dict[tuple[str, str], dict[str, Any]] = {}
        self._workouts: dict[tuple[str, str], dict[str, Any]] = {}
        self._journal: dict[tuple[str, date, str], dict[str, Any]] = {}
        self._friend_profiles: dict[str, dict[str, Any]] = {}
        self._friend_tokens: dict[str, str] = {}
        self._friend_invites: dict[str, dict[str, Any]] = {}
        self._friend_requests: dict[str, dict[str, Any]] = {}
        self._friendships: dict[tuple[str, str], dict[str, Any]] = {}
        self._friend_visibility: dict[tuple[str, str], dict[str, bool]] = {}
        self._friend_blocks: set[tuple[str, str]] = set()

    async def startup(self) -> None:
        return None

    async def shutdown(self) -> None:
        return None

    async def sync(
        self,
        payload: SyncPayload,
        payload_hash: str,
        social_profile_id: str | None = None,
    ) -> SyncResult:
        batch_id = str(payload.batch_id)
        async with self._lock:
            if social_profile_id is not None:
                profile = self._friend_profiles.get(social_profile_id)
                if (
                    profile is None
                    or profile["disabled_at"] is not None
                    or profile["daily_device_id"] != payload.source.device_id
                ):
                    raise FriendForbiddenError(
                        "member profile is no longer active for this producer"
                    )
            existing_batch = self._batch_hashes.get(batch_id)
            if existing_batch is not None:
                existing_hash = existing_batch[0]
                if existing_hash != payload_hash:
                    raise SyncConflictError(
                        "batch_id was already used for different content"
                    )
                return SyncResult(
                    batch_id=payload.batch_id,
                    duplicate=True,
                    counts=SyncCounts(),
                )

            device_id = payload.source.device_id
            row_provenance = {
                "sync_batch_id": str(payload.batch_id),
                "source_platform": payload.source.platform,
                "source_metadata": dict(payload.source.metadata),
            }
            device = payload.source.device.model_dump(mode="json")
            previous = self._devices.get(device_id, {})
            self._devices[device_id] = {
                "device_id": device_id,
                "display_name": device["display_name"]
                if device["display_name"] is not None
                else previous.get("display_name"),
                "model": device["model"]
                if device["model"] is not None
                else previous.get("model"),
                "firmware_version": device["firmware_version"]
                if device["firmware_version"] is not None
                else previous.get("firmware_version"),
                "hardware_revision": device["hardware_revision"]
                if device["hardware_revision"] is not None
                else previous.get("hardware_revision"),
                "platform": payload.source.platform or previous.get("platform"),
                "app_version": payload.source.app_version
                or previous.get("app_version"),
                "last_seen": max(
                    payload.source.sent_at,
                    previous.get("last_seen", payload.source.sent_at),
                ),
                "metadata": {**previous.get("metadata", {}), **payload.source.metadata},
            }

            metric_count = 0
            for metric, samples in payload.streams.numeric_items():
                for sample in samples:
                    unit, measurement_class, interpretable = sample_semantics(
                        metric, sample
                    )
                    sample_key = _sample_key(metric, sample.value, sample.metadata)
                    self._metrics[
                        (device_id, metric, sample.recorded_at, sample_key)
                    ] = {
                        "recorded_at": sample.recorded_at,
                        "value": sample.value,
                        "unit": unit,
                        "measurement_class": measurement_class,
                        "clinical_interpretation_allowed": interpretable,
                        "quality": sample.quality,
                        "metadata": sample.metadata,
                        **row_provenance,
                    }
                    metric_count += 1

            for event in payload.streams.events:
                self._events[(device_id, event.event_id)] = {
                    **event.model_dump(mode="python"),
                    **row_provenance,
                }

            daily_count = 0
            for day, metrics in payload.daily_metrics.items():
                if social_profile_id is not None:
                    omitted_keys = [
                        key
                        for key in self._daily
                        if key[0] == device_id
                        and key[1] == day
                        and key[2] in FRIEND_DAILY_METRICS
                        and key[2] not in metrics
                    ]
                    for key in omitted_keys:
                        del self._daily[key]
                for metric, value in metrics.items():
                    self._daily[(device_id, day, metric)] = {
                        "value": value,
                        **row_provenance,
                    }
                    daily_count += 1

            for sleep in payload.sleep_sessions:
                self._sleep[(device_id, sleep.session_id)] = {
                    **sleep.model_dump(mode="python"),
                    **row_provenance,
                }

            for workout in payload.workouts:
                self._workouts[(device_id, workout.workout_id)] = {
                    **workout.model_dump(mode="python"),
                    **row_provenance,
                }

            for entry in payload.journal:
                self._journal[(device_id, entry.day, entry.question.casefold())] = {
                    **entry.model_dump(mode="python"),
                    **row_provenance,
                }

            self._batch_hashes[batch_id] = (
                payload_hash,
                device_id,
                datetime.now(UTC),
            )
            return SyncResult(
                batch_id=payload.batch_id,
                duplicate=False,
                counts=SyncCounts(
                    metric_samples=metric_count,
                    events=len(payload.streams.events),
                    daily_metrics=daily_count,
                    sleep_sessions=len(payload.sleep_sessions),
                    workouts=len(payload.workouts),
                    journal_entries=len(payload.journal),
                ),
            )

    async def list_devices(self) -> list[dict[str, Any]]:
        async with self._lock:
            return sorted(
                (dict(device) for device in self._devices.values()),
                key=lambda device: device["last_seen"],
                reverse=True,
            )

    async def latest_metrics(
        self, device_id: str, metrics: list[str] | None
    ) -> dict[str, dict[str, Any]]:
        selected = set(metrics) if metrics else None
        latest: dict[str, dict[str, Any]] = {}
        async with self._lock:
            for (
                stored_device,
                metric,
                recorded_at,
                _sample_key,
            ), sample in self._metrics.items():
                if stored_device != device_id:
                    continue
                if selected is not None and metric not in selected:
                    continue
                current = latest.get(metric)
                if current is None or current["recorded_at"] < recorded_at:
                    latest[metric] = dict(sample)
        return dict(sorted(latest.items()))

    async def metric_range(
        self,
        device_id: str,
        metric: str,
        start: datetime,
        end: datetime,
        limit: int,
    ) -> list[dict[str, Any]]:
        async with self._lock:
            values = [
                dict(sample)
                for (
                    stored_device,
                    stored_metric,
                    recorded_at,
                    _sample_key,
                ), sample in self._metrics.items()
                if stored_device == device_id
                and stored_metric == metric
                and start <= recorded_at < end
            ]
        if metric == "rr":
            return sorted(
                values,
                key=lambda sample: (
                    sample["recorded_at"],
                    int(sample["metadata"]["seq"]),
                    sample["value"],
                ),
            )[:limit]
        return sorted(values, key=lambda sample: sample["recorded_at"])[:limit]

    async def daily_metrics(
        self, device_id: str, start: date, end: date
    ) -> list[dict[str, Any]]:
        grouped: dict[date, dict[str, Any]] = {}
        async with self._lock:
            for (stored_device, day, metric), row in self._daily.items():
                if stored_device == device_id and start <= day <= end:
                    day_row = grouped.setdefault(day, {"metrics": {}, "provenance": {}})
                    day_row["metrics"][metric] = row["value"]
                    day_row["provenance"][metric] = {
                        key: row[key]
                        for key in (
                            "sync_batch_id",
                            "source_platform",
                            "source_metadata",
                        )
                    }
        return [
            {
                "day": day,
                "metrics": dict(sorted(row["metrics"].items())),
                "provenance": dict(sorted(row["provenance"].items())),
            }
            for day, row in sorted(grouped.items())
        ]

    async def events(
        self,
        device_id: str,
        start: datetime,
        end: datetime,
        limit: int,
    ) -> list[dict[str, Any]]:
        async with self._lock:
            records = [
                dict(record)
                for (stored_device, _), record in self._events.items()
                if stored_device == device_id and start <= record["recorded_at"] < end
            ]
        return sorted(records, key=lambda record: record["recorded_at"])[:limit]

    async def sleep_sessions(
        self,
        device_id: str,
        start: datetime,
        end: datetime,
        limit: int,
    ) -> list[dict[str, Any]]:
        async with self._lock:
            records = [
                dict(record)
                for (stored_device, _), record in self._sleep.items()
                if stored_device == device_id
                and record["start_ts"] < end
                and record["end_ts"] > start
            ]
        return sorted(records, key=lambda record: record["start_ts"], reverse=True)[
            :limit
        ]

    async def workouts(
        self,
        device_id: str,
        start: datetime,
        end: datetime,
        limit: int,
    ) -> list[dict[str, Any]]:
        async with self._lock:
            records = [
                dict(record)
                for (stored_device, _), record in self._workouts.items()
                if stored_device == device_id
                and record["start_ts"] < end
                and record["end_ts"] > start
            ]
        return sorted(records, key=lambda record: record["start_ts"], reverse=True)[
            :limit
        ]

    async def journal_entries(
        self, device_id: str, start: date, end: date
    ) -> list[dict[str, Any]]:
        async with self._lock:
            records = [
                dict(record)
                for (stored_device, day, _), record in self._journal.items()
                if stored_device == device_id and start <= day <= end
            ]
        return sorted(
            records,
            key=lambda record: (record["day"], record["question"].casefold()),
            reverse=True,
        )

    async def stats(self) -> dict[str, Any]:
        async with self._lock:
            newest = max(
                (device["last_seen"] for device in self._devices.values()),
                default=None,
            )
            return {
                "storage": "memory",
                "devices": len(self._devices),
                "metric_samples": len(self._metrics),
                "events": len(self._events),
                "daily_metrics": len(self._daily),
                "sleep_sessions": len(self._sleep),
                "workouts": len(self._workouts),
                "journal_entries": len(self._journal),
                "sync_batches": len(self._batch_hashes),
                "latest_sync_at": newest,
            }

    async def export_device(
        self,
        device_id: str,
        start: datetime | None,
        end: datetime | None,
    ) -> dict[str, Any]:
        def in_window(value: datetime) -> bool:
            return (start is None or value >= start) and (end is None or value < end)

        async with self._lock:
            device = self._devices.get(device_id)
            metrics = [
                {"metric": metric, **dict(sample)}
                for (
                    stored_device,
                    metric,
                    recorded_at,
                    _sample_key,
                ), sample in self._metrics.items()
                if stored_device == device_id and in_window(recorded_at)
            ]
            events = [
                dict(record)
                for (stored_device, _), record in self._events.items()
                if stored_device == device_id and in_window(record["recorded_at"])
            ]
            daily = [
                {"day": day, "metric": metric, **dict(row)}
                for (stored_device, day, metric), row in self._daily.items()
                if stored_device == device_id
                and (start is None or day >= start.date())
                and (end is None or day < end.date())
            ]
            sleep = [
                dict(record)
                for (stored_device, _), record in self._sleep.items()
                if stored_device == device_id
                and (end is None or record["start_ts"] < end)
                and (start is None or record["end_ts"] > start)
            ]
            workouts = [
                dict(record)
                for (stored_device, _), record in self._workouts.items()
                if stored_device == device_id
                and (end is None or record["start_ts"] < end)
                and (start is None or record["end_ts"] > start)
            ]
            journal = [
                dict(record)
                for (stored_device, day, _), record in self._journal.items()
                if stored_device == device_id
                and (start is None or day >= start.date())
                and (end is None or day < end.date())
            ]
        return {
            "schema_version": 1,
            "exported_at": datetime.now().astimezone(),
            "device": dict(device) if device else None,
            "metric_samples": sorted(metrics, key=lambda row: row["recorded_at"]),
            "events": sorted(events, key=lambda row: row["recorded_at"]),
            "daily_metrics": sorted(daily, key=lambda row: (row["day"], row["metric"])),
            "sleep_sessions": sorted(sleep, key=lambda row: row["start_ts"]),
            "workouts": sorted(workouts, key=lambda row: row["start_ts"]),
            "journal": sorted(journal, key=lambda row: (row["day"], row["question"])),
            "notice": (
                "Raw ADC channels are uncalibrated sensor counts, not clinical "
                "SpO2, temperature, or respiration measurements."
            ),
        }

    async def delete_device(self, device_id: str) -> dict[str, int]:
        async with self._lock:
            counts = Counter()
            if self._devices.pop(device_id, None) is not None:
                counts["devices"] += 1
            stores: tuple[tuple[str, dict[Any, Any]], ...] = (
                ("metric_samples", self._metrics),
                ("events", self._events),
                ("daily_metrics", self._daily),
                ("sleep_sessions", self._sleep),
                ("workouts", self._workouts),
                ("journal_entries", self._journal),
            )
            for label, store in stores:
                keys = [key for key in store if key[0] == device_id]
                counts[label] += len(keys)
                for key in keys:
                    del store[key]
            batch_keys = [
                batch_id
                for batch_id, (_, stored_device, _) in self._batch_hashes.items()
                if stored_device == device_id
            ]
            counts["sync_batches"] = len(batch_keys)
            for batch_id in batch_keys:
                del self._batch_hashes[batch_id]
            return dict(counts)

    async def purge_before(
        self, cutoff: datetime, device_id: str | None = None
    ) -> dict[str, int]:
        async with self._lock:
            counts = Counter()

            def selected(stored_device: str) -> bool:
                return device_id is None or stored_device == device_id

            timed_stores: tuple[tuple[str, dict[Any, Any], Any], ...] = (
                ("metric_samples", self._metrics, lambda key, row: key[2]),
                ("events", self._events, lambda key, row: row["recorded_at"]),
                ("sleep_sessions", self._sleep, lambda key, row: row["end_ts"]),
                ("workouts", self._workouts, lambda key, row: row["end_ts"]),
            )
            for label, store, timestamp in timed_stores:
                keys = [
                    key
                    for key, row in store.items()
                    if selected(key[0]) and timestamp(key, row) < cutoff
                ]
                counts[label] = len(keys)
                for key in keys:
                    del store[key]
            daily_keys = [
                key
                for key in self._daily
                if selected(key[0]) and key[1] < cutoff.date()
            ]
            journal_keys = [
                key
                for key in self._journal
                if selected(key[0]) and key[1] < cutoff.date()
            ]
            counts["daily_metrics"] = len(daily_keys)
            counts["journal_entries"] = len(journal_keys)
            for key in daily_keys:
                del self._daily[key]
            for key in journal_keys:
                del self._journal[key]
            batch_keys = [
                batch_id
                for batch_id, (
                    _,
                    stored_device,
                    received_at,
                ) in self._batch_hashes.items()
                if selected(stored_device) and received_at < cutoff
            ]
            counts["sync_batches"] = len(batch_keys)
            for batch_id in batch_keys:
                del self._batch_hashes[batch_id]
            return dict(counts)

    async def create_friend_profile(
        self,
        profile_id: str,
        enrollment_id: str,
        display_name: str,
        installation_id: str,
        daily_device_id: str,
        token_hash: str,
    ) -> dict[str, Any]:
        if not _friend_device_matches_installation(daily_device_id, installation_id):
            raise FriendConflictError(
                "daily device must be scoped to the profile installation"
            )
        now = datetime.now(UTC)
        async with self._lock:
            if token_hash in self._friend_tokens:
                raise FriendConflictError("friend credential already exists")
            if any(
                profile["enrollment_id"] == enrollment_id
                for profile in self._friend_profiles.values()
            ):
                raise FriendConflictError("friend enrollment already exists")
            if any(
                profile["installation_id"] == installation_id
                and profile["disabled_at"] is None
                for profile in self._friend_profiles.values()
            ):
                raise FriendConflictError(
                    "this installation already has a friend profile"
                )
            profile = {
                "profile_id": profile_id,
                "enrollment_id": enrollment_id,
                "display_name": display_name,
                "installation_id": installation_id,
                "daily_device_id": daily_device_id,
                "created_at": now,
                "updated_at": now,
                "disabled_at": None,
            }
            self._friend_profiles[profile_id] = profile
            self._friend_tokens[token_hash] = profile_id
            return dict(profile)

    async def list_friend_profiles(self) -> list[dict[str, Any]]:
        async with self._lock:
            return [
                dict(profile)
                for profile in sorted(
                    self._friend_profiles.values(),
                    key=lambda row: (row["display_name"].casefold(), row["profile_id"]),
                )
            ]

    async def friend_profile_for_token(self, token_hash: str) -> dict[str, Any] | None:
        async with self._lock:
            profile_id = self._friend_tokens.get(token_hash)
            profile = self._friend_profiles.get(profile_id or "")
            if profile is None or profile["disabled_at"] is not None:
                return None
            return dict(profile)

    async def update_friend_profile(
        self,
        profile_id: str,
        changes: dict[str, Any],
    ) -> dict[str, Any]:
        async with self._lock:
            profile = self._friend_profiles.get(profile_id)
            if profile is None:
                raise FriendNotFoundError("friend profile was not found")
            if changes.get("display_name") is not None:
                profile["display_name"] = changes["display_name"]
            if "daily_device_id" in changes:
                if not _friend_device_matches_installation(
                    changes["daily_device_id"] or "",
                    profile["installation_id"],
                ):
                    raise FriendConflictError(
                        "daily_device_id must remain scoped to the profile installation"
                    )
                profile["daily_device_id"] = changes["daily_device_id"]
            profile["updated_at"] = datetime.now(UTC)
            return dict(profile)

    async def rotate_friend_token(
        self, profile_id: str, token_hash: str
    ) -> dict[str, Any]:
        async with self._lock:
            profile = self._friend_profiles.get(profile_id)
            if profile is None or profile["disabled_at"] is not None:
                raise FriendNotFoundError("friend profile was not found")
            for stored_hash, stored_profile in list(self._friend_tokens.items()):
                if stored_profile == profile_id:
                    del self._friend_tokens[stored_hash]
            self._friend_tokens[token_hash] = profile_id
            profile["updated_at"] = datetime.now(UTC)
            return dict(profile)

    async def disable_friend_profile(self, profile_id: str) -> None:
        async with self._lock:
            profile = self._friend_profiles.get(profile_id)
            if profile is None:
                raise FriendNotFoundError("friend profile was not found")
            now = datetime.now(UTC)
            profile["disabled_at"] = now
            profile["updated_at"] = now
            for stored_hash, stored_profile in list(self._friend_tokens.items()):
                if stored_profile == profile_id:
                    del self._friend_tokens[stored_hash]
            for invite in self._friend_invites.values():
                if invite["inviter_id"] == profile_id and invite["revoked_at"] is None:
                    invite["revoked_at"] = now
            for request in self._friend_requests.values():
                if (
                    profile_id in (request["inviter_id"], request["requester_id"])
                    and request["status"] == "pending"
                ):
                    request["status"] = "cancelled"
                    request["decided_at"] = now
            pairs = [pair for pair in self._friendships if profile_id in pair]
            for pair in pairs:
                del self._friendships[pair]
                self._friend_visibility.pop((pair[0], pair[1]), None)
                self._friend_visibility.pop((pair[1], pair[0]), None)

    async def delete_friend_profile_data(
        self, profile_id: str, daily_device_id: str
    ) -> dict[str, int]:
        async with self._lock:
            profile = self._friend_profiles.get(profile_id)
            if (
                profile is None
                or profile["disabled_at"] is not None
                or profile["daily_device_id"] != daily_device_id
            ):
                raise FriendForbiddenError(
                    "member profile is no longer active for this producer"
                )

            counts = Counter()
            daily_keys = [key for key in self._daily if key[0] == daily_device_id]
            counts["daily_metrics"] = len(daily_keys)
            for key in daily_keys:
                del self._daily[key]

            batch_keys = [
                batch_id
                for batch_id, (_, device_id, _) in self._batch_hashes.items()
                if device_id == daily_device_id
            ]
            counts["sync_batches"] = len(batch_keys)
            for batch_id in batch_keys:
                del self._batch_hashes[batch_id]

            own_invites = {
                invite_id
                for invite_id, invite in self._friend_invites.items()
                if invite["inviter_id"] == profile_id
            }
            request_keys = [
                request_id
                for request_id, request in self._friend_requests.items()
                if profile_id in (request["inviter_id"], request["requester_id"])
                or request["invite_id"] in own_invites
            ]
            counts["friend_requests"] = len(request_keys)
            for request_id in request_keys:
                del self._friend_requests[request_id]

            counts["friend_invites"] = len(own_invites)
            for invite_id in own_invites:
                del self._friend_invites[invite_id]
            for invite in self._friend_invites.values():
                if invite["redeemed_by"] == profile_id:
                    invite["redeemed_by"] = None

            friendship_keys = [pair for pair in self._friendships if profile_id in pair]
            counts["friendships"] = len(friendship_keys)
            for pair in friendship_keys:
                del self._friendships[pair]

            visibility_keys = [
                key for key in self._friend_visibility if profile_id in key
            ]
            counts["friend_visibility"] = len(visibility_keys)
            for key in visibility_keys:
                del self._friend_visibility[key]

            block_keys = [key for key in self._friend_blocks if profile_id in key]
            counts["friend_blocks"] = len(block_keys)
            for key in block_keys:
                self._friend_blocks.remove(key)

            token_keys = [
                token_hash
                for token_hash, stored_profile_id in self._friend_tokens.items()
                if stored_profile_id == profile_id
            ]
            counts["friend_tokens"] = len(token_keys)
            for token_hash in token_keys:
                del self._friend_tokens[token_hash]

            del self._friend_profiles[profile_id]
            counts["friend_profiles"] = 1

            has_remaining_rows = any(
                key[0] == daily_device_id
                for store in (
                    self._metrics,
                    self._events,
                    self._sleep,
                    self._workouts,
                    self._journal,
                )
                for key in store
            )
            if (
                not has_remaining_rows
                and self._devices.pop(daily_device_id, None) is not None
            ):
                counts["devices"] = 1
            return dict(counts)

    async def create_friend_invite(
        self,
        invite_id: str,
        inviter_id: str,
        code_hash: str,
        expires_at: datetime,
    ) -> dict[str, Any]:
        now = datetime.now(UTC)
        async with self._lock:
            profile = self._friend_profiles.get(inviter_id)
            if profile is None or profile["disabled_at"] is not None:
                raise FriendNotFoundError("friend profile was not found")
            if any(
                row["code_hash"] == code_hash for row in self._friend_invites.values()
            ):
                raise FriendConflictError("invite code already exists")
            invite = {
                "invite_id": invite_id,
                "inviter_id": inviter_id,
                "code_hash": code_hash,
                "created_at": now,
                "expires_at": expires_at,
                "redeemed_at": None,
                "redeemed_by": None,
                "revoked_at": None,
            }
            self._friend_invites[invite_id] = invite
            return {key: value for key, value in invite.items() if key != "code_hash"}

    async def revoke_friend_invite(self, profile_id: str, invite_id: str) -> None:
        async with self._lock:
            invite = self._friend_invites.get(invite_id)
            if invite is None or invite["inviter_id"] != profile_id:
                raise FriendNotFoundError("invite was not found")
            if invite["redeemed_at"] is not None:
                raise FriendConflictError("invite has already been redeemed")
            invite["revoked_at"] = datetime.now(UTC)

    async def redeem_friend_invite(
        self,
        code_hash: str,
        requester_id: str,
        request_id: str,
        now: datetime,
    ) -> dict[str, Any]:
        async with self._lock:
            invite = next(
                (
                    row
                    for row in self._friend_invites.values()
                    if row["code_hash"] == code_hash
                ),
                None,
            )
            if (
                invite is None
                or invite["revoked_at"] is not None
                or invite["redeemed_at"] is not None
                or invite["expires_at"] <= now
            ):
                raise FriendNotFoundError("invite is invalid or expired")
            inviter_id = invite["inviter_id"]
            if inviter_id == requester_id:
                raise FriendConflictError("an invite cannot be redeemed by its creator")
            requester = self._friend_profiles.get(requester_id)
            inviter = self._friend_profiles.get(inviter_id)
            if (
                requester is None
                or inviter is None
                or requester["disabled_at"] is not None
                or inviter["disabled_at"] is not None
            ):
                raise FriendNotFoundError("invite is invalid or expired")
            if (inviter_id, requester_id) in self._friend_blocks or (
                requester_id,
                inviter_id,
            ) in self._friend_blocks:
                raise FriendNotFoundError("invite is invalid or expired")
            pair = _friend_pair(inviter_id, requester_id)
            if pair in self._friendships:
                raise FriendConflictError("profiles are already friends")
            if any(
                request["status"] == "pending"
                and _friend_pair(request["inviter_id"], request["requester_id"]) == pair
                for request in self._friend_requests.values()
            ):
                raise FriendConflictError("a friend request is already pending")
            invite["redeemed_at"] = now
            invite["redeemed_by"] = requester_id
            request = {
                "request_id": request_id,
                "invite_id": invite["invite_id"],
                "inviter_id": inviter_id,
                "requester_id": requester_id,
                "status": "pending",
                "created_at": now,
                "decided_at": None,
            }
            self._friend_requests[request_id] = request
            return {
                **request,
                "recipient": {
                    "profile_id": inviter_id,
                    "display_name": inviter["display_name"],
                },
            }

    async def join_friend_invite(
        self,
        code_hash: str,
        profile_id: str,
        enrollment_id: str,
        display_name: str,
        installation_id: str,
        daily_device_id: str,
        token_hash: str,
        request_id: str,
        now: datetime,
    ) -> dict[str, Any]:
        if not _friend_device_matches_installation(daily_device_id, installation_id):
            raise FriendConflictError(
                "daily device must be scoped to the profile installation"
            )
        async with self._lock:
            invite = next(
                (
                    row
                    for row in self._friend_invites.values()
                    if row["code_hash"] == code_hash
                ),
                None,
            )
            if invite is None:
                raise FriendNotFoundError("invite is invalid or expired")
            if invite["redeemed_at"] is not None:
                existing_profile = self._friend_profiles.get(
                    invite["redeemed_by"] or ""
                )
                existing_request = next(
                    (
                        row
                        for row in self._friend_requests.values()
                        if row["invite_id"] == invite["invite_id"]
                        and row["requester_id"] == invite["redeemed_by"]
                    ),
                    None,
                )
                inviter = self._friend_profiles.get(invite["inviter_id"])
                matches = (
                    existing_profile is not None
                    and existing_profile["disabled_at"] is None
                    and existing_request is not None
                    and inviter is not None
                    and existing_profile["enrollment_id"] == enrollment_id
                    and existing_profile["installation_id"] == installation_id
                    and existing_profile["daily_device_id"] == daily_device_id
                    and existing_profile["display_name"] == display_name
                    and self._friend_tokens.get(token_hash)
                    == existing_profile["profile_id"]
                )
                if not matches:
                    raise FriendConflictError(
                        "invite was consumed by a different enrollment"
                    )
                return {
                    "profile": dict(existing_profile),
                    "request": dict(existing_request),
                    "inviter_display_name": inviter["display_name"],
                    "idempotent_replay": True,
                }
            if invite["revoked_at"] is not None or invite["expires_at"] <= now:
                raise FriendNotFoundError("invite is invalid or expired")
            inviter = self._friend_profiles.get(invite["inviter_id"])
            if inviter is None or inviter["disabled_at"] is not None:
                raise FriendNotFoundError("invite is invalid or expired")
            if any(
                profile["installation_id"] == installation_id
                and profile["disabled_at"] is None
                for profile in self._friend_profiles.values()
            ):
                raise FriendConflictError(
                    "this installation already has a friend profile"
                )
            if token_hash in self._friend_tokens:
                raise FriendConflictError("friend credential already exists")
            if any(
                profile["enrollment_id"] == enrollment_id
                for profile in self._friend_profiles.values()
            ):
                raise FriendConflictError("friend enrollment already exists")

            profile = {
                "profile_id": profile_id,
                "enrollment_id": enrollment_id,
                "display_name": display_name,
                "installation_id": installation_id,
                "daily_device_id": daily_device_id,
                "created_at": now,
                "updated_at": now,
                "disabled_at": None,
            }
            request = {
                "request_id": request_id,
                "invite_id": invite["invite_id"],
                "inviter_id": invite["inviter_id"],
                "requester_id": profile_id,
                "status": "pending",
                "created_at": now,
                "decided_at": None,
            }
            # These writes share the repository lock: an invalid/raced invite
            # cannot leave behind a profile without its pending request.
            self._friend_profiles[profile_id] = profile
            self._friend_tokens[token_hash] = profile_id
            invite["redeemed_at"] = now
            invite["redeemed_by"] = profile_id
            self._friend_requests[request_id] = request
            return {
                "profile": dict(profile),
                "request": dict(request),
                "inviter_display_name": inviter["display_name"],
                "idempotent_replay": False,
            }

    async def list_friend_requests(self, profile_id: str) -> list[dict[str, Any]]:
        async with self._lock:
            values: list[dict[str, Any]] = []
            for request in self._friend_requests.values():
                if request["status"] != "pending":
                    continue
                if profile_id not in (
                    request["inviter_id"],
                    request["requester_id"],
                ):
                    continue
                other_id = (
                    request["requester_id"]
                    if request["inviter_id"] == profile_id
                    else request["inviter_id"]
                )
                other = self._friend_profiles.get(other_id)
                if other is None:
                    continue
                values.append(
                    {
                        **request,
                        "direction": (
                            "incoming"
                            if request["inviter_id"] == profile_id
                            else "outgoing"
                        ),
                        "profile": {
                            "profile_id": other_id,
                            "display_name": other["display_name"],
                        },
                    }
                )
            return sorted(values, key=lambda row: row["created_at"], reverse=True)

    async def decide_friend_request(
        self,
        profile_id: str,
        request_id: str,
        decision: str,
        now: datetime,
    ) -> dict[str, Any]:
        async with self._lock:
            request = self._friend_requests.get(request_id)
            if request is None or request["inviter_id"] != profile_id:
                raise FriendNotFoundError("incoming friend request was not found")
            if request["status"] != "pending":
                raise FriendConflictError("friend request is no longer pending")
            requester_id = request["requester_id"]
            if (profile_id, requester_id) in self._friend_blocks or (
                requester_id,
                profile_id,
            ) in self._friend_blocks:
                raise FriendConflictError("friend request can no longer be accepted")
            request["status"] = "accepted" if decision == "accept" else "declined"
            request["decided_at"] = now
            if decision == "accept":
                pair = _friend_pair(profile_id, requester_id)
                self._friendships[pair] = {
                    "profile_a": pair[0],
                    "profile_b": pair[1],
                    "created_at": now,
                }
                defaults = FriendVisibility().model_dump()
                self._friend_visibility[(profile_id, requester_id)] = dict(defaults)
                self._friend_visibility[(requester_id, profile_id)] = dict(defaults)
            return dict(request)

    async def list_friends(self, profile_id: str) -> list[dict[str, Any]]:
        async with self._lock:
            friends: list[dict[str, Any]] = []
            for pair, friendship in self._friendships.items():
                if profile_id not in pair:
                    continue
                friend_id = pair[1] if pair[0] == profile_id else pair[0]
                profile = self._friend_profiles.get(friend_id)
                if profile is None or profile["disabled_at"] is not None:
                    continue
                friends.append(
                    {
                        "profile_id": friend_id,
                        "display_name": profile["display_name"],
                        "friends_since": friendship["created_at"],
                        "sharing": dict(
                            self._friend_visibility[(profile_id, friend_id)]
                        ),
                        "shared_with_me": dict(
                            self._friend_visibility[(friend_id, profile_id)]
                        ),
                    }
                )
            return sorted(
                friends,
                key=lambda row: (row["display_name"].casefold(), row["profile_id"]),
            )

    async def update_friend_visibility(
        self,
        owner_id: str,
        viewer_id: str,
        changes: dict[str, bool],
    ) -> dict[str, bool]:
        async with self._lock:
            if _friend_pair(owner_id, viewer_id) not in self._friendships:
                raise FriendNotFoundError("friendship was not found")
            visibility = self._friend_visibility[(owner_id, viewer_id)]
            visibility.update(changes)
            return dict(visibility)

    async def remove_friend(self, profile_id: str, friend_id: str) -> None:
        async with self._lock:
            pair = _friend_pair(profile_id, friend_id)
            if pair not in self._friendships:
                raise FriendNotFoundError("friendship was not found")
            del self._friendships[pair]
            self._friend_visibility.pop((profile_id, friend_id), None)
            self._friend_visibility.pop((friend_id, profile_id), None)

    async def block_friend(self, profile_id: str, blocked_id: str) -> None:
        if profile_id == blocked_id:
            raise FriendConflictError("a profile cannot block itself")
        async with self._lock:
            blocked = self._friend_profiles.get(blocked_id)
            if blocked is None or blocked["disabled_at"] is not None:
                raise FriendNotFoundError("profile was not found")
            self._friend_blocks.add((profile_id, blocked_id))
            pair = _friend_pair(profile_id, blocked_id)
            self._friendships.pop(pair, None)
            self._friend_visibility.pop((profile_id, blocked_id), None)
            self._friend_visibility.pop((blocked_id, profile_id), None)
            now = datetime.now(UTC)
            for request in self._friend_requests.values():
                if (
                    request["status"] == "pending"
                    and _friend_pair(request["inviter_id"], request["requester_id"])
                    == pair
                ):
                    request["status"] = "cancelled"
                    request["decided_at"] = now

    async def unblock_friend(self, profile_id: str, blocked_id: str) -> None:
        async with self._lock:
            key = (profile_id, blocked_id)
            if key not in self._friend_blocks:
                raise FriendNotFoundError("block was not found")
            self._friend_blocks.remove(key)

    async def friend_feed(
        self, profile_id: str, start: date, end: date
    ) -> list[dict[str, Any]]:
        async with self._lock:
            records: list[dict[str, Any]] = []
            for pair, friendship in self._friendships.items():
                if profile_id not in pair:
                    continue
                owner_id = pair[1] if pair[0] == profile_id else pair[0]
                owner = self._friend_profiles.get(owner_id)
                if (
                    owner is None
                    or owner["disabled_at"] is not None
                    or owner["daily_device_id"] is None
                ):
                    continue
                visibility = self._friend_visibility[(owner_id, profile_id)]
                grouped: dict[date, dict[str, float]] = {}
                for (device_id, day, metric), row in self._daily.items():
                    if (
                        device_id == owner["daily_device_id"]
                        and start <= day <= end
                        and day >= friendship["created_at"].date()
                        and metric in FRIEND_DAILY_METRICS
                        and row["source_metadata"].get("namespace") == "noop_computed"
                    ):
                        grouped.setdefault(day, {})[metric] = row["value"]
                for day, metrics in grouped.items():
                    summary = _project_friend_metrics(metrics, visibility)
                    if summary:
                        records.append(
                            {
                                "profile_id": owner_id,
                                "display_name": owner["display_name"],
                                "day": day,
                                "summary": summary,
                            }
                        )
            return sorted(
                records,
                key=lambda row: (
                    row["day"],
                    row["display_name"].casefold(),
                    row["profile_id"],
                ),
                reverse=True,
            )


def _json_dump(value: Any) -> str:
    return json.dumps(
        value,
        allow_nan=False,
        ensure_ascii=False,
        separators=(",", ":"),
        default=str,
    )


def _sample_key(metric: str, value: float, metadata: dict[str, Any]) -> str:
    if metric != "rr":
        return ""
    # Local RR identity is (whole-second timestamp, interval value, duplicate
    # sequence). `seq` alone is not unique because 810ms and 825ms can both be
    # sequence zero in the same second.
    return f"{format(value, '.17g')}:{metadata.get('seq', '0')}"


def _decoded_row(record: Any) -> dict[str, Any]:
    row = dict(record)
    for key in (
        "metadata",
        "source_metadata",
        "stages",
        "metrics",
        "value",
        "value_json",
        "counts",
    ):
        value = row.get(key)
        if isinstance(value, str):
            try:
                row[key] = json.loads(value)
            except json.JSONDecodeError:
                pass
    return row


def _command_count(status: str) -> int:
    try:
        return int(status.rsplit(" ", 1)[-1])
    except (ValueError, IndexError):
        return 0


class PostgresRepository:
    """TimescaleDB/PostgreSQL implementation used by the Docker service.

    ``asyncpg`` is imported lazily so model and API tests can run with the
    in-memory repository and no database client installed.
    """

    def __init__(
        self,
        database_url: str,
        *,
        pool_min_size: int = 1,
        pool_max_size: int = 8,
    ) -> None:
        self.database_url = database_url
        self.pool_min_size = pool_min_size
        self.pool_max_size = pool_max_size
        self._pool: Any = None

    async def startup(self) -> None:
        try:
            import asyncpg
        except ImportError as exc:  # pragma: no cover - deployment dependency
            raise RuntimeError("asyncpg is required for PostgreSQL storage") from exc
        self._pool = await asyncpg.create_pool(
            dsn=self.database_url,
            min_size=self.pool_min_size,
            max_size=self.pool_max_size,
            command_timeout=120,
        )
        try:
            async with self._pool.acquire() as connection:
                await self._run_migrations(connection)
        except Exception:
            await self._pool.close()
            self._pool = None
            raise

    async def _run_migrations(self, connection: Any) -> None:
        """Apply immutable SQL migrations once, in lexical version order."""

        await connection.execute(
            """
            CREATE TABLE IF NOT EXISTS noop_schema_migrations (
                version text PRIMARY KEY,
                checksum char(64) NOT NULL,
                applied_at timestamptz NOT NULL DEFAULT now()
            )
            """
        )
        await connection.execute(
            "SELECT pg_advisory_lock(hashtext('noop_schema_migrations'))"
        )
        try:
            migration_dir = Path(__file__).resolve().parent.parent / "migrations"
            migrations = sorted(migration_dir.glob("*.sql"))
            if not migrations:
                raise RuntimeError("no database migrations were found")
            for path in migrations:
                body = path.read_text(encoding="utf-8")
                checksum = hashlib.sha256(body.encode("utf-8")).hexdigest()
                applied = await connection.fetchrow(
                    """
                    SELECT checksum
                    FROM noop_schema_migrations
                    WHERE version = $1
                    """,
                    path.name,
                )
                if applied is not None:
                    if applied["checksum"].strip() != checksum:
                        raise RuntimeError(
                            f"applied migration {path.name} has changed; "
                            "create a new migration instead"
                        )
                    continue
                async with connection.transaction():
                    await connection.execute(body)
                    await connection.execute(
                        """
                        INSERT INTO noop_schema_migrations (version, checksum)
                        VALUES ($1, $2)
                        """,
                        path.name,
                        checksum,
                    )
        finally:
            await connection.execute(
                "SELECT pg_advisory_unlock(hashtext('noop_schema_migrations'))"
            )

    async def shutdown(self) -> None:
        if self._pool is not None:
            await self._pool.close()
            self._pool = None

    def _require_pool(self) -> Any:
        if self._pool is None:
            raise RuntimeError("repository has not started")
        return self._pool

    async def sync(
        self,
        payload: SyncPayload,
        payload_hash: str,
        social_profile_id: str | None = None,
    ) -> SyncResult:
        pool = self._require_pool()
        batch_id = str(payload.batch_id)
        device_id = payload.source.device_id
        counts = SyncCounts(
            metric_samples=sum(
                len(samples) for _, samples in payload.streams.numeric_items()
            ),
            events=len(payload.streams.events),
            daily_metrics=sum(len(values) for values in payload.daily_metrics.values()),
            sleep_sessions=len(payload.sleep_sessions),
            workouts=len(payload.workouts),
            journal_entries=len(payload.journal),
        )
        async with pool.acquire() as connection:
            async with connection.transaction():
                # Serialise concurrent retries of the same UUID before checking
                # its content hash.
                await connection.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    batch_id,
                )
                await connection.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    f"noop-device:{device_id}",
                )
                if social_profile_id is not None:
                    active_profile = await connection.fetchrow(
                        """
                        SELECT profile_id
                        FROM friend_profiles
                        WHERE profile_id = $1
                          AND daily_device_id = $2
                          AND disabled_at IS NULL
                        FOR SHARE
                        """,
                        UUID(social_profile_id),
                        device_id,
                    )
                    if active_profile is None:
                        raise FriendForbiddenError(
                            "member profile is no longer active for this producer"
                        )
                existing = await connection.fetchrow(
                    "SELECT payload_hash FROM sync_batches WHERE batch_id = $1",
                    payload.batch_id,
                )
                if existing is not None:
                    if existing["payload_hash"] != payload_hash:
                        raise SyncConflictError(
                            "batch_id was already used for different content"
                        )
                    return SyncResult(
                        batch_id=payload.batch_id,
                        duplicate=True,
                        counts=SyncCounts(),
                    )

                device = payload.source.device
                await connection.execute(
                    """
                    INSERT INTO devices (
                        device_id, display_name, model, firmware_version,
                        hardware_revision, platform, app_version, last_seen, metadata
                    ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9::jsonb)
                    ON CONFLICT (device_id) DO UPDATE SET
                        display_name = COALESCE(EXCLUDED.display_name, devices.display_name),
                        model = COALESCE(EXCLUDED.model, devices.model),
                        firmware_version = COALESCE(
                            EXCLUDED.firmware_version, devices.firmware_version
                        ),
                        hardware_revision = COALESCE(
                            EXCLUDED.hardware_revision, devices.hardware_revision
                        ),
                        platform = COALESCE(EXCLUDED.platform, devices.platform),
                        app_version = COALESCE(EXCLUDED.app_version, devices.app_version),
                        last_seen = GREATEST(EXCLUDED.last_seen, devices.last_seen),
                        metadata = devices.metadata || EXCLUDED.metadata,
                        updated_at = now()
                    """,
                    device_id,
                    device.display_name,
                    device.model,
                    device.firmware_version,
                    device.hardware_revision,
                    payload.source.platform,
                    payload.source.app_version,
                    payload.source.sent_at,
                    _json_dump(payload.source.metadata),
                )

                # The receipt is inserted before its rows so each row can retain
                # an FK-backed producer/batch identity. The surrounding
                # transaction rolls the receipt back if any row fails.
                await connection.execute(
                    """
                    INSERT INTO sync_batches (
                        batch_id, device_id, payload_hash, counts, sent_at
                    ) VALUES ($1,$2,$3,$4::jsonb,$5)
                    """,
                    payload.batch_id,
                    device_id,
                    payload_hash,
                    _json_dump(counts.model_dump()),
                    payload.source.sent_at,
                )

                source_metadata = _json_dump(payload.source.metadata)
                metric_rows: list[tuple[Any, ...]] = []
                for metric, samples in payload.streams.numeric_items():
                    for sample in samples:
                        unit, measurement_class, interpretable = sample_semantics(
                            metric, sample
                        )
                        sample_key = _sample_key(metric, sample.value, sample.metadata)
                        metric_rows.append(
                            (
                                device_id,
                                metric,
                                sample.recorded_at,
                                sample_key,
                                sample.value,
                                unit,
                                measurement_class,
                                interpretable,
                                sample.quality,
                                _json_dump(sample.metadata),
                                payload.batch_id,
                                payload.source.platform,
                                source_metadata,
                            )
                        )
                if metric_rows:
                    await connection.executemany(
                        """
                        INSERT INTO metric_samples (
                            device_id, metric, recorded_at, sample_key, value,
                            unit, measurement_class,
                            clinical_interpretation_allowed, quality, metadata,
                            sync_batch_id, source_platform, source_metadata
                        ) VALUES (
                            $1,$2,$3,$4,$5,$6,$7,$8,$9,$10::jsonb,
                            $11,$12,$13::jsonb
                        )
                        ON CONFLICT (
                            device_id, metric, recorded_at, sample_key
                        ) DO UPDATE SET
                            value = EXCLUDED.value,
                            unit = EXCLUDED.unit,
                            measurement_class = EXCLUDED.measurement_class,
                            clinical_interpretation_allowed =
                                EXCLUDED.clinical_interpretation_allowed,
                            quality = EXCLUDED.quality,
                            metadata = EXCLUDED.metadata,
                            sync_batch_id = EXCLUDED.sync_batch_id,
                            source_platform = EXCLUDED.source_platform,
                            source_metadata = EXCLUDED.source_metadata,
                            received_at = now()
                        """,
                        metric_rows,
                    )

                event_rows = [
                    (
                        device_id,
                        event.event_id,
                        event.recorded_at,
                        event.kind,
                        _json_dump(event.value),
                        _json_dump(event.metadata),
                        payload.batch_id,
                        payload.source.platform,
                        source_metadata,
                    )
                    for event in payload.streams.events
                ]
                if event_rows:
                    await connection.executemany(
                        """
                        INSERT INTO events (
                            device_id, event_id, recorded_at, kind, value_json, metadata,
                            sync_batch_id, source_platform, source_metadata
                        ) VALUES (
                            $1,$2,$3,$4,$5::jsonb,$6::jsonb,$7,$8,$9::jsonb
                        )
                        ON CONFLICT (device_id, event_id) DO UPDATE SET
                            recorded_at = EXCLUDED.recorded_at,
                            kind = EXCLUDED.kind,
                            value_json = EXCLUDED.value_json,
                            metadata = EXCLUDED.metadata,
                            sync_batch_id = EXCLUDED.sync_batch_id,
                            source_platform = EXCLUDED.source_platform,
                            source_metadata = EXCLUDED.source_metadata,
                            received_at = now()
                        """,
                        event_rows,
                    )

                daily_rows = [
                    (
                        device_id,
                        day,
                        metric,
                        value,
                        payload.batch_id,
                        payload.source.platform,
                        source_metadata,
                    )
                    for day, metrics in payload.daily_metrics.items()
                    for metric, value in metrics.items()
                ]
                if social_profile_id is not None and payload.daily_metrics:
                    await connection.executemany(
                        """
                        DELETE FROM daily_metrics
                        WHERE device_id = $1
                          AND day = $2
                          AND metric = ANY($3::text[])
                          AND NOT (metric = ANY($4::text[]))
                        """,
                        [
                            (
                                device_id,
                                day,
                                sorted(FRIEND_DAILY_METRICS),
                                sorted(metrics),
                            )
                            for day, metrics in payload.daily_metrics.items()
                        ],
                    )
                if daily_rows:
                    await connection.executemany(
                        """
                        INSERT INTO daily_metrics (
                            device_id, day, metric, value, sync_batch_id,
                            source_platform, source_metadata
                        ) VALUES ($1,$2,$3,$4,$5,$6,$7::jsonb)
                        ON CONFLICT (device_id, day, metric) DO UPDATE SET
                            value = EXCLUDED.value,
                            sync_batch_id = EXCLUDED.sync_batch_id,
                            source_platform = EXCLUDED.source_platform,
                            source_metadata = EXCLUDED.source_metadata,
                            received_at = now()
                        """,
                        daily_rows,
                    )

                sleep_rows = [
                    (
                        device_id,
                        sleep.session_id,
                        sleep.start_ts,
                        sleep.end_ts,
                        sleep.efficiency,
                        sleep.resting_hr,
                        sleep.avg_hrv,
                        _json_dump(sleep.stages),
                        _json_dump(sleep.metadata),
                        payload.batch_id,
                        payload.source.platform,
                        source_metadata,
                    )
                    for sleep in payload.sleep_sessions
                ]
                if sleep_rows:
                    await connection.executemany(
                        """
                        INSERT INTO sleep_sessions (
                            device_id, session_id, start_ts, end_ts, efficiency,
                            resting_hr, avg_hrv, stages, metadata, sync_batch_id,
                            source_platform, source_metadata
                        ) VALUES (
                            $1,$2,$3,$4,$5,$6,$7,$8::jsonb,$9::jsonb,
                            $10,$11,$12::jsonb
                        )
                        ON CONFLICT (device_id, session_id) DO UPDATE SET
                            start_ts = EXCLUDED.start_ts,
                            end_ts = EXCLUDED.end_ts,
                            efficiency = EXCLUDED.efficiency,
                            resting_hr = EXCLUDED.resting_hr,
                            avg_hrv = EXCLUDED.avg_hrv,
                            stages = EXCLUDED.stages,
                            metadata = EXCLUDED.metadata,
                            sync_batch_id = EXCLUDED.sync_batch_id,
                            source_platform = EXCLUDED.source_platform,
                            source_metadata = EXCLUDED.source_metadata,
                            received_at = now()
                        """,
                        sleep_rows,
                    )

                workout_rows = [
                    (
                        device_id,
                        workout.workout_id,
                        workout.start_ts,
                        workout.end_ts,
                        workout.sport,
                        workout.source,
                        _json_dump(workout.metrics),
                        _json_dump(workout.metadata),
                        payload.batch_id,
                        payload.source.platform,
                        source_metadata,
                    )
                    for workout in payload.workouts
                ]
                if workout_rows:
                    await connection.executemany(
                        """
                        INSERT INTO workouts (
                            device_id, workout_id, start_ts, end_ts, sport,
                            source, metrics, metadata, sync_batch_id,
                            source_platform, source_metadata
                        ) VALUES (
                            $1,$2,$3,$4,$5,$6,$7::jsonb,$8::jsonb,
                            $9,$10,$11::jsonb
                        )
                        ON CONFLICT (device_id, workout_id) DO UPDATE SET
                            start_ts = EXCLUDED.start_ts,
                            end_ts = EXCLUDED.end_ts,
                            sport = EXCLUDED.sport,
                            source = EXCLUDED.source,
                            metrics = EXCLUDED.metrics,
                            metadata = EXCLUDED.metadata,
                            sync_batch_id = EXCLUDED.sync_batch_id,
                            source_platform = EXCLUDED.source_platform,
                            source_metadata = EXCLUDED.source_metadata,
                            received_at = now()
                        """,
                        workout_rows,
                    )

                journal_rows = [
                    (
                        device_id,
                        entry.day,
                        entry.question,
                        entry.question.casefold(),
                        entry.answered_yes,
                        entry.notes,
                        entry.numeric_value,
                        payload.batch_id,
                        payload.source.platform,
                        source_metadata,
                    )
                    for entry in payload.journal
                ]
                if journal_rows:
                    await connection.executemany(
                        """
                        INSERT INTO journal_entries (
                            device_id, day, question, question_key, answered_yes,
                            notes, numeric_value, sync_batch_id, source_platform,
                            source_metadata
                        ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10::jsonb)
                        ON CONFLICT (device_id, day, question_key) DO UPDATE SET
                            question = EXCLUDED.question,
                            answered_yes = EXCLUDED.answered_yes,
                            notes = EXCLUDED.notes,
                            numeric_value = EXCLUDED.numeric_value,
                            sync_batch_id = EXCLUDED.sync_batch_id,
                            source_platform = EXCLUDED.source_platform,
                            source_metadata = EXCLUDED.source_metadata,
                            received_at = now()
                        """,
                        journal_rows,
                    )
        return SyncResult(
            batch_id=payload.batch_id,
            duplicate=False,
            counts=counts,
        )

    async def list_devices(self) -> list[dict[str, Any]]:
        pool = self._require_pool()
        rows = await pool.fetch(
            """
            SELECT device_id, display_name, model, firmware_version,
                   hardware_revision, platform, app_version, last_seen, metadata
            FROM devices
            ORDER BY last_seen DESC, device_id
            """
        )
        return [_decoded_row(row) for row in rows]

    async def events(
        self,
        device_id: str,
        start: datetime,
        end: datetime,
        limit: int,
    ) -> list[dict[str, Any]]:
        pool = self._require_pool()
        rows = await pool.fetch(
            """
            SELECT event_id, recorded_at, kind, value_json AS value, metadata,
                   sync_batch_id, source_platform, source_metadata
            FROM events
            WHERE device_id = $1
              AND recorded_at >= $2 AND recorded_at < $3
            ORDER BY recorded_at, event_id
            LIMIT $4
            """,
            device_id,
            start,
            end,
            limit,
        )
        return [_decoded_row(row) for row in rows]

    async def latest_metrics(
        self, device_id: str, metrics: list[str] | None
    ) -> dict[str, dict[str, Any]]:
        pool = self._require_pool()
        rows = await pool.fetch(
            """
            SELECT DISTINCT ON (metric)
                   metric, recorded_at, value, unit, measurement_class,
                   clinical_interpretation_allowed, quality, metadata,
                   sync_batch_id, source_platform, source_metadata
            FROM metric_samples
            WHERE device_id = $1
              AND ($2::text[] IS NULL OR metric = ANY($2::text[]))
            ORDER BY metric, recorded_at DESC, sample_key DESC
            """,
            device_id,
            metrics,
        )
        return {
            row["metric"]: {
                key: value
                for key, value in _decoded_row(row).items()
                if key != "metric"
            }
            for row in rows
        }

    async def metric_range(
        self,
        device_id: str,
        metric: str,
        start: datetime,
        end: datetime,
        limit: int,
    ) -> list[dict[str, Any]]:
        pool = self._require_pool()
        rows = await pool.fetch(
            """
            SELECT recorded_at, value, unit, measurement_class,
                   clinical_interpretation_allowed, quality, metadata,
                   sync_batch_id, source_platform, source_metadata
            FROM metric_samples
            WHERE device_id = $1 AND metric = $2
              AND recorded_at >= $3 AND recorded_at < $4
            ORDER BY recorded_at,
                     CASE WHEN metric = 'rr'
                          THEN (metadata ->> 'seq')::bigint
                          ELSE 0
                     END,
                     value,
                     sample_key
            LIMIT $5
            """,
            device_id,
            metric,
            start,
            end,
            limit,
        )
        return [_decoded_row(row) for row in rows]

    async def daily_metrics(
        self, device_id: str, start: date, end: date
    ) -> list[dict[str, Any]]:
        pool = self._require_pool()
        rows = await pool.fetch(
            """
            SELECT day, metric, value, sync_batch_id, source_platform,
                   source_metadata
            FROM daily_metrics
            WHERE device_id = $1 AND day >= $2 AND day <= $3
            ORDER BY day, metric
            """,
            device_id,
            start,
            end,
        )
        grouped: dict[date, dict[str, Any]] = {}
        for row in rows:
            decoded = _decoded_row(row)
            day_row = grouped.setdefault(
                decoded["day"], {"metrics": {}, "provenance": {}}
            )
            metric = decoded["metric"]
            day_row["metrics"][metric] = decoded["value"]
            day_row["provenance"][metric] = {
                key: decoded[key]
                for key in ("sync_batch_id", "source_platform", "source_metadata")
            }
        return [{"day": day, **values} for day, values in grouped.items()]

    async def sleep_sessions(
        self,
        device_id: str,
        start: datetime,
        end: datetime,
        limit: int,
    ) -> list[dict[str, Any]]:
        pool = self._require_pool()
        rows = await pool.fetch(
            """
            SELECT session_id, start_ts, end_ts, efficiency, resting_hr,
                   avg_hrv, stages, metadata, sync_batch_id, source_platform,
                   source_metadata
            FROM sleep_sessions
            WHERE device_id = $1 AND start_ts < $3 AND end_ts > $2
            ORDER BY start_ts DESC
            LIMIT $4
            """,
            device_id,
            start,
            end,
            limit,
        )
        return [_decoded_row(row) for row in rows]

    async def workouts(
        self,
        device_id: str,
        start: datetime,
        end: datetime,
        limit: int,
    ) -> list[dict[str, Any]]:
        pool = self._require_pool()
        rows = await pool.fetch(
            """
            SELECT workout_id, start_ts, end_ts, sport, source, metrics, metadata,
                   sync_batch_id, source_platform, source_metadata
            FROM workouts
            WHERE device_id = $1 AND start_ts < $3 AND end_ts > $2
            ORDER BY start_ts DESC
            LIMIT $4
            """,
            device_id,
            start,
            end,
            limit,
        )
        return [_decoded_row(row) for row in rows]

    async def journal_entries(
        self, device_id: str, start: date, end: date
    ) -> list[dict[str, Any]]:
        pool = self._require_pool()
        rows = await pool.fetch(
            """
            SELECT day, question, answered_yes, notes, numeric_value,
                   sync_batch_id, source_platform, source_metadata
            FROM journal_entries
            WHERE device_id = $1 AND day >= $2 AND day <= $3
            ORDER BY day DESC, question_key
            """,
            device_id,
            start,
            end,
        )
        return [_decoded_row(row) for row in rows]

    async def stats(self) -> dict[str, Any]:
        pool = self._require_pool()
        rows = await pool.fetch(
            """
            SELECT 'devices' AS key, count(*)::bigint AS value FROM devices
            UNION ALL SELECT 'metric_samples', count(*) FROM metric_samples
            UNION ALL SELECT 'events', count(*) FROM events
            UNION ALL SELECT 'daily_metrics', count(*) FROM daily_metrics
            UNION ALL SELECT 'sleep_sessions', count(*) FROM sleep_sessions
            UNION ALL SELECT 'workouts', count(*) FROM workouts
            UNION ALL SELECT 'journal_entries', count(*) FROM journal_entries
            UNION ALL SELECT 'sync_batches', count(*) FROM sync_batches
            """
        )
        latest = await pool.fetchval("SELECT max(received_at) FROM sync_batches")
        result = {row["key"]: row["value"] for row in rows}
        result.update(
            {
                "storage": "timescaledb",
                "latest_sync_at": latest,
            }
        )
        return result

    async def export_device(
        self,
        device_id: str,
        start: datetime | None,
        end: datetime | None,
    ) -> dict[str, Any]:
        pool = self._require_pool()
        async with pool.acquire() as connection:
            device_row = await connection.fetchrow(
                """
                SELECT device_id, display_name, model, firmware_version,
                       hardware_revision, platform, app_version, last_seen, metadata
                FROM devices WHERE device_id = $1
                """,
                device_id,
            )
            metric_rows = await connection.fetch(
                """
                SELECT metric, recorded_at, value, unit, measurement_class,
                       clinical_interpretation_allowed, quality, metadata,
                       sync_batch_id, source_platform, source_metadata
                FROM metric_samples
                WHERE device_id = $1
                  AND ($2::timestamptz IS NULL OR recorded_at >= $2)
                  AND ($3::timestamptz IS NULL OR recorded_at < $3)
                ORDER BY recorded_at, metric,
                         CASE WHEN metric = 'rr'
                              THEN (metadata ->> 'seq')::bigint
                              ELSE 0
                         END,
                         value,
                         sample_key
                """,
                device_id,
                start,
                end,
            )
            event_rows = await connection.fetch(
                """
                SELECT event_id, recorded_at, kind, value_json AS value, metadata,
                       sync_batch_id, source_platform, source_metadata
                FROM events
                WHERE device_id = $1
                  AND ($2::timestamptz IS NULL OR recorded_at >= $2)
                  AND ($3::timestamptz IS NULL OR recorded_at < $3)
                ORDER BY recorded_at, event_id
                """,
                device_id,
                start,
                end,
            )
            daily_rows = await connection.fetch(
                """
                SELECT day, metric, value, sync_batch_id, source_platform,
                       source_metadata
                FROM daily_metrics
                WHERE device_id = $1
                  AND ($2::date IS NULL OR day >= $2::date)
                  AND ($3::date IS NULL OR day < $3::date)
                ORDER BY day, metric
                """,
                device_id,
                start.date() if start else None,
                end.date() if end else None,
            )
            sleep_rows = await connection.fetch(
                """
                SELECT session_id, start_ts, end_ts, efficiency, resting_hr,
                       avg_hrv, stages, metadata, sync_batch_id, source_platform,
                       source_metadata
                FROM sleep_sessions
                WHERE device_id = $1
                  AND ($2::timestamptz IS NULL OR end_ts > $2)
                  AND ($3::timestamptz IS NULL OR start_ts < $3)
                ORDER BY start_ts
                """,
                device_id,
                start,
                end,
            )
            workout_rows = await connection.fetch(
                """
                SELECT workout_id, start_ts, end_ts, sport, source, metrics, metadata,
                       sync_batch_id, source_platform, source_metadata
                FROM workouts
                WHERE device_id = $1
                  AND ($2::timestamptz IS NULL OR end_ts > $2)
                  AND ($3::timestamptz IS NULL OR start_ts < $3)
                ORDER BY start_ts
                """,
                device_id,
                start,
                end,
            )
            journal_rows = await connection.fetch(
                """
                SELECT day, question, answered_yes, notes, numeric_value,
                       sync_batch_id, source_platform, source_metadata
                FROM journal_entries
                WHERE device_id = $1
                  AND ($2::date IS NULL OR day >= $2::date)
                  AND ($3::date IS NULL OR day < $3::date)
                ORDER BY day, question_key
                """,
                device_id,
                start.date() if start else None,
                end.date() if end else None,
            )
        return {
            "schema_version": 1,
            "exported_at": datetime.now(UTC),
            "device": _decoded_row(device_row) if device_row else None,
            "metric_samples": [_decoded_row(row) for row in metric_rows],
            "events": [_decoded_row(row) for row in event_rows],
            "daily_metrics": [_decoded_row(row) for row in daily_rows],
            "sleep_sessions": [_decoded_row(row) for row in sleep_rows],
            "workouts": [_decoded_row(row) for row in workout_rows],
            "journal": [_decoded_row(row) for row in journal_rows],
            "notice": (
                "Raw ADC channels are uncalibrated sensor counts, not clinical "
                "SpO2, temperature, or respiration measurements."
            ),
        }

    async def delete_device(self, device_id: str) -> dict[str, int]:
        pool = self._require_pool()
        tables = (
            "metric_samples",
            "events",
            "daily_metrics",
            "sleep_sessions",
            "workouts",
            "journal_entries",
            "sync_batches",
        )
        async with pool.acquire() as connection:
            async with connection.transaction():
                counts: dict[str, int] = {}
                for table in tables:
                    counts[table] = await connection.fetchval(
                        f"SELECT count(*) FROM {table} WHERE device_id = $1",
                        device_id,
                    )
                status = await connection.execute(
                    "DELETE FROM devices WHERE device_id = $1",
                    device_id,
                )
                counts["devices"] = _command_count(status)
        return counts

    async def purge_before(
        self, cutoff: datetime, device_id: str | None = None
    ) -> dict[str, int]:
        pool = self._require_pool()
        predicates = {
            "metric_samples": "recorded_at < $1",
            "events": "recorded_at < $1",
            "daily_metrics": "day < $1::date",
            "sleep_sessions": "end_ts < $1",
            "workouts": "end_ts < $1",
            "journal_entries": "day < $1::date",
            # Removing receipts matters: a client may replay locally retained
            # data after server-side retention has deleted it.
            "sync_batches": "received_at < $1",
        }
        counts: dict[str, int] = {}
        async with pool.acquire() as connection:
            async with connection.transaction():
                for table, time_predicate in predicates.items():
                    cutoff_value: datetime | date = (
                        cutoff.date() if "::date" in time_predicate else cutoff
                    )
                    status = await connection.execute(
                        f"""
                        DELETE FROM {table}
                        WHERE {time_predicate}
                          AND ($2::text IS NULL OR device_id = $2)
                        """,
                        cutoff_value,
                        device_id,
                    )
                    counts[table] = _command_count(status)
        return counts

    async def create_friend_profile(
        self,
        profile_id: str,
        enrollment_id: str,
        display_name: str,
        installation_id: str,
        daily_device_id: str,
        token_hash: str,
    ) -> dict[str, Any]:
        if not _friend_device_matches_installation(daily_device_id, installation_id):
            raise FriendConflictError(
                "daily device must be scoped to the profile installation"
            )
        pool = self._require_pool()
        row = await pool.fetchrow(
            """
            INSERT INTO friend_profiles (
                profile_id, enrollment_id, display_name, installation_id,
                daily_device_id, token_hash
            ) VALUES ($1,$2,$3,$4,$5,$6)
            ON CONFLICT DO NOTHING
            RETURNING profile_id, enrollment_id, display_name, installation_id,
                      daily_device_id, created_at, updated_at, disabled_at
            """,
            UUID(profile_id),
            UUID(enrollment_id),
            display_name,
            installation_id,
            daily_device_id,
            token_hash,
        )
        if row is None:
            raise FriendConflictError("this installation already has a friend profile")
        return _decoded_row(row)

    async def list_friend_profiles(self) -> list[dict[str, Any]]:
        pool = self._require_pool()
        rows = await pool.fetch(
            """
            SELECT profile_id, enrollment_id, display_name, installation_id,
                   daily_device_id, created_at, updated_at, disabled_at
            FROM friend_profiles
            ORDER BY lower(display_name), profile_id
            """
        )
        return [_decoded_row(row) for row in rows]

    async def friend_profile_for_token(self, token_hash: str) -> dict[str, Any] | None:
        pool = self._require_pool()
        row = await pool.fetchrow(
            """
            SELECT profile_id, enrollment_id, display_name, installation_id,
                   daily_device_id, created_at, updated_at, disabled_at
            FROM friend_profiles
            WHERE token_hash = $1 AND disabled_at IS NULL
            """,
            token_hash,
        )
        return _decoded_row(row) if row else None

    async def update_friend_profile(
        self,
        profile_id: str,
        changes: dict[str, Any],
    ) -> dict[str, Any]:
        pool = self._require_pool()
        row = await pool.fetchrow(
            """
            UPDATE friend_profiles
            SET display_name = COALESCE($2, display_name),
                daily_device_id = COALESCE($3, daily_device_id),
                updated_at = now()
            WHERE profile_id = $1
              AND (
                  $3::text IS NULL
                  OR (
                      split_part($3, ':', 1) IN ('ios', 'android', 'macos')
                      AND split_part($3, ':', 2) = installation_id
                      AND split_part($3, ':', 3) <> ''
                  )
              )
            RETURNING profile_id, enrollment_id, display_name, installation_id,
                      daily_device_id, created_at, updated_at, disabled_at
            """,
            UUID(profile_id),
            changes.get("display_name"),
            changes.get("daily_device_id"),
        )
        if row is None:
            raise FriendNotFoundError(
                "friend profile was not found or device scope was invalid"
            )
        return _decoded_row(row)

    async def rotate_friend_token(
        self, profile_id: str, token_hash: str
    ) -> dict[str, Any]:
        pool = self._require_pool()
        row = await pool.fetchrow(
            """
            UPDATE friend_profiles
            SET token_hash = $2, updated_at = now()
            WHERE profile_id = $1 AND disabled_at IS NULL
            RETURNING profile_id, enrollment_id, display_name, installation_id,
                      daily_device_id, created_at, updated_at, disabled_at
            """,
            UUID(profile_id),
            token_hash,
        )
        if row is None:
            raise FriendNotFoundError("friend profile was not found")
        return _decoded_row(row)

    async def disable_friend_profile(self, profile_id: str) -> None:
        pool = self._require_pool()
        profile_uuid = UUID(profile_id)
        async with pool.acquire() as connection:
            async with connection.transaction():
                row = await connection.fetchrow(
                    """
                    UPDATE friend_profiles
                    SET disabled_at = now(), updated_at = now()
                    WHERE profile_id = $1
                    RETURNING profile_id
                    """,
                    profile_uuid,
                )
                if row is None:
                    raise FriendNotFoundError("friend profile was not found")
                await connection.execute(
                    """
                    UPDATE friend_invites
                    SET revoked_at = COALESCE(revoked_at, now())
                    WHERE inviter_id = $1 AND redeemed_at IS NULL
                    """,
                    profile_uuid,
                )
                await connection.execute(
                    """
                    UPDATE friend_requests
                    SET status = 'cancelled', decided_at = now()
                    WHERE status = 'pending'
                      AND (inviter_id = $1 OR requester_id = $1)
                    """,
                    profile_uuid,
                )
                await connection.execute(
                    """
                    DELETE FROM friendships
                    WHERE profile_a = $1 OR profile_b = $1
                    """,
                    profile_uuid,
                )
                await connection.execute(
                    """
                    DELETE FROM friend_visibility
                    WHERE owner_id = $1 OR viewer_id = $1
                    """,
                    profile_uuid,
                )

    async def delete_friend_profile_data(
        self, profile_id: str, daily_device_id: str
    ) -> dict[str, int]:
        pool = self._require_pool()
        profile_uuid = UUID(profile_id)
        async with pool.acquire() as connection:
            async with connection.transaction():
                stored_device = await connection.fetchval(
                    """
                    SELECT daily_device_id
                    FROM friend_profiles
                    WHERE profile_id = $1 AND disabled_at IS NULL
                    """,
                    profile_uuid,
                )
                if stored_device != daily_device_id:
                    raise FriendForbiddenError(
                        "member profile is no longer active for this producer"
                    )
                await connection.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    f"noop-device:{daily_device_id}",
                )
                profile = await connection.fetchrow(
                    """
                    SELECT profile_id
                    FROM friend_profiles
                    WHERE profile_id = $1
                      AND daily_device_id = $2
                      AND disabled_at IS NULL
                    FOR UPDATE
                    """,
                    profile_uuid,
                    daily_device_id,
                )
                if profile is None:
                    raise FriendForbiddenError(
                        "member profile is no longer active for this producer"
                    )

                daily_status = await connection.execute(
                    "DELETE FROM daily_metrics WHERE device_id = $1",
                    daily_device_id,
                )
                batch_status = await connection.execute(
                    "DELETE FROM sync_batches WHERE device_id = $1",
                    daily_device_id,
                )
                profile_status = await connection.execute(
                    "DELETE FROM friend_profiles WHERE profile_id = $1",
                    profile_uuid,
                )
                device_status = await connection.execute(
                    """
                    DELETE FROM devices d
                    WHERE d.device_id = $1
                      AND NOT EXISTS (
                          SELECT 1 FROM metric_samples m
                          WHERE m.device_id = d.device_id
                      )
                      AND NOT EXISTS (
                          SELECT 1 FROM events e
                          WHERE e.device_id = d.device_id
                      )
                      AND NOT EXISTS (
                          SELECT 1 FROM daily_metrics dm
                          WHERE dm.device_id = d.device_id
                      )
                      AND NOT EXISTS (
                          SELECT 1 FROM sleep_sessions s
                          WHERE s.device_id = d.device_id
                      )
                      AND NOT EXISTS (
                          SELECT 1 FROM workouts w
                          WHERE w.device_id = d.device_id
                      )
                      AND NOT EXISTS (
                          SELECT 1 FROM journal_entries j
                          WHERE j.device_id = d.device_id
                      )
                      AND NOT EXISTS (
                          SELECT 1 FROM sync_batches b
                          WHERE b.device_id = d.device_id
                      )
                    """,
                    daily_device_id,
                )
        return {
            "daily_metrics": _command_count(daily_status),
            "sync_batches": _command_count(batch_status),
            "friend_profiles": _command_count(profile_status),
            "devices": _command_count(device_status),
        }

    async def create_friend_invite(
        self,
        invite_id: str,
        inviter_id: str,
        code_hash: str,
        expires_at: datetime,
    ) -> dict[str, Any]:
        pool = self._require_pool()
        row = await pool.fetchrow(
            """
            INSERT INTO friend_invites (
                invite_id, inviter_id, code_hash, expires_at
            )
            SELECT $1, profile_id, $3, $4
            FROM friend_profiles
            WHERE profile_id = $2 AND disabled_at IS NULL
            RETURNING invite_id, inviter_id, created_at, expires_at,
                      redeemed_at, redeemed_by, revoked_at
            """,
            UUID(invite_id),
            UUID(inviter_id),
            code_hash,
            expires_at,
        )
        if row is None:
            raise FriendNotFoundError("friend profile was not found")
        return _decoded_row(row)

    async def revoke_friend_invite(self, profile_id: str, invite_id: str) -> None:
        pool = self._require_pool()
        row = await pool.fetchrow(
            """
            UPDATE friend_invites
            SET revoked_at = now()
            WHERE invite_id = $1 AND inviter_id = $2
              AND redeemed_at IS NULL AND revoked_at IS NULL
            RETURNING invite_id
            """,
            UUID(invite_id),
            UUID(profile_id),
        )
        if row is None:
            raise FriendNotFoundError("active invite was not found")

    async def redeem_friend_invite(
        self,
        code_hash: str,
        requester_id: str,
        request_id: str,
        now: datetime,
    ) -> dict[str, Any]:
        pool = self._require_pool()
        requester_uuid = UUID(requester_id)
        async with pool.acquire() as connection:
            async with connection.transaction():
                invite = await connection.fetchrow(
                    """
                    SELECT invite_id, inviter_id
                    FROM friend_invites
                    WHERE code_hash = $1
                      AND revoked_at IS NULL
                      AND redeemed_at IS NULL
                      AND expires_at > $2
                    FOR UPDATE
                    """,
                    code_hash,
                    now,
                )
                if invite is None:
                    raise FriendNotFoundError("invite is invalid or expired")
                inviter_uuid = invite["inviter_id"]
                if inviter_uuid == requester_uuid:
                    raise FriendConflictError(
                        "an invite cannot be redeemed by its creator"
                    )
                pair = sorted((str(inviter_uuid), requester_id))
                await connection.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    ":".join(pair),
                )
                available = await connection.fetchval(
                    """
                    SELECT count(*) = 2
                    FROM friend_profiles
                    WHERE profile_id = ANY($1::uuid[]) AND disabled_at IS NULL
                    """,
                    [inviter_uuid, requester_uuid],
                )
                blocked = await connection.fetchval(
                    """
                    SELECT EXISTS (
                        SELECT 1 FROM friend_blocks
                        WHERE (blocker_id = $1 AND blocked_id = $2)
                           OR (blocker_id = $2 AND blocked_id = $1)
                    )
                    """,
                    inviter_uuid,
                    requester_uuid,
                )
                if not available or blocked:
                    raise FriendNotFoundError("invite is invalid or expired")
                existing = await connection.fetchval(
                    """
                    SELECT EXISTS (
                        SELECT 1 FROM friendships
                        WHERE profile_a = $1 AND profile_b = $2
                    )
                    """,
                    UUID(pair[0]),
                    UUID(pair[1]),
                )
                pending = await connection.fetchval(
                    """
                    SELECT EXISTS (
                        SELECT 1 FROM friend_requests
                        WHERE status = 'pending'
                          AND LEAST(inviter_id, requester_id) = $1
                          AND GREATEST(inviter_id, requester_id) = $2
                    )
                    """,
                    UUID(pair[0]),
                    UUID(pair[1]),
                )
                if existing:
                    raise FriendConflictError("profiles are already friends")
                if pending:
                    raise FriendConflictError("a friend request is already pending")
                await connection.execute(
                    """
                    UPDATE friend_invites
                    SET redeemed_at = $2, redeemed_by = $3
                    WHERE invite_id = $1
                    """,
                    invite["invite_id"],
                    now,
                    requester_uuid,
                )
                request = await connection.fetchrow(
                    """
                    INSERT INTO friend_requests (
                        request_id, invite_id, inviter_id, requester_id, created_at
                    ) VALUES ($1,$2,$3,$4,$5)
                    RETURNING request_id, invite_id, inviter_id, requester_id,
                              status, created_at, decided_at
                    """,
                    UUID(request_id),
                    invite["invite_id"],
                    inviter_uuid,
                    requester_uuid,
                    now,
                )
                recipient = await connection.fetchrow(
                    """
                    SELECT profile_id, display_name
                    FROM friend_profiles WHERE profile_id = $1
                    """,
                    inviter_uuid,
                )
        return {**_decoded_row(request), "recipient": _decoded_row(recipient)}

    async def join_friend_invite(
        self,
        code_hash: str,
        profile_id: str,
        enrollment_id: str,
        display_name: str,
        installation_id: str,
        daily_device_id: str,
        token_hash: str,
        request_id: str,
        now: datetime,
    ) -> dict[str, Any]:
        if not _friend_device_matches_installation(daily_device_id, installation_id):
            raise FriendConflictError(
                "daily device must be scoped to the profile installation"
            )
        pool = self._require_pool()
        profile_uuid = UUID(profile_id)
        async with pool.acquire() as connection:
            async with connection.transaction():
                invite = await connection.fetchrow(
                    """
                    SELECT i.invite_id, i.inviter_id, i.expires_at,
                           i.redeemed_at, i.redeemed_by, i.revoked_at,
                           p.display_name, p.disabled_at AS inviter_disabled_at
                    FROM friend_invites i
                    JOIN friend_profiles p ON p.profile_id = i.inviter_id
                    WHERE i.code_hash = $1
                    FOR UPDATE OF i
                    """,
                    code_hash,
                )
                if invite is None:
                    raise FriendNotFoundError("invite is invalid or expired")
                if invite["redeemed_at"] is not None:
                    profile = await connection.fetchrow(
                        """
                        SELECT profile_id, enrollment_id, display_name,
                               installation_id, daily_device_id, created_at,
                               updated_at, disabled_at
                        FROM friend_profiles
                        WHERE profile_id = $1
                          AND enrollment_id = $2
                          AND token_hash = $3
                          AND installation_id = $4
                          AND daily_device_id = $5
                          AND display_name = $6
                          AND disabled_at IS NULL
                        """,
                        invite["redeemed_by"],
                        UUID(enrollment_id),
                        token_hash,
                        installation_id,
                        daily_device_id,
                        display_name,
                    )
                    request = await connection.fetchrow(
                        """
                        SELECT request_id, invite_id, inviter_id, requester_id,
                               status, created_at, decided_at
                        FROM friend_requests
                        WHERE invite_id = $1 AND requester_id = $2
                        """,
                        invite["invite_id"],
                        invite["redeemed_by"],
                    )
                    if profile is None or request is None:
                        raise FriendConflictError(
                            "invite was consumed by a different enrollment"
                        )
                    return {
                        "profile": _decoded_row(profile),
                        "request": _decoded_row(request),
                        "inviter_display_name": invite["display_name"],
                        "idempotent_replay": True,
                    }
                if invite["revoked_at"] is not None or invite["expires_at"] <= now:
                    raise FriendNotFoundError("invite is invalid or expired")
                if invite["inviter_disabled_at"] is not None:
                    raise FriendNotFoundError("invite is invalid or expired")
                profile = await connection.fetchrow(
                    """
                    INSERT INTO friend_profiles (
                        profile_id, enrollment_id, display_name, installation_id,
                        daily_device_id, token_hash, created_at, updated_at
                    ) VALUES ($1,$2,$3,$4,$5,$6,$7,$7)
                    ON CONFLICT DO NOTHING
                    RETURNING profile_id, enrollment_id, display_name,
                              installation_id, daily_device_id, created_at,
                              updated_at, disabled_at
                    """,
                    profile_uuid,
                    UUID(enrollment_id),
                    display_name,
                    installation_id,
                    daily_device_id,
                    token_hash,
                    now,
                )
                if profile is None:
                    raise FriendConflictError(
                        "this installation already has a friend profile"
                    )
                await connection.execute(
                    """
                    UPDATE friend_invites
                    SET redeemed_at = $2, redeemed_by = $3
                    WHERE invite_id = $1
                    """,
                    invite["invite_id"],
                    now,
                    profile_uuid,
                )
                request = await connection.fetchrow(
                    """
                    INSERT INTO friend_requests (
                        request_id, invite_id, inviter_id, requester_id, created_at
                    ) VALUES ($1,$2,$3,$4,$5)
                    RETURNING request_id, invite_id, inviter_id, requester_id,
                              status, created_at, decided_at
                    """,
                    UUID(request_id),
                    invite["invite_id"],
                    invite["inviter_id"],
                    profile_uuid,
                    now,
                )
        return {
            "profile": _decoded_row(profile),
            "request": _decoded_row(request),
            "inviter_display_name": invite["display_name"],
            "idempotent_replay": False,
        }

    async def list_friend_requests(self, profile_id: str) -> list[dict[str, Any]]:
        pool = self._require_pool()
        profile_uuid = UUID(profile_id)
        rows = await pool.fetch(
            """
            SELECT r.request_id, r.invite_id, r.inviter_id, r.requester_id,
                   r.status, r.created_at, r.decided_at,
                   CASE WHEN r.inviter_id = $1
                        THEN 'incoming' ELSE 'outgoing' END AS direction,
                   p.profile_id AS other_profile_id,
                   p.display_name AS other_display_name
            FROM friend_requests r
            JOIN friend_profiles p
              ON p.profile_id = CASE WHEN r.inviter_id = $1
                                     THEN r.requester_id ELSE r.inviter_id END
            WHERE (r.inviter_id = $1 OR r.requester_id = $1)
              AND r.status = 'pending'
            ORDER BY r.created_at DESC, r.request_id
            """,
            profile_uuid,
        )
        values: list[dict[str, Any]] = []
        for row in rows:
            decoded = _decoded_row(row)
            values.append(
                {
                    key: decoded[key]
                    for key in (
                        "request_id",
                        "invite_id",
                        "inviter_id",
                        "requester_id",
                        "status",
                        "created_at",
                        "decided_at",
                        "direction",
                    )
                }
                | {
                    "profile": {
                        "profile_id": decoded["other_profile_id"],
                        "display_name": decoded["other_display_name"],
                    }
                }
            )
        return values

    async def decide_friend_request(
        self,
        profile_id: str,
        request_id: str,
        decision: str,
        now: datetime,
    ) -> dict[str, Any]:
        pool = self._require_pool()
        profile_uuid = UUID(profile_id)
        async with pool.acquire() as connection:
            async with connection.transaction():
                candidate = await connection.fetchrow(
                    """
                    SELECT request_id, invite_id, inviter_id, requester_id,
                           status, created_at, decided_at
                    FROM friend_requests
                    WHERE request_id = $1 AND inviter_id = $2
                    """,
                    UUID(request_id),
                    profile_uuid,
                )
                if candidate is None:
                    raise FriendNotFoundError("incoming friend request was not found")
                pair = sorted(
                    (str(candidate["inviter_id"]), str(candidate["requester_id"]))
                )
                await connection.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    ":".join(pair),
                )
                request = await connection.fetchrow(
                    """
                    SELECT request_id, invite_id, inviter_id, requester_id,
                           status, created_at, decided_at
                    FROM friend_requests
                    WHERE request_id = $1 AND inviter_id = $2
                    FOR UPDATE
                    """,
                    UUID(request_id),
                    profile_uuid,
                )
                if request["status"] != "pending":
                    raise FriendConflictError("friend request is no longer pending")
                requester_uuid = request["requester_id"]
                blocked = await connection.fetchval(
                    """
                    SELECT EXISTS (
                        SELECT 1 FROM friend_blocks
                        WHERE (blocker_id = $1 AND blocked_id = $2)
                           OR (blocker_id = $2 AND blocked_id = $1)
                    )
                    """,
                    profile_uuid,
                    requester_uuid,
                )
                if blocked:
                    raise FriendConflictError(
                        "friend request can no longer be accepted"
                    )
                next_status = "accepted" if decision == "accept" else "declined"
                updated = await connection.fetchrow(
                    """
                    UPDATE friend_requests
                    SET status = $2, decided_at = $3
                    WHERE request_id = $1
                    RETURNING request_id, invite_id, inviter_id, requester_id,
                              status, created_at, decided_at
                    """,
                    request["request_id"],
                    next_status,
                    now,
                )
                if decision == "accept":
                    await connection.execute(
                        """
                        INSERT INTO friendships (profile_a, profile_b, created_at)
                        VALUES ($1,$2,$3)
                        ON CONFLICT DO NOTHING
                        """,
                        UUID(pair[0]),
                        UUID(pair[1]),
                        now,
                    )
                    await connection.executemany(
                        """
                        INSERT INTO friend_visibility (owner_id, viewer_id)
                        VALUES ($1,$2)
                        ON CONFLICT DO NOTHING
                        """,
                        [
                            (profile_uuid, requester_uuid),
                            (requester_uuid, profile_uuid),
                        ],
                    )
        return _decoded_row(updated)

    async def list_friends(self, profile_id: str) -> list[dict[str, Any]]:
        pool = self._require_pool()
        profile_uuid = UUID(profile_id)
        rows = await pool.fetch(
            """
            SELECT p.profile_id, p.display_name, f.created_at AS friends_since,
                   mine.share_charge AS my_charge,
                   mine.share_effort AS my_effort,
                   mine.share_rest AS my_rest,
                   mine.share_sleep_duration AS my_sleep_duration,
                   mine.share_hrv AS my_hrv,
                   mine.share_rhr AS my_rhr,
                   theirs.share_charge AS their_charge,
                   theirs.share_effort AS their_effort,
                   theirs.share_rest AS their_rest,
                   theirs.share_sleep_duration AS their_sleep_duration,
                   theirs.share_hrv AS their_hrv,
                   theirs.share_rhr AS their_rhr
            FROM friendships f
            JOIN friend_profiles p
              ON p.profile_id = CASE WHEN f.profile_a = $1
                                     THEN f.profile_b ELSE f.profile_a END
            JOIN friend_visibility mine
              ON mine.owner_id = $1 AND mine.viewer_id = p.profile_id
            JOIN friend_visibility theirs
              ON theirs.owner_id = p.profile_id AND theirs.viewer_id = $1
            WHERE (f.profile_a = $1 OR f.profile_b = $1)
              AND p.disabled_at IS NULL
            ORDER BY lower(p.display_name), p.profile_id
            """,
            profile_uuid,
        )
        friends: list[dict[str, Any]] = []
        fields = FriendVisibility().model_dump()
        for row in rows:
            decoded = _decoded_row(row)
            friends.append(
                {
                    "profile_id": decoded["profile_id"],
                    "display_name": decoded["display_name"],
                    "friends_since": decoded["friends_since"],
                    "sharing": {field: decoded[f"my_{field}"] for field in fields},
                    "shared_with_me": {
                        field: decoded[f"their_{field}"] for field in fields
                    },
                }
            )
        return friends

    async def update_friend_visibility(
        self,
        owner_id: str,
        viewer_id: str,
        changes: dict[str, bool],
    ) -> dict[str, bool]:
        pool = self._require_pool()
        owner_uuid = UUID(owner_id)
        viewer_uuid = UUID(viewer_id)
        async with pool.acquire() as connection:
            async with connection.transaction():
                row = await connection.fetchrow(
                    """
                    SELECT share_charge, share_effort, share_rest,
                           share_sleep_duration, share_hrv, share_rhr
                    FROM friend_visibility
                    WHERE owner_id = $1 AND viewer_id = $2
                    FOR UPDATE
                    """,
                    owner_uuid,
                    viewer_uuid,
                )
                if row is None:
                    raise FriendNotFoundError("friendship was not found")
                current = {
                    field: row[f"share_{field}"]
                    for field in FriendVisibility().model_dump()
                }
                current.update(changes)
                updated = await connection.fetchrow(
                    """
                    UPDATE friend_visibility
                    SET share_charge = $3,
                        share_effort = $4,
                        share_rest = $5,
                        share_sleep_duration = $6,
                        share_hrv = $7,
                        share_rhr = $8,
                        updated_at = now()
                    WHERE owner_id = $1 AND viewer_id = $2
                    RETURNING share_charge, share_effort, share_rest,
                              share_sleep_duration, share_hrv, share_rhr
                    """,
                    owner_uuid,
                    viewer_uuid,
                    current["charge"],
                    current["effort"],
                    current["rest"],
                    current["sleep_duration"],
                    current["hrv"],
                    current["rhr"],
                )
        return {
            field: updated[f"share_{field}"]
            for field in FriendVisibility().model_dump()
        }

    async def remove_friend(self, profile_id: str, friend_id: str) -> None:
        pool = self._require_pool()
        pair = sorted((profile_id, friend_id))
        async with pool.acquire() as connection:
            async with connection.transaction():
                await connection.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    ":".join(pair),
                )
                status = await connection.execute(
                    """
                    DELETE FROM friendships
                    WHERE profile_a = $1 AND profile_b = $2
                    """,
                    UUID(pair[0]),
                    UUID(pair[1]),
                )
                if _command_count(status) == 0:
                    raise FriendNotFoundError("friendship was not found")
                await connection.execute(
                    """
                    DELETE FROM friend_visibility
                    WHERE (owner_id = $1 AND viewer_id = $2)
                       OR (owner_id = $2 AND viewer_id = $1)
                    """,
                    UUID(pair[0]),
                    UUID(pair[1]),
                )

    async def block_friend(self, profile_id: str, blocked_id: str) -> None:
        if profile_id == blocked_id:
            raise FriendConflictError("a profile cannot block itself")
        pool = self._require_pool()
        blocker_uuid = UUID(profile_id)
        blocked_uuid = UUID(blocked_id)
        pair = sorted((profile_id, blocked_id))
        async with pool.acquire() as connection:
            async with connection.transaction():
                await connection.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    ":".join(pair),
                )
                exists = await connection.fetchval(
                    """
                    SELECT EXISTS (
                        SELECT 1 FROM friend_profiles
                        WHERE profile_id = $1 AND disabled_at IS NULL
                    )
                    """,
                    blocked_uuid,
                )
                if not exists:
                    raise FriendNotFoundError("profile was not found")
                await connection.execute(
                    """
                    INSERT INTO friend_blocks (blocker_id, blocked_id)
                    VALUES ($1,$2)
                    ON CONFLICT DO NOTHING
                    """,
                    blocker_uuid,
                    blocked_uuid,
                )
                await connection.execute(
                    """
                    DELETE FROM friendships
                    WHERE profile_a = $1 AND profile_b = $2
                    """,
                    UUID(pair[0]),
                    UUID(pair[1]),
                )
                await connection.execute(
                    """
                    DELETE FROM friend_visibility
                    WHERE (owner_id = $1 AND viewer_id = $2)
                       OR (owner_id = $2 AND viewer_id = $1)
                    """,
                    blocker_uuid,
                    blocked_uuid,
                )
                await connection.execute(
                    """
                    UPDATE friend_requests
                    SET status = 'cancelled', decided_at = now()
                    WHERE status = 'pending'
                      AND LEAST(inviter_id, requester_id) = $1
                      AND GREATEST(inviter_id, requester_id) = $2
                    """,
                    UUID(pair[0]),
                    UUID(pair[1]),
                )

    async def unblock_friend(self, profile_id: str, blocked_id: str) -> None:
        pool = self._require_pool()
        status = await pool.execute(
            """
            DELETE FROM friend_blocks
            WHERE blocker_id = $1 AND blocked_id = $2
            """,
            UUID(profile_id),
            UUID(blocked_id),
        )
        if _command_count(status) == 0:
            raise FriendNotFoundError("block was not found")

    async def friend_feed(
        self, profile_id: str, start: date, end: date
    ) -> list[dict[str, Any]]:
        pool = self._require_pool()
        rows = await pool.fetch(
            """
            SELECT p.profile_id, p.display_name, d.day, d.metric, d.value,
                   v.share_charge, v.share_effort, v.share_rest,
                   v.share_sleep_duration, v.share_hrv, v.share_rhr
            FROM friendships f
            JOIN friend_profiles p
              ON p.profile_id = CASE WHEN f.profile_a = $1
                                     THEN f.profile_b ELSE f.profile_a END
            JOIN friend_visibility v
              ON v.owner_id = p.profile_id AND v.viewer_id = $1
            JOIN daily_metrics d ON d.device_id = p.daily_device_id
            WHERE (f.profile_a = $1 OR f.profile_b = $1)
              AND p.disabled_at IS NULL
              AND d.day >= $2 AND d.day <= $3
              AND d.day >= (f.created_at AT TIME ZONE 'UTC')::date
              AND d.metric = ANY($4::text[])
              AND d.source_metadata ->> 'namespace' = 'noop_computed'
            ORDER BY d.day DESC, lower(p.display_name), p.profile_id, d.metric
            """,
            UUID(profile_id),
            start,
            end,
            sorted(FRIEND_DAILY_METRICS),
        )
        grouped: dict[tuple[str, date], dict[str, Any]] = {}
        for row in rows:
            decoded = _decoded_row(row)
            key = (str(decoded["profile_id"]), decoded["day"])
            record = grouped.setdefault(
                key,
                {
                    "profile_id": decoded["profile_id"],
                    "display_name": decoded["display_name"],
                    "day": decoded["day"],
                    "metrics": {},
                    "visibility": {
                        field: decoded[f"share_{field}"]
                        for field in FriendVisibility().model_dump()
                    },
                },
            )
            record["metrics"][decoded["metric"]] = decoded["value"]
        records = [
            {
                "profile_id": row["profile_id"],
                "display_name": row["display_name"],
                "day": row["day"],
                "summary": _project_friend_metrics(row["metrics"], row["visibility"]),
            }
            for row in grouped.values()
        ]
        return [row for row in records if row["summary"]]
