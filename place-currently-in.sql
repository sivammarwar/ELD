-- ==============================================================
-- PLACE CURRENTLY IN STUDENTS
-- Shows list of students whose last status is IN at each place
-- ==============================================================

-- Create function to get students currently IN at each place
CREATE OR REPLACE FUNCTION get_place_currently_in()
RETURNS TABLE (
  place_name TEXT,
  uid TEXT,
  roll_number TEXT,
  last_in_timestamp TIMESTAMPTZ
)
LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT DISTINCT ON (latest.place_name, latest.uid)
    latest.place_name,
    latest.uid,
    latest.roll_number,
    latest.timestamp as last_in_timestamp
  FROM (
    SELECT DISTINCT ON (uid, place_name)
      uid,
      place_name,
      roll_number,
      status,
      timestamp
    FROM access_logs
    WHERE place_name IS NOT NULL
    ORDER BY uid, place_name, timestamp DESC
  ) AS latest
  WHERE latest.status = 1
    AND NOT EXISTS (
      -- Exclude if student transitioned out (moved to another place)
      SELECT 1 FROM student_transitions st
      WHERE st.uid = latest.uid
      AND st.from_place = latest.place_name
      AND st.transition_timestamp > NOW() - INTERVAL '24 hours'
    )
  ORDER BY latest.place_name, latest.uid, latest.timestamp DESC;
$$;

-- Grant execute permissions
GRANT EXECUTE ON FUNCTION get_place_currently_in() TO anon, authenticated;

-- ==============================================================
-- DONE
-- ==============================================================
