-- Drop and recreate the view with all columns
DROP VIEW IF EXISTS device_lock_status;

CREATE VIEW device_lock_status AS
SELECT 
  d.device_id,
  d.place_name,
  d.device_code,
  d.device_email,
  d.pilot_uid,
  d.upload_uid,
  d.email_unknown_scans,
  d.email_status_for,
  d.can_register,
  d.is_active,
  d.firmware_version,
  d.last_seen,
  d.is_locked as db_is_locked,
  d.locked_by,
  d.locked_at,
  EXISTS (
    SELECT 1 FROM device_lock_events e
    WHERE e.device_id = d.device_id
      AND e.action = 'UNLOCKED'
      AND e.pilot_uid != 'DASHBOARD'
      AND e.timestamp > NOW() - INTERVAL '15 seconds'
      AND (e.timestamp > d.locked_at OR d.locked_at IS NULL)
  ) as pilot_recently_unlocked,
  CASE 
    WHEN EXISTS (
      SELECT 1 FROM device_lock_events e
      WHERE e.device_id = d.device_id
        AND e.action = 'UNLOCKED'
        AND e.pilot_uid != 'DASHBOARD'
        AND e.timestamp > NOW() - INTERVAL '15 seconds'
        AND (e.timestamp > d.locked_at OR d.locked_at IS NULL)
    ) THEN false
    ELSE d.is_locked
  END as effective_is_locked
FROM devices d;

GRANT SELECT ON device_lock_status TO anon, authenticated;
