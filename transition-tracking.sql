-- ==============================================================
-- TRANSITION TRACKING UPDATE
-- Run this in Supabase SQL Editor
-- Assumes you have already run the main schema and email-setup.sql
-- ==============================================================

-- Step 1: Add student_transitions table (if not exists)
CREATE TABLE IF NOT EXISTS student_transitions (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  uid               TEXT        NOT NULL,
  from_place        TEXT        NOT NULL,
  to_place          TEXT        NOT NULL,
  from_status       SMALLINT    NOT NULL,
  to_status         SMALLINT    NOT NULL,
  transition_timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  device_id         TEXT
);

-- Step 2: Add indexes (if not exists)
CREATE INDEX IF NOT EXISTS idx_transitions_uid ON student_transitions (uid);
CREATE INDEX IF NOT EXISTS idx_transitions_from_place ON student_transitions (from_place);
CREATE INDEX IF NOT EXISTS idx_transitions_to_place ON student_transitions (to_place);
CREATE INDEX IF NOT EXISTS idx_transitions_timestamp ON student_transitions (transition_timestamp DESC);

-- Step 3: Enable RLS
ALTER TABLE student_transitions ENABLE ROW LEVEL SECURITY;

-- Step 4: Create RLS policies
DROP POLICY IF EXISTS "transitions anon select" ON student_transitions;
CREATE POLICY "transitions anon select"
  ON student_transitions FOR SELECT TO anon USING (true);

DROP POLICY IF EXISTS "transitions anon insert" ON student_transitions;
CREATE POLICY "transitions anon insert"
  ON student_transitions FOR INSERT TO anon WITH CHECK (true);

-- Step 5: Update process_access_logs_batch with transition detection
CREATE OR REPLACE FUNCTION process_access_logs_batch(p_logs JSONB)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  item          JSONB;
  rec_uid       TEXT;
  rec_roll      TEXT;
  rec_place     TEXT;
  rec_device    TEXT;
  rec_status    SMALLINT;
  rec_ts        TIMESTAMPTZ;
  v_device      RECORD;
  v_edge_url    TEXT;
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

    -- Detect and record transition using subquery (no variables)
    INSERT INTO student_transitions (uid, from_place, to_place, from_status, to_status, transition_timestamp, device_id)
    SELECT 
      rec_uid,
      al.place_name,
      rec_place,
      al.status,
      rec_status,
      rec_ts,
      rec_device
    FROM (
      SELECT place_name, status, device_id
      FROM access_logs
      WHERE uid = rec_uid
      ORDER BY timestamp DESC
      LIMIT 1
    ) al
    WHERE al.place_name IS NOT NULL
      AND al.place_name != rec_place
      AND al.status = 1
      AND rec_status = 1
      AND NOT EXISTS (
        SELECT 1 FROM student_transitions st
        WHERE st.uid = rec_uid
        AND st.from_place = al.place_name
        AND st.to_place = rec_place
        AND st.transition_timestamp > NOW() - INTERVAL '1 hour'
      );

    INSERT INTO access_logs
      (uid, roll_number, place_name, device_id, status, timestamp)
    VALUES
      (rec_uid, rec_roll, rec_place, rec_device, rec_status, rec_ts)
    ON CONFLICT (uid, timestamp, device_id) DO NOTHING;

    -- Email logic (existing)
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

-- Step 6: Update get_place_wise_status to exclude transitioned students
CREATE OR REPLACE FUNCTION get_place_wise_status()
RETURNS TABLE (
  place_name  TEXT,
  in_count    BIGINT,
  out_count   BIGINT,
  total_count BIGINT
)
LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT
    latest.place_name,
    COUNT(*) FILTER (WHERE latest.status = 1 AND latest.uid NOT IN (
      SELECT DISTINCT st.uid
      FROM student_transitions st
      WHERE st.from_place = latest.place_name
      AND st.transition_timestamp > NOW() - INTERVAL '24 hours'
    )) AS in_count,
    COUNT(*) FILTER (WHERE latest.status = 0 OR latest.uid IN (
      SELECT DISTINCT st.uid
      FROM student_transitions st
      WHERE st.from_place = latest.place_name
      AND st.transition_timestamp > NOW() - INTERVAL '24 hours'
    )) AS out_count,
    COUNT(*) AS total_count
  FROM (
    SELECT DISTINCT ON (uid, place_name)
      uid, place_name, status
    FROM access_logs
    WHERE place_name IS NOT NULL
    ORDER BY uid, place_name, timestamp DESC
  ) AS latest
  GROUP BY latest.place_name
  ORDER BY latest.place_name;
$$;

-- Step 7: Create function to get transitions for a place
CREATE OR REPLACE FUNCTION get_place_transitions(p_place_name TEXT, p_hours INT DEFAULT 24)
RETURNS TABLE (
  uid                  TEXT,
  to_place             TEXT,
  to_status            SMALLINT,
  transition_timestamp TIMESTAMPTZ,
  device_id            TEXT
)
LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT
    st.uid,
    st.to_place,
    st.to_status,
    st.transition_timestamp,
    st.device_id
  FROM student_transitions st
  WHERE st.from_place = p_place_name
    AND st.transition_timestamp > NOW() - (p_hours || ' hours')::INTERVAL
  ORDER BY st.transition_timestamp DESC;
$$;

-- Step 8: Grant execute permissions
GRANT EXECUTE ON FUNCTION get_place_transitions(TEXT, INT) TO anon, authenticated;

-- ==============================================================
-- DONE
-- ==============================================================
