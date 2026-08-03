// Ignyte Club Manager — migration/import edge function.
//
// Brings a club over from another system. Club admins call this to:
//   { action: "invite_coach",  club_id, name, email, disciplines?, levels?, rate? }
//   { action: "invite_family", club_id, name, email, athletes: [{name, dob, notes?}],
//     coach_id?, slot_id?, weekly? }
//
// New people get Supabase's built-in invite email — they click the link and
// only have to choose a password (the club has set everything else up).
// People who already have an Ignyte login are attached without an email.
//
// NOTE: Supabase's default SMTP is heavily rate-limited (a few emails/hour).
// For a real migration batch, set up custom SMTP in Supabase → Auth settings.

import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const body = await req.json().catch(() => ({}));
    const { action, club_id } = body as { action: string; club_id: string };
    const name = String(body.name ?? "").trim();
    const email = String(body.email ?? "").trim().toLowerCase();
    if (!club_id || !name || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
      return json({ error: "Name, a valid email and club are required." }, 400);
    }

    const anon = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: userData } = await anon.auth.getUser();
    if (!userData?.user) return json({ error: "Sign in first." }, 401);

    const svc = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    const { data: adm } = await svc
      .from("club_members")
      .select("role")
      .eq("club_id", club_id)
      .eq("profile_id", userData.user.id)
      .eq("status", "active")
      .single();
    if (adm?.role !== "admin") return json({ error: "Only this club's admins can import people." }, 403);

    // Existing account? Attach without an email. Otherwise send the invite.
    let profileId: string;
    let invited = false;
    const { data: existing } = await svc.from("profiles").select("id").eq("email", email).maybeSingle();
    if (existing) {
      profileId = existing.id;
    } else {
      const redirectTo = `${new URL(req.headers.get("Origin") ?? "https://ignyte-club-manager.nathansmith00.workers.dev").origin}/welcome`;
      const { data: inviteData, error: inviteErr } = await svc.auth.admin.inviteUserByEmail(email, {
        data: { full_name: name },
        redirectTo,
      });
      if (inviteErr || !inviteData?.user) {
        return json({ error: inviteErr?.message ?? "Couldn't send the invite email." }, 500);
      }
      profileId = inviteData.user.id;
      invited = true;
      // the auth trigger created the profile; make sure the name stuck
      await svc.from("profiles").update({ full_name: name }).eq("id", profileId).eq("full_name", email.split("@")[0]);
    }

    if (action === "invite_coach") {
      const { error } = await svc.rpc("admin_import_coach", {
        p_club: club_id,
        p_profile: profileId,
        p_disciplines: Array.isArray(body.disciplines) && body.disciplines.length ? body.disciplines : null,
        p_levels: body.levels ? String(body.levels) : null,
        p_rate: body.rate != null && body.rate !== "" ? Number(body.rate) : null,
      });
      if (error) return json({ error: error.message }, 500);
      return json({ ok: true, invited });
    }

    if (action === "invite_family") {
      const athletes = Array.isArray(body.athletes) ? body.athletes : [];
      if (!athletes.length) return json({ error: "Add at least one athlete." }, 400);
      const { data, error } = await svc.rpc("admin_import_family", {
        p_club: club_id,
        p_profile: profileId,
        p_athletes: athletes,
        p_coach: body.coach_id || null,
        p_slot: body.slot_id || null,
        p_weekly: body.weekly !== false,
      });
      if (error) return json({ error: error.message }, 500);
      return json({ ok: true, invited, ...data });
    }

    return json({ error: "Unknown action." }, 400);
  } catch (e) {
    return json({ error: (e as Error).message }, 500);
  }
});
