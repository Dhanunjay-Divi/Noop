-- Migration 017 registered an aspirational calibrated-stream vocabulary before
-- the mobile SQLite mapping was finalized. Migration 020 added the streams the
-- iOS and Android extractors actually emit, but leaving the old registrations
-- attached to chunk schema v1 meant no mobile payload could ever represent a
-- complete authoritative window. Stop accepting those unreachable stream names
-- while preserving their schema rows as retired historical metadata.

DELETE FROM managed_chunk_schema_streams
WHERE chunk_schema_version = 1
  AND (
      (
          data_class = 'essential_timeseries'
          AND stream_key IN (
              'respiratory_rate',
              'skin_temperature',
              'spo2',
              'steps',
              'wear_state'
          )
      )
      OR (
          data_class = 'raw_ppg'
          AND stream_key IN (
              'ppg_ambient',
              'ppg_green',
              'ppg_infrared',
              'ppg_red'
          )
      )
      OR (
          data_class = 'raw_motion'
          AND stream_key IN (
              'accelerometer',
              'gyroscope'
          )
      )
  );

UPDATE managed_stream_schemas
SET status = 'retired',
    retired_at = GREATEST(
        timestamptz '2026-09-03 00:01:00+00',
        effective_at + interval '1 microsecond'
    )
WHERE schema_revision = 1
  AND status = 'active'
  AND (
      (
          data_class = 'essential_timeseries'
          AND stream_key IN (
              'respiratory_rate',
              'skin_temperature',
              'spo2',
              'steps',
              'wear_state'
          )
      )
      OR (
          data_class = 'raw_ppg'
          AND stream_key IN (
              'ppg_ambient',
              'ppg_green',
              'ppg_infrared',
              'ppg_red'
          )
      )
      OR (
          data_class = 'raw_motion'
          AND stream_key IN (
              'accelerometer',
              'gyroscope'
          )
      )
  );
