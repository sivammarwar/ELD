-- ==============================================================
-- FIX: Prevent dashboard from overwriting recent pilot unlocks
-- Add to your database to prevent auto-relock issue
-- ==============================================================

-- Update the devices table to track WHO last changed the lock
-- (This assumes locked_by already exists from earlier SQL)

-- Create function for dashboard to safely update lock
-- Only locks if not recently unlocked by pilot
CREATE OR REPLACE FUNCTION dashboard_force_lock(
  p_device_id TEXT,
  p_locked BOOLEAN
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_current_record RECORD;
  v_seconds_since_pilot_change INT;
BEGIN
  -- Get current device state
  SELECT is_locked, locked_by, locked_at, EXTRACT(EPOCH FROM (NOW() - locked_at))/1 AS seconds_since_change
  INTO v_current_record
  FROM devices
  WHERE device_id = p_device_id;

  -- If trying to lock, but pilot just unlocked in last 5 seconds, skip
  -- This prevents race condition where pollDeviceLock() re-locks immediately after pilot unlocks
  IF p_locked = true AND v_current_record.is_locked = false THEN
    -- Check if last unlock was by pilot and recent
    IF v_current_record.locked_by LIKE 'PILOT%' OR v_current_record.locked_by = '' THEN
      -- If pilot unlocked less than 5 seconds ago, don't re-lock
      IF v_current_record.seconds_since_change < 5 THEN
        RAISE NOTICE 'Skipping dashboard lock - pilot recently unlocked';
        RETURN; -- Exit without changing
      END IF;
    END IF;
  END IF;

  -- Safe to update
  UPDATE devices
  SET 
    is_locked = p_locked,
    locked_by = 'DASHBOARD',
    locked_at = NOW()
  WHERE device_id = p_device_id;

  -- Log event
  INSERT INTO device_lock_events (device_id, pilot_uid, action, timestamp)
  VALUES (p_device_id, 'DASHBOARD', CASE WHEN p_locked THEN 'LOCKED' ELSE 'UNLOCKED' END, NOW());
END;
$$;

-- Grant permissions
GRANT EXECUTE ON FUNCTION dashboard_force_lock(TEXT, BOOLEAN) TO anon, authenticated;

-- Drop the trigger if it was previously created (to avoid blocking ESP32 updates)
DROP TRIGGER IF EXISTS prevent_rapid_lock ON devices;

-- ==============================================================
-- DONE - Run this in Supabase SQL Editor
-- ==============================================================

-- NOTE: Using dashboard_force_lock() RPC instead of trigger
-- Dashboard calls this function which respects recent pilot unlocks
