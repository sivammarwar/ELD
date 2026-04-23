-- ==============================================================
-- PREVENT AUTO-RELOCK AFTER PILOT UNLOCK
-- Run this in Supabase SQL Editor
-- This blocks DB updates that would overwrite recent pilot actions
-- ==============================================================

-- Drop existing trigger if any
DROP TRIGGER IF EXISTS prevent_relock_after_pilot ON devices;
DROP FUNCTION IF EXISTS check_pilot_unlock_protection();

-- Create function to protect recent pilot unlocks
CREATE OR REPLACE FUNCTION check_pilot_unlock_protection()
RETURNS TRIGGER AS $$
DECLARE
  v_last_pilot_action TEXT;
  v_last_pilot_time TIMESTAMPTZ;
  v_seconds_since_pilot INT;
BEGIN
  -- Get the most recent lock event for this device
  SELECT action, timestamp
  INTO v_last_pilot_action, v_last_pilot_time
  FROM device_lock_events
  WHERE device_id = NEW.device_id
    AND pilot_uid != 'DASHBOARD'  -- Only consider non-dashboard actions
  ORDER BY timestamp DESC
  LIMIT 1;

  -- If we have a recent pilot action
  IF v_last_pilot_time IS NOT NULL THEN
    v_seconds_since_pilot = EXTRACT(EPOCH FROM (NOW() - v_last_pilot_time))::INT;
    
    -- If pilot UNLOCKED within last 15 seconds, prevent any lock
    IF v_last_pilot_action = 'UNLOCKED' AND v_seconds_since_pilot < 15 THEN
      -- Someone (pollDeviceLock or dashboard) is trying to lock
      -- But pilot just unlocked, so reject this change
      RAISE NOTICE 'BLOCKING lock - pilot unlocked % seconds ago', v_seconds_since_pilot;
      
      -- Return the OLD record unchanged (reject the update)
      RETURN OLD;
    END IF;
    
    -- If pilot LOCKED within last 5 seconds, prevent unlock
    IF v_last_pilot_action = 'LOCKED' AND v_seconds_since_pilot < 5 THEN
      RAISE NOTICE 'BLOCKING unlock - pilot locked % seconds ago', v_seconds_since_pilot;
      RETURN OLD;
    END IF;
  END IF;

  -- Allow the change
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger on devices table
CREATE TRIGGER prevent_relock_after_pilot
  BEFORE UPDATE ON devices
  FOR EACH ROW
  WHEN (OLD.is_locked IS DISTINCT FROM NEW.is_locked)  -- Only when lock state changes
  EXECUTE FUNCTION check_pilot_unlock_protection();

-- ==============================================================
-- ALTERNATIVE: If trigger causes issues, use this simpler approach:
-- Just update the pollDeviceLock to respect pilot actions
-- ==============================================================

-- Drop the existing view first (needed when adding columns)
DROP VIEW IF EXISTS device_lock_status CASCADE;

-- Create a view that shows effective lock state considering recent pilot actions
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
  -- Check if pilot recently unlocked (within 15 seconds)
  EXISTS (
    SELECT 1 FROM device_lock_events e
    WHERE e.device_id = d.device_id
      AND e.action = 'UNLOCKED'
      AND e.pilot_uid != 'DASHBOARD'
      AND e.timestamp > NOW() - INTERVAL '15 seconds'
      AND (e.timestamp > d.locked_at OR d.locked_at IS NULL)
  ) as pilot_recently_unlocked,
  -- Effective lock state
  CASE 
    WHEN EXISTS (
      SELECT 1 FROM device_lock_events e
      WHERE e.device_id = d.device_id
        AND e.action = 'UNLOCKED'
        AND e.pilot_uid != 'DASHBOARD'
        AND e.timestamp > NOW() - INTERVAL '15 seconds'
        AND (e.timestamp > d.locked_at OR d.locked_at IS NULL)
    ) THEN false  -- Force unlocked if pilot recently unlocked
    ELSE d.is_locked
  END as effective_is_locked
FROM devices d;

-- Grant access to view
GRANT SELECT ON device_lock_status TO anon, authenticated;

-- ==============================================================
-- DONE
-- ==============================================================
