// Ignyte Club Manager — email pipeline.
//
// Drains unemailed notifications and sends them via Resend. Triggered
// opportunistically from the app after sign-in (rate-limited to one drain
// per 2 minutes via app_kv), so no cron is required — though you can also
// schedule it. No-ops gracefully until RESEND_API_KEY is set.
//
// Secrets: RESEND_API_KEY (required to send), EMAIL_FROM (e.g.
// "Ignyte Club Manager <notify@yourdomain>"). Deploy:
//   supabase functions deploy send-emails
//   supabase secrets set RESEND_API_KEY=re_... EMAIL_FROM="..."

import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const esc = (s: string) =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    // any signed-in user may nudge the drain; sending itself is service-side
    const anon = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: userData } = await anon.auth.getUser();
    if (!userData?.user) return json({ error: "Sign in first." }, 401);

    const key = Deno.env.get("RESEND_API_KEY");
    if (!key) return json({ sent: 0, skipped: "RESEND_API_KEY not set" });
    const from = Deno.env.get("EMAIL_FROM") ?? "Ignyte Club Manager <onboarding@resend.dev>";
    const appUrl = Deno.env.get("APP_URL") ?? "https://ignyte-club-manager.nathansmith00.workers.dev";

    const svc = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    // one drain per 2 minutes
    const { data: lockRow } = await svc.from("app_kv").select("v").eq("k", "email_drain").maybeSingle();
    if (lockRow?.v && Date.now() - Date.parse(lockRow.v) < 120_000) return json({ sent: 0, skipped: "recently drained" });
    await svc.from("app_kv").upsert({ k: "email_drain", v: new Date().toISOString(), updated_at: new Date().toISOString() });

    const since = new Date(Date.now() - 7 * 864e5).toISOString();
    const { data: pending } = await svc
      .from("notifications")
      .select("id, profile_id, club_id, title, body, created_at, profiles(email, full_name, email_notifications), clubs(name)")
      .is("emailed_at", null)
      .gt("created_at", since)
      .order("created_at")
      .limit(25);

    let sent = 0;
    for (const n of pending ?? []) {
      const prof = n.profiles as unknown as { email: string; full_name: string; email_notifications: boolean } | null;
      const clubName = (n.clubs as unknown as { name: string } | null)?.name ?? "Ignyte Club Manager";
      const done = () => svc.from("notifications").update({ emailed_at: new Date().toISOString() }).eq("id", n.id);
      if (!prof?.email || prof.email_notifications === false || prof.email.endsWith("@test.ignyte")) {
        await done();
        continue;
      }
      const res = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          from,
          to: prof.email,
          subject: `${n.title} · ${clubName}`,
          html: `<div style="font-family:system-ui,sans-serif;max-width:520px;margin:0 auto;padding:24px">
            <p style="font-size:13px;color:#888;margin:0 0 12px">${esc(clubName)}</p>
            <h2 style="font-size:18px;margin:0 0 8px">${esc(n.title)}</h2>
            <p style="font-size:15px;line-height:1.5;color:#333">${esc(n.body)}</p>
            <p style="margin-top:20px"><a href="${appUrl}/dashboard" style="background:#f43f0c;color:#fff;padding:10px 18px;border-radius:8px;text-decoration:none;font-size:14px">Open the app</a></p>
            <p style="font-size:12px;color:#999;margin-top:24px">You can turn email notifications off from your Money page.</p>
          </div>`,
        }),
      });
      if (res.ok) {
        await done();
        sent++;
      } else if (res.status >= 400 && res.status < 500 && res.status !== 429) {
        await done(); // bad address etc — don't retry forever
      } else {
        break; // rate limited / down — resume next drain
      }
    }
    return json({ sent, pending: (pending ?? []).length });
  } catch (e) {
    return json({ error: (e as Error).message }, 500);
  }
});
