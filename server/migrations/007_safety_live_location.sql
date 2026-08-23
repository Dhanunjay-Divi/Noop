-- Latest-only live location for an explicitly triggered Safety incident.
--
-- Privacy boundary: this table is one row per incident, not a route history.
-- Each newer fix replaces the previous one and the row is deleted with the
-- incident. Contacts can read it only through their signed incident link.

CREATE TABLE IF NOT EXISTS safety_incident_locations (
    dispatch_id uuid PRIMARY KEY
        REFERENCES safety_dispatches(dispatch_id) ON DELETE CASCADE,
    sequence bigint NOT NULL,
    latitude double precision NOT NULL,
    longitude double precision NOT NULL,
    horizontal_accuracy_meters double precision,
    captured_at timestamptz NOT NULL,
    received_at timestamptz NOT NULL,
    CONSTRAINT safety_location_sequence_positive CHECK (sequence > 0),
    CONSTRAINT safety_location_latitude CHECK (
        latitude >= -90 AND latitude <= 90
    ),
    CONSTRAINT safety_location_longitude CHECK (
        longitude >= -180 AND longitude <= 180
    ),
    CONSTRAINT safety_location_accuracy CHECK (
        horizontal_accuracy_meters IS NULL
        OR (
            horizontal_accuracy_meters >= 0
            AND horizontal_accuracy_meters <= 10000
        )
    )
);
