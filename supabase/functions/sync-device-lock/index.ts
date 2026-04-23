import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

serve(async (req) => {
  try {
    const { device_id, is_locked, pilot_uid } = await req.json();

    if (!device_id) {
      return new Response(JSON.stringify({ error: 'Missing device_id' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' }
      });
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    // Update device lock state from ESP32
    const { error } = await supabase
      .from('devices')
      .update({
        is_locked: is_locked,
        locked_by: pilot_uid ? `PILOT:${pilot_uid}` : 'PILOT',
        locked_at: new Date().toISOString()
      })
      .eq('device_id', device_id);

    if (error) throw error;

    // Log the event
    try {
      await supabase.from('device_lock_events').insert({
        device_id: device_id,
        pilot_uid: pilot_uid || 'PILOT',
        action: is_locked ? 'LOCKED' : 'UNLOCKED',
        timestamp: new Date().toISOString()
      });
    } catch (e) {
      // Non-critical
    }

    return new Response(
      JSON.stringify({ success: true, message: `Device ${is_locked ? 'locked' : 'unlocked'}` }),
      { headers: { 'Content-Type': 'application/json' } }
    );
  } catch (err) {
    return new Response(
      JSON.stringify({ error: err.message }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    );
  }
});
