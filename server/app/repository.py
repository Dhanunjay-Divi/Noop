from __future__ import annotations

import asyncio
import hashlib
import json
from collections import Counter
from datetime import UTC, date, datetime
from pathlib import Path
from typing import Any, Protocol

from app.models import (
    SyncCounts,
    SyncPayload,
    SyncResult,
    sample_semantics,
)


class SyncConflictError(Exception):
    """Raised when a batch identifier is reused for different content."""


class Repository(Protocol):
    async def startup(self) -> None: ...

    async def shutdown(self) -> None: ...

    async def sync(self, payload: SyncPayload, payload_hash: str) -> SyncResult: ...

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

    async def startup(self) -> None:
        return None

    async def shutdown(self) -> None:
        return None

    async def sync(self, payload: SyncPayload, payload_hash: str) -> SyncResult:
        batch_id = str(payload.batch_id)
        async with self._lock:
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

    async def sync(self, payload: SyncPayload, payload_hash: str) -> SyncResult:
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
