-- Remove precise locations retained by terminal incidents created before the
-- terminal-transition deletion contract was deployed. Active incidents keep
-- their latest-only row; terminal history remains coordinate-free.

DELETE FROM safety_incident_locations AS location
USING safety_dispatches AS dispatch
WHERE location.dispatch_id = dispatch.dispatch_id
  AND dispatch.status IN ('resolved', 'cancelled', 'expired', 'failed');
