-- ==============================================================
-- FIX DEVICE FUNCTIONS AND TABLES
-- Run this in Supabase SQL Editor
-- ==============================================================

-- Step 1: Add locked_by and locked_at columns to devices table (if not exist)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'devices' AND column_name = 'locked_by') THEN
    ALTER TABLE devices ADD COLUMN locked_by TEXT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'devices' AND column_name = 'locked_at') THEN
    ALTER TABLE devices ADD COLUMN locked_at TIMESTAMPTZ;
  END IF;
END $$;

-- Step 2: Create device_lock_events table
CREATE TABLE IF NOT EXISTS device_lock_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  device_id TEXT NOT NULL,
  pilot_uid TEXT,
  action TEXT NOT NULL CHECK (action IN ('LOCKED', 'UNLOCKED')),
  timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Step 3: Enable RLS on device_lock_events
ALTER TABLE device_lock_events ENABLE ROW LEVEL SECURITY;

-- Step 4: Create RLS policies for device_lock_events
DROP POLICY IF EXISTS "lock events anon select" ON device_lock_events;
CREATE POLICY "lock events anon select"
  ON device_lock_events FOR SELECT TO anon USING (true);

DROP POLICY IF EXISTS "lock events anon insert" ON device_lock_events;
CREATE POLICY "lock events anon insert"
  ON device_lock_events FOR INSERT TO anon WITH CHECK (true);

-- Step 5: Create update_device_pilot function
CREATE OR REPLACE FUNCTION update_device_pilot(
  p_device_id TEXT,
  p_pilot_uid TEXT
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  -- Update the device pilot_uid
  UPDATE devices 
  SET pilot_uid = p_pilot_uid
  WHERE device_id = p_device_id;
  
  -- Log the pilot change event
  INSERT INTO device_lock_events (device_id, pilot_uid, action, timestamp)
  VALUES (p_device_id, p_pilot_uid, 'PILOT_CHANGED', NOW());
END;
$$;

-- Step 6: Grant execute permissions
GRANT EXECUTE ON FUNCTION update_device_pilot(TEXT, TEXT) TO anon, authenticated;

-- Step 7: Create index for device_lock_events
CREATE INDEX IF NOT EXISTS idx_lock_events_device ON device_lock_events (device_id);
CREATE INDEX IF NOT EXISTS idx_lock_events_timestamp ON device_lock_events (timestamp DESC);

-- ==============================================================
-- DONE
-- ==============================================================
