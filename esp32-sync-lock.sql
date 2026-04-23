-- ==============================================================
-- ESP32 Device Lock Sync Function
-- Call this from ESP32 when pilot card locks/unlocks device
-- ==============================================================

-- Create function for ESP32 to sync lock state
CREATE OR REPLACE FUNCTION sync_device_lock_from_esp32(
  p_device_id TEXT,
  p_is_locked BOOLEAN,
  p_pilot_uid TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  -- Update device lock state
  UPDATE devices
  SET 
    is_locked = p_is_locked,
    locked_by = CASE 
      WHEN p_pilot_uid IS NOT NULL THEN 'PILOT:' || p_pilot_uid
      ELSE 'PILOT'
    END,
    locked_at = NOW()
  WHERE device_id = p_device_id;

  -- Log the event (optional table)
  BEGIN
    INSERT INTO device_lock_events (device_id, pilot_uid, action, timestamp)
    VALUES (
      p_device_id, 
      COALESCE(p_pilot_uid, 'PILOT'),
      CASE WHEN p_is_locked THEN 'LOCKED' ELSE 'UNLOCKED' END,
      NOW()
    );
  EXCEPTION WHEN OTHERS THEN
    -- Ignore if table doesn't exist
    NULL;
  END;
END;
$$;

-- Grant permissions
GRANT EXECUTE ON FUNCTION sync_device_lock_from_esp32(TEXT, BOOLEAN, TEXT) TO anon, authenticated;

-- ==============================================================
-- DONE - ESP32 should call this function via Supabase client
-- ==============================================================
