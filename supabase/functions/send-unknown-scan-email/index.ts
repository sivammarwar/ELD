import { serve } from "https://deno.land/std@0.168.0/http/server.ts"

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const { uid, device_id, place_name, to_email } = await req.json()

    if (!to_email || !uid || !device_id || !place_name) {
      return new Response(
        JSON.stringify({ error: 'Missing required fields' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
      )
    }

    const resendApiKey = Deno.env.get('RESEND_API_KEY')
    const resendFromEmail = Deno.env.get('RESEND_FROM_EMAIL')

    if (!resendApiKey || !resendFromEmail) {
      return new Response(
        JSON.stringify({ error: 'Email service not configured' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 500 }
      )
    }

    const emailHtml = `
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="utf-8">
        <style>
          body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; line-height: 1.6; color: #111827; }
          .container { max-width: 600px; margin: 0 auto; padding: 32px; }
          .header { border-bottom: 1px solid #e5e7eb; padding-bottom: 16px; margin-bottom: 24px; }
          .header h1 { margin: 0; color: #dc2626; font-size: 24px; }
          .alert { background: #fee2e2; border: 1px solid #fecaca; padding: 16px; border-radius: 8px; margin-bottom: 24px; }
          .alert p { margin: 4px 0; color: #991b1b; }
          .alert strong { color: #7f1d1d; }
          .info { background: #f8fafc; padding: 16px; border-radius: 8px; margin-bottom: 24px; }
          .info p { margin: 4px 0; color: #374151; }
          .info strong { color: #111827; }
          .uid { font-family: monospace; background: #f1f5f9; padding: 8px 12px; border-radius: 4px; font-size: 16px; letter-spacing: 1px; }
        </style>
      </head>
      <body>
        <div class="container">
          <div class="header">
            <h1>⚠️ Unknown RFID Card Scanned</h1>
          </div>
          <div class="alert">
            <p><strong>An unregistered RFID card was scanned at your location.</strong></p>
          </div>
          <div class="info">
            <p><strong>Card UID:</strong> <span class="uid">${uid}</span></p>
            <p><strong>Device:</strong> ${device_id}</p>
            <p><strong>Place:</strong> ${place_name}</p>
            <p><strong>Time:</strong> ${new Date().toLocaleString()}</p>
          </div>
          <p style="color: #6b7280; font-size: 14px;">
            This card is not registered in the system. Please check if this is a legitimate card that needs to be added, or if this is an unauthorized access attempt.
          </p>
          <p style="margin-top: 16px; color: #6b7280; font-size: 14px;">
            Review this scan in the dashboard's Unknown Scans section.
          </p>
        </div>
      </body>
      </html>
    `

    const resendResponse = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${resendApiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        from: resendFromEmail,
        to: to_email,
        subject: `⚠️ Unknown RFID Card Scanned - ${place_name}`,
        html: emailHtml,
      }),
    })

    if (!resendResponse.ok) {
      const error = await resendResponse.text()
      console.error('Resend API error:', error)
      return new Response(
        JSON.stringify({ error: 'Failed to send email', details: error }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 500 }
      )
    }

    const resendData = await resendResponse.json()
    
    return new Response(
      JSON.stringify({ success: true, messageId: resendData.id }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )

  } catch (error) {
    console.error('Error in send-unknown-scan-email:', error)
    return new Response(
      JSON.stringify({ error: error.message }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 500 }
    )
  }
})
