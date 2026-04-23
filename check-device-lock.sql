-- ==============================================================
-- DEBUG: Check current device lock status
-- Run this in Supabase SQL Editor to see what's happening
-- ==============================================================

-- Check current state of the device
SELECT 
  device_id,
  place_name,
  is_locked,
  locked_by,
  locked_at,
  last_seen,
  pilot_uid,
  NOW() - locked_at as time_since_lock_change
FROM devices 
WHERE device_id = 'LAB_AS_03';

-- Check recent lock events for this device
SELECT 
  device_id,
  pilot_uid,
  action,
  timestamp,
  NOW() - timestamp as time_ago
FROM device_lock_events 
WHERE device_id = 'LAB_AS_03'
ORDER BY timestamp DESC
LIMIT 10;

-- ==============================================================
-- MANUAL FIX: Force unlock the device
-- Uncomment and run this if needed:
-- ==============================================================
/*
UPDATE devices 
SET 
  is_locked = false,
  locked_by = 'PILOT:8BCCFB03',
  locked_at = NOW()
WHERE device_id = 'LAB_AS_03';
*/
