-- Keep accepted Safety contact rows subordinate to the request that created
-- them so profile/account deletion can complete through the existing cascades.

ALTER TABLE managed_safety_contacts
    DROP CONSTRAINT IF EXISTS managed_safety_contacts_accepted_request_id_fkey;

ALTER TABLE managed_safety_contacts
    ADD CONSTRAINT managed_safety_contacts_accepted_request_id_fkey
    FOREIGN KEY (accepted_request_id)
    REFERENCES managed_safety_requests(request_id)
    ON DELETE CASCADE;
