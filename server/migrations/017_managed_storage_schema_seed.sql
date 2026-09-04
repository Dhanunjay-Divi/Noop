-- Synthetic-staging payload contracts. Production schema revisions require a
-- separately reviewed artifact and migration; active rows are never rewritten.

INSERT INTO managed_chunk_schemas (
    data_class,
    schema_version,
    status,
    content_mode,
    content_type,
    allowed_compressions,
    schema_sha256,
    schema_uri,
    maximum_event_span_seconds,
    maximum_streams,
    effective_at,
    configuration
) VALUES
    (
        'essential_timeseries',
        1,
        'active',
        'server_readable',
        'application/vnd.noop.chunk+json',
        ARRAY['gzip', 'none']::text[],
        'c1fccd5fa6c0ad0cb7d6b16415ca94008edd60c4d2c2e66a9a673e77f5bd2bf7',
        'noop-schema://managed/chunk-json-v1',
        21600,
        32,
        timestamptz '2026-09-03 00:00:00+00',
        '{
            "environment": "synthetic_staging",
            "target_compressed_bytes": 4194304,
            "maximum_target_compressed_bytes": 16777216
        }'::jsonb
    ),
    (
        'raw_ppg',
        1,
        'active',
        'server_readable',
        'application/vnd.noop.chunk+json',
        ARRAY['gzip']::text[],
        'c1fccd5fa6c0ad0cb7d6b16415ca94008edd60c4d2c2e66a9a673e77f5bd2bf7',
        'noop-schema://managed/chunk-json-v1',
        3600,
        8,
        timestamptz '2026-09-03 00:00:00+00',
        '{
            "environment": "synthetic_staging",
            "target_compressed_bytes": 8388608,
            "maximum_target_compressed_bytes": 16777216
        }'::jsonb
    ),
    (
        'raw_motion',
        1,
        'active',
        'server_readable',
        'application/vnd.noop.chunk+json',
        ARRAY['gzip']::text[],
        'c1fccd5fa6c0ad0cb7d6b16415ca94008edd60c4d2c2e66a9a673e77f5bd2bf7',
        'noop-schema://managed/chunk-json-v1',
        3600,
        8,
        timestamptz '2026-09-03 00:00:00+00',
        '{
            "environment": "synthetic_staging",
            "target_compressed_bytes": 8388608,
            "maximum_target_compressed_bytes": 16777216
        }'::jsonb
    ),
    (
        'derived_summaries',
        1,
        'active',
        'server_readable',
        'application/vnd.noop.chunk+json',
        ARRAY['gzip', 'none']::text[],
        'c1fccd5fa6c0ad0cb7d6b16415ca94008edd60c4d2c2e66a9a673e77f5bd2bf7',
        'noop-schema://managed/chunk-json-v1',
        604800,
        16,
        timestamptz '2026-09-03 00:00:00+00',
        '{
            "environment": "synthetic_staging",
            "target_compressed_bytes": 1048576,
            "maximum_target_compressed_bytes": 4194304
        }'::jsonb
    ),
    (
        'encrypted_backup',
        1,
        'active',
        'client_encrypted',
        'application/vnd.noop.backup',
        ARRAY['none']::text[],
        'b077700aa7657a75222d868a2f695316d03d7972de9d95877991df2521820293',
        'noop-schema://managed/opaque-backup-v1',
        604800,
        0,
        timestamptz '2026-09-03 00:00:00+00',
        '{
            "environment": "synthetic_staging",
            "ciphertext_only": true,
            "maximum_target_compressed_bytes": 16777216
        }'::jsonb
    );

INSERT INTO managed_stream_schemas (
    data_class,
    stream_key,
    schema_revision,
    status,
    schema_sha256,
    schema_uri,
    value_schema,
    effective_at
)
SELECT
    stream.data_class,
    stream.stream_key,
    1,
    'active',
    '7cc61565feaba710c24f31ff8fafae842b3a46b8f097dc97a7eac7fd47e28e6e',
    'noop-schema://managed/stream-value-contract-v1',
    jsonb_build_object(
        'encoding',
        'tabular_v1',
        'timestamp_column',
        'event_at_ms',
        'semantic',
        stream.semantic,
        'clinical_measurement',
        false,
        'columns',
        stream.columns
    ),
    timestamptz '2026-09-03 00:00:00+00'
