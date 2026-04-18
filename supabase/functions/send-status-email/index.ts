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
    const { device_id, place_name, to_email, status_filter, students } = await req.json()

    if (!to_email || !students) {
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

    // Build email content
    const statusText = status_filter === 'IN' ? 'Currently IN' : 'Currently OUT'
    const studentCount = students.length
    
    let studentListHtml = ''
    if (studentCount > 0) {
      studentListHtml = `
        <table style="width: 100%; border-collapse: collapse; margin-top: 16px;">
          <thead>
            <tr style="background: #f1f5f9;">
              <th style="padding: 12px; text-align: left; border-bottom: 1px solid #e5e7eb;">Name</th>
              <th style="padding: 12px; text-align: left; border-bottom: 1px solid #e5e7eb;">Roll Number</th>
              <th style="padding: 12px; text-align: left; border-bottom: 1px solid #e5e7eb;">UID</th>
            </tr>
          </thead>
          <tbody>
            ${students.map((s: any) => `
              <tr>
                <td style="padding: 12px; border-bottom: 1px solid #e5e7eb;">${s.name || '-'}</td>
                <td style="padding: 12px; border-bottom: 1px solid #e5e7eb;">${s.roll_number || '-'}</td>
                <td style="padding: 12px; border-bottom: 1px solid #e5e7eb;">${s.uid}</td>
              </tr>
            `).join('')}
          </tbody>
        </table>
      `
    } else {
      studentListHtml = '<p style="margin-top: 16px; color: #6b7280;">No students found for this status.</p>'
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
          .header h1 { margin: 0; color: #1d4ed8; font-size: 24px; }
          .info { background: #f8fafc; padding: 16px; border-radius: 8px; margin-bottom: 24px; }
          .info p { margin: 4px 0; color: #374151; }
          .info strong { color: #111827; }
          .badge { display: inline-block; padding: 4px 12px; border-radius: 9999px; font-size: 12px; font-weight: 600; }
          .badge-in { background: #dcfce7; color: #16a34a; }
          .badge-out { background: #fee2e2; color: #dc2626; }
        </style>
      </head>
      <body>
        <div class="container">
          <div class="header">
            <h1>RFID Access Control - Status Report</h1>
          </div>
          <div class="info">
            <p><strong>Device:</strong> ${device_id}</p>
            <p><strong>Place:</strong> ${place_name}</p>
            <p><strong>Status Filter:</strong> <span class="badge ${status_filter === 'IN' ? 'badge-in' : 'badge-out'}">${statusText}</span></p>
            <p><strong>Total Students:</strong> ${studentCount}</p>
          </div>
          <h2 style="font-size: 18px; margin-bottom: 12px;">Student List</h2>
          ${studentListHtml}
          <p style="margin-top: 24px; color: #6b7280; font-size: 14px;">
            This is an automated email from the RFID Access Control System.
          </p>
        </div>
      </body>
      </html>
    `

    // Send email via Resend
    const resendResponse = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${resendApiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        from: resendFromEmail,
        to: to_email,
        subject: `RFID Status Report - ${place_name} (${statusText})`,
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
    console.error('Error in send-status-email:', error)
    return new Response(
      JSON.stringify({ error: error.message }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 500 }
    )
  }
})
