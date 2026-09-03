CREATE TABLE IF NOT EXISTS devices (
    device_id text PRIMARY KEY,
    display_name text,
    model text,
    firmware_version text,
    hardware_revision text,
    platform text,
    app_version text,
    last_seen timestamptz NOT NULL,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS sync_batches (
    batch_id uuid PRIMARY KEY,
    device_id text NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    payload_hash char(64) NOT NULL,
    counts jsonb NOT NULL,
    sent_at timestamptz NOT NULL,
    received_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS sync_batches_device_received_idx
    ON sync_batches (device_id, received_at DESC);

CREATE TABLE IF NOT EXISTS metric_samples (
    device_id text NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    metric text NOT NULL,
    recorded_at timestamptz NOT NULL,
    -- R-R intervals can share a whole-second timestamp. The repository derives
    -- this from interval value + metadata.seq, matching the client's full
    -- (timestamp, value, duplicate sequence) natural key.
    sample_key text NOT NULL DEFAULT '',
    value double precision NOT NULL,
    unit text NOT NULL,
    measurement_class text NOT NULL,
    clinical_interpretation_allowed boolean NOT NULL DEFAULT false,
    quality double precision,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    received_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (device_id, metric, recorded_at, sample_key),
    CONSTRAINT metric_quality_fraction
        CHECK (quality IS NULL OR (quality >= 0 AND quality <= 1)),
    CONSTRAINT raw_sensor_never_clinical
        CHECK (
            measurement_class NOT IN ('raw_sensor', 'unclassified_sensor')
            OR clinical_interpretation_allowed = false
        )
);

CREATE INDEX IF NOT EXISTS metric_samples_latest_idx
    ON metric_samples (device_id, metric, recorded_at DESC);

CREATE TABLE IF NOT EXISTS events (
    device_id text NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    event_id text NOT NULL,
    recorded_at timestamptz NOT NULL,
    kind text NOT NULL,
    value_json jsonb,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    received_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (device_id, event_id)
);

CREATE INDEX IF NOT EXISTS events_device_time_idx
    ON events (device_id, recorded_at DESC);

CREATE TABLE IF NOT EXISTS daily_metrics (
    device_id text NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    day date NOT NULL,
    metric text NOT NULL,
    value double precision NOT NULL,
    received_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (device_id, day, metric)
);

CREATE INDEX IF NOT EXISTS daily_metrics_device_day_idx
    ON daily_metrics (device_id, day DESC);

CREATE TABLE IF NOT EXISTS sleep_sessions (
    device_id text NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    session_id text NOT NULL,
    start_ts timestamptz NOT NULL,
    end_ts timestamptz NOT NULL,
    -- Fraction, not percentage: 0.87 means 87%.
    efficiency double precision,
    resting_hr double precision,
    avg_hrv double precision,
    stages jsonb NOT NULL DEFAULT '[]'::jsonb,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    received_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (device_id, session_id),
    CONSTRAINT sleep_times_ordered CHECK (end_ts > start_ts),
    CONSTRAINT sleep_efficiency_fraction
        CHECK (efficiency IS NULL OR (efficiency >= 0 AND efficiency <= 1))
);

CREATE INDEX IF NOT EXISTS sleep_sessions_device_time_idx
    ON sleep_sessions (device_id, start_ts DESC);

CREATE TABLE IF NOT EXISTS workouts (
    device_id text NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    workout_id text NOT NULL,
    start_ts timestamptz NOT NULL,
    end_ts timestamptz NOT NULL,
    sport text NOT NULL,
    source text,
    metrics jsonb NOT NULL DEFAULT '{}'::jsonb,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    received_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (device_id, workout_id),
    CONSTRAINT workout_times_ordered CHECK (end_ts > start_ts)
);

CREATE INDEX IF NOT EXISTS workouts_device_time_idx
    ON workouts (device_id, start_ts DESC);

CREATE TABLE IF NOT EXISTS journal_entries (
    device_id text NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    day date NOT NULL,
    question text NOT NULL,
    question_key text NOT NULL,
    answered_yes boolean NOT NULL,
    notes text,
    numeric_value double precision,
    received_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (device_id, day, question_key)
);

CREATE INDEX IF NOT EXISTS journal_entries_device_day_idx
    ON journal_entries (device_id, day DESC);
