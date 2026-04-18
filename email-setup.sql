-- ==============================================================
-- EMAIL SETUP SQL (Resend)
-- Run this in Supabase SQL Editor
-- ==============================================================

-- Step 1: Create settings table if not exists
CREATE TABLE IF NOT EXISTS settings (
  name  TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

-- Step 2: Insert edge function configuration
INSERT INTO settings (name, value) VALUES
  ('app.edge_function_url', 'https://ewrvfwmrbtshyhtrmoge.supabase.co/functions/v1'),
  ('app.service_role_key', 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImV3cnZmd21yYnRzaHlodHJtb2dlIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3NjUxNzAwMiwiZXhwIjoyMDkyMDkzMDAyfQ.vqXNbYD3oLnP76O1qzgZvhhenrOzENfqtZZcK_jvP8E')
ON CONFLICT (name) DO UPDATE SET value = EXCLUDED.value;

-- Step 3: Grant access to settings table
ALTER TABLE settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "settings anon select" ON settings;
CREATE POLICY "settings anon select"
  ON settings FOR SELECT TO anon USING (true);

DROP POLICY IF EXISTS "settings service_role all" ON settings;
CREATE POLICY "settings service_role all"
  ON settings FOR ALL TO service_role USING (true) WITH CHECK (true);

-- Step 4: Create helper function for sending unknown scan emails
CREATE OR REPLACE FUNCTION send_unknown_scan_email(
  p_uid        TEXT,
  p_device_id  TEXT,
  p_place_name TEXT,
  p_to_email   TEXT
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_edge_url    TEXT;
  v_service_key TEXT;
BEGIN
  BEGIN
    v_edge_url    := (SELECT value FROM settings WHERE name = 'app.edge_function_url');
    v_service_key := (SELECT value FROM settings WHERE name = 'app.service_role_key');
  EXCEPTION WHEN OTHERS THEN
    RETURN;
  END;

  IF COALESCE(v_edge_url,    '') = '' THEN RETURN; END IF;
  IF COALESCE(v_service_key, '') = '' THEN RETURN; END IF;
  IF COALESCE(p_to_email,    '') = '' THEN RETURN; END IF;

  BEGIN
    PERFORM net.http_post(
      url     := v_edge_url || '/send-unknown-scan-email',
      headers := jsonb_build_object(
                   'Content-Type',  'application/json',
                   'Authorization', 'Bearer ' || v_service_key
                 ),
      body    := jsonb_build_object(
                   'uid',        p_uid,
                   'device_id',  p_device_id,
                   'place_name', p_place_name,
                   'to_email',   p_to_email
                 )
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'send_unknown_scan_email HTTP failed: %', SQLERRM;
  END;
END;
$$;

-- Step 5: Replace process_unknown_scans with email support
CREATE OR REPLACE FUNCTION process_unknown_scans(p_scans JSONB)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  item        JSONB;
  rec_uid     TEXT;
  rec_device  TEXT;
  rec_place   TEXT;
  rec_to_email TEXT;
  rec_ts      TIMESTAMPTZ;
  v_device    RECORD;
BEGIN
  FOR item IN SELECT * FROM jsonb_array_elements(p_scans)
  LOOP
    rec_uid    := item->>'uid';
    rec_device := item->>'device_id';
    rec_place  := item->>'place_name';
    rec_to_email := item->>'to_email';

    BEGIN
      rec_ts := COALESCE((item->>'timestamp')::TIMESTAMPTZ, NOW());
    EXCEPTION WHEN OTHERS THEN
      rec_ts := NOW();
    END;

    -- Insert into unknown_scans
    INSERT INTO unknown_scans (uid, device_id, place_name, to_email, created_at)
    VALUES (rec_uid, rec_device, rec_place, rec_to_email, rec_ts)
    ON CONFLICT (uid, device_id) DO NOTHING;

    -- Send email if device has email_unknown_scans enabled
    IF rec_device IS NOT NULL AND rec_device != '' THEN
      SELECT * INTO v_device 
      FROM devices 
      WHERE device_id = rec_device AND email_unknown_scans = TRUE 
      LIMIT 1;
      
      IF v_device.device_id IS NOT NULL THEN
        PERFORM send_unknown_scan_email(
          rec_uid, 
          rec_device, 
          rec_place, 
          COALESCE(v_device.device_email, rec_to_email)
        );
      END IF;
    END IF;
  END LOOP;
END;
$$;

-- Step 6: Replace process_access_logs_batch with automatic status email support
CREATE OR REPLACE FUNCTION process_access_logs_batch(p_logs JSONB)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  item       JSONB;
  rec_uid    TEXT;
  rec_roll   TEXT;
  rec_place  TEXT;
  rec_device TEXT;
  rec_status SMALLINT;
  rec_ts     TIMESTAMPTZ;
  v_device   RECORD;
  v_edge_url TEXT;
  v_service_key TEXT;
  v_device_code TEXT;
BEGIN
  FOR item IN SELECT * FROM jsonb_array_elements(p_logs)
  LOOP
    rec_uid    := item->>'uid';
    rec_roll   := item->>'roll_number';
    rec_place  := item->>'place_name';
    rec_device := item->>'device_id';

    BEGIN
      rec_status := (item->>'status')::SMALLINT;
    EXCEPTION WHEN OTHERS THEN
      CONTINUE;
    END;

    BEGIN
      rec_ts := (item->>'timestamp')::TIMESTAMPTZ;
    EXCEPTION WHEN OTHERS THEN
      CONTINUE;
    END;

    IF rec_uid    IS NULL OR rec_uid    = '' THEN CONTINUE; END IF;
    IF rec_ts     IS NULL                    THEN CONTINUE; END IF;
    IF rec_device IS NULL OR rec_device = '' THEN CONTINUE; END IF;

    -- Insert access log
    INSERT INTO access_logs
      (uid, roll_number, place_name, device_id, status, timestamp)
    VALUES
      (rec_uid, rec_roll, rec_place, rec_device, rec_status, rec_ts)
    ON CONFLICT (uid, timestamp, device_id) DO NOTHING;

    -- Check if device has email_status_for matching this status change
    SELECT * INTO v_device 
    FROM devices 
    WHERE device_id = rec_device 
      AND is_active = TRUE
      AND device_email IS NOT NULL 
      AND device_email != ''
      AND (
        (email_status_for = 'IN' AND rec_status = 1) OR
        (email_status_for = 'OUT' AND rec_status = 0)
      )
    LIMIT 1;

    IF v_device.device_id IS NOT NULL THEN
      -- Send automatic status email
      BEGIN
        v_edge_url    := (SELECT value FROM settings WHERE name = 'app.edge_function_url');
        v_service_key := (SELECT value FROM settings WHERE name = 'app.service_role_key');
        
        IF COALESCE(v_edge_url, '') != '' AND COALESCE(v_service_key, '') != '' THEN
          v_device_code := v_device.device_code;
          
          PERFORM net.http_post(
            url     := v_edge_url || '/send-status-email',
            headers := jsonb_build_object(
                         'Content-Type',  'application/json',
                         'Authorization', 'Bearer ' || v_service_key
                       ),
            body    := jsonb_build_object(
                         'device_id',     rec_device,
                         'place_name',    rec_place,
                         'to_email',      v_device.device_email,
                         'status_filter', CASE WHEN rec_status = 1 THEN 'IN' ELSE 'OUT' END,
                         'students',      get_students_json(rec_status, v_device_code)
                       )
          );
        END IF;
      EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Automatic status email HTTP failed: %', SQLERRM;
      END;
    END IF;
  END LOOP;

  -- Update user statuses
  UPDATE valid_users AS u
  SET status = latest.status
  FROM (
    SELECT DISTINCT ON (al.uid)
      al.uid,
      al.status
    FROM access_logs al
    WHERE al.uid = ANY (
      SELECT DISTINCT el->>'uid'
      FROM jsonb_array_elements(p_logs) AS el
      WHERE el->>'uid' IS NOT NULL
    )
    ORDER BY al.uid, al.timestamp DESC
  ) AS latest
  WHERE u.uid = latest.uid;
END;
$$;

-- Step 7: Grant execute on new function
GRANT EXECUTE ON FUNCTION send_unknown_scan_email(TEXT, TEXT, TEXT, TEXT) TO anon, authenticated;

-- ==============================================================
-- DONE
-- ==============================================================
