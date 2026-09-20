-- Persist one bounded app-to-app paging round per installation without
-- changing provider retry semantics. The existing attempts column remains the
-- per-round provider-attempt counter; page_round counts human-facing pages.

ALTER TABLE managed_safety_push_deliveries
    ADD COLUMN page_round integer NOT NULL DEFAULT 1;

ALTER TABLE managed_safety_push_deliveries
    ADD COLUMN next_page_at timestamptz;

ALTER TABLE managed_safety_push_deliveries
    ADD COLUMN first_delivered_at timestamptz;

UPDATE managed_safety_push_deliveries
SET first_delivered_at = delivered_at
WHERE delivered_at IS NOT NULL;

ALTER TABLE managed_safety_push_deliveries
    ADD CONSTRAINT managed_safety_delivery_page_round
        CHECK (page_round BETWEEN 1 AND 8) NOT VALID;

ALTER TABLE managed_safety_push_deliveries
    ADD CONSTRAINT managed_safety_delivery_next_page_state
        CHECK (
            next_page_at IS NULL
            OR (
                status = 'sent'
                AND delivered_at IS NOT NULL
                AND next_page_at > delivered_at
            )
        ) NOT VALID;

ALTER TABLE managed_safety_push_deliveries
    VALIDATE CONSTRAINT managed_safety_delivery_page_round;

ALTER TABLE managed_safety_push_deliveries
    VALIDATE CONSTRAINT managed_safety_delivery_next_page_state;

CREATE INDEX managed_safety_push_repeat_queue_idx
    ON managed_safety_push_deliveries (
        next_page_at,
        delivery_id
    )
    WHERE status = 'sent'
      AND next_page_at IS NOT NULL;