FROM (
    VALUES
        (
            'essential_timeseries',
            'heart_rate',
            'sensor_heart_rate_beats_per_minute',
            '[
                {"name":"event_at_ms","type":"integer"},
                {"name":"bpm","type":"number","minimum":20,"maximum":260},
                {"name":"quality","type":"number","nullable":true,"minimum":0,"maximum":1},
                {"name":"provenance","type":"string","max_length":64}
            ]'::jsonb
        ),
        (
            'essential_timeseries',
            'rr_intervals',
            'beat_interval_milliseconds',
            '[
                {"name":"event_at_ms","type":"integer"},
                {"name":"rr_ms","type":"integer","minimum":200,"maximum":3000},
                {"name":"seq","type":"integer","minimum":0,"maximum":100},
                {"name":"ord","type":"integer","nullable":true,"minimum":0,"maximum":100},
                {"name":"source_channel","type":"integer","nullable":true,"minimum":-1,"maximum":255},
                {"name":"timestamp_suspect","type":"boolean"}
            ]'::jsonb
        ),
        (
            'essential_timeseries',
            'spo2',
            'calibrated_oxygen_saturation_percent',
            '[
                {"name":"event_at_ms","type":"integer"},
                {"name":"percent","type":"number","minimum":50,"maximum":100},
                {"name":"quality","type":"number","nullable":true,"minimum":0,"maximum":1},
                {"name":"provenance","type":"string","max_length":64}
            ]'::jsonb
        ),
        (
            'essential_timeseries',
            'skin_temperature',
            'calibrated_skin_temperature_celsius',
            '[
                {"name":"event_at_ms","type":"integer"},
                {"name":"celsius","type":"number","minimum":-20,"maximum":60},
                {"name":"quality","type":"number","nullable":true,"minimum":0,"maximum":1},
                {"name":"provenance","type":"string","max_length":64}
            ]'::jsonb
        ),
        (
            'essential_timeseries',
            'respiratory_rate',
            'derived_breaths_per_minute',
            '[
                {"name":"event_at_ms","type":"integer"},
                {"name":"breaths_per_minute","type":"number","minimum":1,"maximum":100},
                {"name":"quality","type":"number","nullable":true,"minimum":0,"maximum":1},
                {"name":"provenance","type":"string","max_length":64}
            ]'::jsonb
        ),
        (
            'essential_timeseries',
            'steps',
            'interval_step_count',
            '[
                {"name":"event_at_ms","type":"integer"},
                {"name":"count","type":"integer","minimum":0,"maximum":10000000},
                {"name":"period_seconds","type":"integer","minimum":1,"maximum":86400},
                {"name":"provenance","type":"string","max_length":64}
            ]'::jsonb
        ),
        (
            'essential_timeseries',
            'wear_state',
            'wear_contact_state',
            '[
                {"name":"event_at_ms","type":"integer"},
                {"name":"state","type":"string","enum":["worn","not_worn","unknown"],"max_length":16}
            ]'::jsonb
        ),
        (
            'essential_timeseries',
            'battery',
            'wearable_battery_state',
            '[
                {"name":"event_at_ms","type":"integer"},
                {"name":"percent","type":"number","nullable":true,"minimum":0,"maximum":100},
                {"name":"millivolts","type":"integer","nullable":true,"minimum":0,"maximum":10000},
                {"name":"charging","type":"boolean","nullable":true}
            ]'::jsonb
        ),
        (
            'raw_ppg',
            'ppg_red',
            'uncalibrated_red_optical_adc',
            '[
                {"name":"event_at_ms","type":"integer"},
                {"name":"adc","type":"integer","minimum":-2147483648,"maximum":2147483647}
            ]'::jsonb
        ),
        (
            'raw_ppg',
            'ppg_green',
            'uncalibrated_green_optical_adc',
            '[
                {"name":"event_at_ms","type":"integer"},
                {"name":"adc","type":"integer","minimum":-2147483648,"maximum":2147483647}
            ]'::jsonb
        ),
        (
            'raw_ppg',
            'ppg_infrared',
            'uncalibrated_infrared_optical_adc',
            '[
                {"name":"event_at_ms","type":"integer"},
                {"name":"adc","type":"integer","minimum":-2147483648,"maximum":2147483647}
            ]'::jsonb
        ),
        (
            'raw_ppg',
            'ppg_ambient',
            'uncalibrated_ambient_optical_adc',
            '[
                {"name":"event_at_ms","type":"integer"},
                {"name":"adc","type":"integer","minimum":-2147483648,"maximum":2147483647}
            ]'::jsonb
        ),
        (
            'raw_motion',
            'accelerometer',
            'acceleration_vector_g',
            '[
                {"name":"event_at_ms","type":"integer"},
                {"name":"x_g","type":"number","minimum":-64,"maximum":64},
                {"name":"y_g","type":"number","minimum":-64,"maximum":64},
                {"name":"z_g","type":"number","minimum":-64,"maximum":64}
            ]'::jsonb
        ),
        (
            'raw_motion',
            'gyroscope',
            'angular_velocity_vector_degrees_per_second',
            '[
                {"name":"event_at_ms","type":"integer"},
                {"name":"x_dps","type":"number","minimum":-5000,"maximum":5000},
                {"name":"y_dps","type":"number","minimum":-5000,"maximum":5000},
                {"name":"z_dps","type":"number","minimum":-5000,"maximum":5000}
            ]'::jsonb
        ),
        (
            'derived_summaries',
            'daily_metrics',
            'versioned_daily_metric_bundle',
            '[
                {"name":"event_at_ms","type":"integer"},
                {"name":"day","type":"string","max_length":10},
                {"name":"source_id","type":"string","max_length":128},
                {"name":"payload_json","type":"string","max_length":262144},
                {"name":"updated_at_ms","type":"integer"},
                {"name":"deleted","type":"boolean"}
            ]'::jsonb
        ),
        (
            'derived_summaries',
            'metric_series',
            'versioned_scalar_metric',
            '[
                {"name":"event_at_ms","type":"integer"},
                {"name":"day","type":"string","max_length":10},
                {"name":"metric_key","type":"string","max_length":64},
                {"name":"value","type":"number"},
                {"name":"source_id","type":"string","max_length":128},
                {"name":"updated_at_ms","type":"integer"},
                {"name":"deleted","type":"boolean"}
            ]'::jsonb
        ),
        (
            'derived_summaries',
            'sleep_summary',
            'versioned_sleep_summary',
            '[
                {"name":"event_at_ms","type":"integer"},
                {"name":"record_id","type":"string","max_length":128},
                {"name":"end_at_ms","type":"integer"},
                {"name":"payload_json","type":"string","max_length":262144},
                {"name":"updated_at_ms","type":"integer"},
                {"name":"deleted","type":"boolean"}
            ]'::jsonb
        ),
        (
            'derived_summaries',
            'workout_summary',
            'versioned_workout_summary',
            '[
                {"name":"event_at_ms","type":"integer"},
                {"name":"record_id","type":"string","max_length":128},
                {"name":"end_at_ms","type":"integer"},
                {"name":"payload_json","type":"string","max_length":262144},
                {"name":"updated_at_ms","type":"integer"},
                {"name":"deleted","type":"boolean"}
            ]'::jsonb
        )
) AS stream(data_class, stream_key, semantic, columns);

INSERT INTO managed_chunk_schema_streams (
    data_class,
    chunk_schema_version,
    stream_key,
    stream_schema_revision,
    required
)
SELECT
    data_class,
    1,
    stream_key,
    1,
    false
FROM managed_stream_schemas
WHERE schema_revision = 1
  AND status = 'active'
  AND data_class IN (
      'essential_timeseries',
      'raw_ppg',
      'raw_motion',
      'derived_summaries'
  );
