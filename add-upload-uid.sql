-- ==============================================================
-- ADD upload_uid COLUMN TO DEVICES TABLE
-- Run this in Supabase SQL Editor
-- ==============================================================

-- Add upload_uid column to devices table
ALTER TABLE devices ADD COLUMN IF NOT EXISTS upload_uid TEXT DEFAULT '';

-- Create index for faster queries (optional, for future use)
CREATE INDEX IF NOT EXISTS idx_devices_upload_uid ON devices (upload_uid);

-- ==============================================================
-- DONE
-- ==============================================================
