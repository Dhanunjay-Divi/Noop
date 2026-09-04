-- Complete the managed payload registry for the decoded tables present on both
-- mobile platforms. Raw ADC values remain explicitly raw and are never
-- relabelled as calibrated SpO2, temperature, or respiratory-rate metrics.

INSERT INTO managed_plan_data_rules (
    plan_code,
    plan_revision,
    data_class,
    cloud_retention_days,
    summary_retention_days,
    recommended_local_raw_days,
    maximum_daily_bytes,
    storage_class,
    server_processing_allowed,
    configuration
) VALUES (
    'noop_plus_staging',
    1,
    'raw_auxiliary',
    14,
    90,
    7,
    67108864,
    'standard',
    true,
    '{
        "description": "uncalibrated auxiliary ADC and device-state streams"
    }'::jsonb
);

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
) VALUES (
    'raw_auxiliary',
    1,
    'active',
    'server_readable',
    'application/vnd.noop.chunk+json',
    ARRAY['gzip']::text[],
    'c1fccd5fa6c0ad0cb7d6b16415ca94008edd60c4d2c2e66a9a673e77f5bd2bf7',
    'noop-schema://managed/chunk-json-v1',
    21600,
    16,
    timestamptz '2026-09-03 00:00:00+00',
    '{
        "environment": "synthetic_staging",
        "target_compressed_bytes": 4194304,
        "maximum_target_compressed_bytes": 16777216,
        "raw_values_are_not_clinical_measurements": true
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
            'derived_heart_rate',
            'on_device_ppg_heart_rate_estimate',
            '[
                {"name":"event_at_ms","type":"integer"},
                {"name":"bpm","type":"number","minimum":20,"maximum":260},
                {"name":"confidence","type":"number","minimum":0,"maximum":1},
                {"name":"algorithm_revision","type":"string","max_length":64}
            ]'::jsonb
        ),
        (
            'essential_timeseries',
            'device_events',
            'wearable_device_event',
            '[
                {"name":"event_at_ms","type":"integer"},
                {"name":"kind","type":"string","max_length":128},
                {"name":"payload_json","type":"string","max_length":262144}
            ]'::jsonb
        ),
        (
            'essential_timeseries',
            'step_counter',
            'cumulative_device_step_counter',
            '[
                {"name":"event_at_ms","type":"integer"},
                {"name":"counter","type":"integer","minimum":0,"maximum":65535},
                {"name":"activity_class","type":"integer","nullable":true,"minimum":0,"maximum":2}
            ]'::jsonb
        ),
        (
            'essential_timeseries',
            'body_measurement',
            'timestamped_body_weight_measurement',
            '[
                {"name":"event_at_ms","type":"integer"},
                {"name":"weight_kg","type":"number","minimum":1,"maximum":1000},
                {"name":"bmi","type":"number","nullable":true,"minimum":1,"maximum":200},
                {"name":"height_cm","type":"number","nullable":true,"minimum":20,"maximum":300},
                {"name":"user_id","type":"integer","minimum":-1,"maximum":255},
                {"name":"source","type":"string","max_length":64}
            ]'::jsonb
        ),
        (
            'raw_auxiliary',
            'skin_temperature_adc',
            'uncalibrated_skin_temperature_adc',
            '[
                {"name":"event_at_ms","type":"integer"},
                {"name":"adc","type":"integer","minimum":-2147483648,"maximum":2147483647}
            ]'::jsonb
        ),
        (
            'raw_auxiliary',
            'respiration_adc',
            'uncalibrated_respiration_adc',
            '[
                {"name":"event_at_ms","type":"integer"},
                {"name":"adc","type":"integer","minimum":-2147483648,"maximum":2147483647}
            ]'::jsonb
        ),
        (
            'raw_auxiliary',
            'sleep_state',
            'device_reported_sleep_state_code',
            '[
                {"name":"event_at_ms","type":"integer"},
                {"name":"state_code","type":"integer","minimum":0,"maximum":3}
            ]'::jsonb
        ),
        (
            'raw_ppg',
            'spo2_optical_adc',
            'uncalibrated_red_and_infrared_optical_adc',
            '[
                {"name":"event_at_ms","type":"integer"},
                {"name":"red_adc","type":"integer","minimum":-2147483648,"maximum":2147483647},
                {"name":"infrared_adc","type":"integer","minimum":-2147483648,"maximum":2147483647}
            ]'::jsonb
        ),
        (
            'raw_ppg',
            'ppg_waveform',
            'packed_uncalibrated_optical_waveform',
            '[
                {"name":"event_at_ms","type":"integer"},
                {"name":"sample_rate_hz","type":"number","minimum":1,"maximum":1000},
                {"name":"sample_count","type":"integer","minimum":1,"maximum":4096},
                {"name":"samples_base64","type":"string","max_length":131072}
            ]'::jsonb
        ),
        (
            'raw_motion',
            'gravity',
            'gravity_vector_g',
            '[
                {"name":"event_at_ms","type":"integer"},
                {"name":"x_g","type":"number","minimum":-64,"maximum":64},
                {"name":"y_g","type":"number","minimum":-64,"maximum":64},
                {"name":"z_g","type":"number","minimum":-64,"maximum":64}
            ]'::jsonb
        ),
        (
            'raw_motion',
            'raw_imu',
            'packed_six_axis_inertial_waveform',
            '[
                {"name":"event_at_ms","type":"integer"},
                {"name":"sample_rate_hz","type":"number","minimum":1,"maximum":2000},
                {"name":"sample_count","type":"integer","minimum":1,"maximum":10000},
                {"name":"axis_order","type":"string","enum":["ax_ay_az_gx_gy_gz"],"max_length":32},
                {"name":"samples_base64","type":"string","max_length":1048576}
            ]'::jsonb
        ),
        (
            'derived_summaries',
            'live_session',
            'versioned_live_guardian_session',
            '[
                {"name":"event_at_ms","type":"integer"},
                {"name":"record_id","type":"string","max_length":128},
                {"name":"end_at_ms","type":"integer","nullable":true},
                {"name":"payload_json","type":"string","max_length":262144},
                {"name":"updated_at_ms","type":"integer"},
                {"name":"deleted","type":"boolean"}
            ]'::jsonb
        )
) AS stream(
    data_class,
    stream_key,
    semantic,
    columns
);

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
  AND (
      data_class IN ('raw_auxiliary', 'raw_ppg', 'raw_motion', 'derived_summaries')
      OR (
          data_class = 'essential_timeseries'
          AND stream_key IN (
              'body_measurement',
              'derived_heart_rate',
              'device_events',
              'step_counter'
          )
      )
  )
ON CONFLICT DO NOTHING;
