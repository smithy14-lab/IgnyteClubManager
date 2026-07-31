// Supabase Edge Function: send-notification-email
//
// Triggered by a Database Webhook on INSERT into public.notifications.
// Looks up the recipient's email and forwards the notification via Resend
// (free tier: 100 emails/day — plenty for a single club).
//
// Setup (see README):
//   supabase secrets set RESEND_API_KEY=re_xxx EMAIL_FROM="Ignyte Club <club@yourdomain.com>"
//   supabase functions deploy send-notification-email --no-verify-jwt
// then create a Database Webhook: table=notifications, events=INSERT,
// type=Supabase Edge Function, function=send-notification-email.

import { createClient } from 'npm:@supabase/supabase-js@2';

Deno.serve(async (req) => {
  try {
    const payload = await req.json();
    const record = payload?.record;
    if (!record?.profile_id) {
      return new Response('ignored', { status: 200 });
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    );

    const { data: profile } = await supabase
      .from('profiles')
      .select('email, full_name')
      .eq('id', record.profile_id)
      .single();
    if (!profile?.email) return new Response('no recipient', { status: 200 });

    const apiKey = Deno.env.get('RESEND_API_KEY');
    if (!apiKey) return new Response('RESEND_API_KEY not set', { status: 200 });

    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        from: Deno.env.get('EMAIL_FROM') ?? 'Ignyte Club Manager <onboarding@resend.dev>',
        to: profile.email,
        subject: record.title,
        html: `
          <div style="font-family:system-ui,sans-serif;max-width:520px;margin:0 auto;padding:24px">
            <h2 style="color:#ff6a1a;margin:0 0 4px">Ignyte Club Manager</h2>
            <h3 style="margin:16px 0 8px">${record.title}</h3>
            <p style="color:#444;line-height:1.6">${record.body}</p>
            <p style="margin-top:24px">
              <a href="${Deno.env.get('APP_URL') ?? ''}/bookings"
                 style="background:#ff6a1a;color:#fff;padding:10px 22px;border-radius:999px;text-decoration:none;font-weight:600">
                Open the app
              </a>
            </p>
          </div>`,
      }),
    });
    return new Response(res.ok ? 'sent' : await res.text(), { status: 200 });
  } catch (e) {
    return new Response(`error: ${e}`, { status: 200 });
  }
});
