// Ignyte Club Manager — payments edge function.
//
// Each club connects its OWN Stripe account (restricted key in
// club_payment_keys, service-role-only). Ignyte adds no fee.
//
// actions:
//   { action: "checkout", invoice_id, return_url }        -> { url }
//   { action: "confirm",  invoice_id, session_id? }        -> { paid, processing? }
//   { action: "setup",    club_id, return_url }            -> { url }        save a card/DD for auto-pay
//   { action: "setup_confirm", club_id, session_id }       -> { saved, label }
//   { action: "autocollect" }                              -> { collected }  drain due invoices w/ saved methods
//
// Deploy: supabase functions deploy pay

import { createClient, SupabaseClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const CURRENCIES: Record<string, string> = { "£": "gbp", "$": "usd", "€": "eur" };

async function stripe(key: string, path: string, params?: Record<string, string>) {
  const res = await fetch(`https://api.stripe.com/v1/${path}`, {
    method: params ? "POST" : "GET",
    headers: {
      Authorization: `Bearer ${key}`,
      ...(params ? { "Content-Type": "application/x-www-form-urlencoded" } : {}),
    },
    body: params ? new URLSearchParams(params) : undefined,
  });
  const data = await res.json();
  if (!res.ok) throw new Error(data?.error?.message ?? `Stripe error (${res.status})`);
  return data;
}

async function clubKeys(svc: SupabaseClient, clubId: string) {
  const { data } = await svc
    .from("club_payment_keys")
    .select("secret_key, pass_fees, fee_percent, fee_fixed")
    .eq("club_id", clubId)
    .single();
  return data;
}

async function clubCurrency(svc: SupabaseClient, clubId: string) {
  const { data } = await svc.from("club_settings").select("currency").eq("club_id", clubId).single();
  return CURRENCIES[data?.currency ?? "£"] ?? "gbp";
}

/** best-effort drain lock in app_kv; returns false if drained recently */
async function drainLock(svc: SupabaseClient, key: string, seconds: number) {
  const { data } = await svc.from("app_kv").select("v").eq("k", key).maybeSingle();
  const last = data?.v ? Date.parse(data.v) : 0;
  if (Date.now() - last < seconds * 1000) return false;
  await svc.from("app_kv").upsert({ k: key, v: new Date().toISOString(), updated_at: new Date().toISOString() });
  return true;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const body = await req.json().catch(() => ({}));
    const action = String(body.action ?? "");

    const anon = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: userData } = await anon.auth.getUser();
    if (!userData?.user) return json({ error: "Sign in first." }, 401);
    const uid = userData.user.id;

    const svc = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    // ---------- invoice checkout / confirm ----------
    if (action === "checkout" || action === "confirm") {
      const invoice_id = String(body.invoice_id ?? "");
      if (!invoice_id) return json({ error: "invoice_id required" }, 400);
      const { data: inv } = await svc.from("invoices").select("*").eq("id", invoice_id).single();
      if (!inv) return json({ error: "Invoice not found." }, 404);
      if (inv.profile_id !== uid) {
        const { data: adm } = await svc
          .from("club_members").select("role")
          .eq("club_id", inv.club_id).eq("profile_id", uid).eq("status", "active").single();
        if (adm?.role !== "admin" || action === "checkout") return json({ error: "Not your invoice." }, 403);
      }
      const keys = await clubKeys(svc, inv.club_id);
      if (!keys) return json({ error: "This club hasn't switched on card payments." }, 400);
      const currency = await clubCurrency(svc, inv.club_id);

      if (action === "checkout") {
        if (!["due", "overdue"].includes(inv.status)) return json({ error: "This invoice is already settled." }, 400);
        const returnUrl = String(body.return_url ?? "");
        if (!/^https?:\/\//.test(returnUrl)) return json({ error: "Bad return_url." }, 400);
        const params: Record<string, string> = {
          mode: "payment",
          "line_items[0][quantity]": "1",
          "line_items[0][price_data][currency]": currency,
          "line_items[0][price_data][unit_amount]": String(Math.round(Number(inv.amount) * 100)),
          "line_items[0][price_data][product_data][name]": inv.description.slice(0, 120),
          success_url: `${returnUrl}?paid={CHECKOUT_SESSION_ID}&inv=${inv.id}`,
          cancel_url: returnUrl,
          "metadata[invoice_id]": inv.id,
        };
        if (keys.pass_fees) {
          const fee = Math.round(Number(inv.amount) * Number(keys.fee_percent)) + Math.round(Number(keys.fee_fixed) * 100);
          if (fee > 0) {
            params["line_items[1][quantity]"] = "1";
            params["line_items[1][price_data][currency]"] = currency;
            params["line_items[1][price_data][unit_amount]"] = String(fee);
            params["line_items[1][price_data][product_data][name]"] = "Payment processing fee";
          }
        }
        const session = await stripe(keys.secret_key, "checkout/sessions", params);
        await svc.from("invoices").update({ meta: { ...(inv.meta ?? {}), stripe_session: session.id } }).eq("id", inv.id);
        return json({ url: session.url });
      }

      // confirm / reconcile
      const sessionId = String(body.session_id ?? inv.meta?.stripe_session ?? "");
      if (!sessionId.startsWith("cs_")) return json({ error: "No online payment to check for this invoice." }, 400);
      const session = await stripe(keys.secret_key, `checkout/sessions/${sessionId}`);
      if (session?.metadata?.invoice_id !== inv.id) return json({ error: "Session mismatch." }, 400);
      if (session?.payment_status === "paid" || session?.payment_status === "no_payment_required") {
        const { error: settleErr } = await svc.rpc("_settle_invoice", {
          p_invoice: inv.id, p_method: "online", p_reference: String(session.payment_intent ?? sessionId),
        });
        if (settleErr) return json({ error: settleErr.message }, 500);
        return json({ paid: true });
      }
      if (session?.status === "complete") {
        if (!inv.meta?.dd_processing) {
          await svc.from("invoices")
            .update({ meta: { ...(inv.meta ?? {}), stripe_session: sessionId, dd_processing: true } })
            .eq("id", inv.id);
        }
        return json({ paid: false, processing: true });
      }
      return json({ paid: false });
    }

    // ---------- auto-pay: save a method ----------
    if (action === "setup" || action === "setup_confirm") {
      const club_id = String(body.club_id ?? "");
      if (!club_id) return json({ error: "club_id required" }, 400);
      const { data: member } = await svc
        .from("club_members").select("role")
        .eq("club_id", club_id).eq("profile_id", uid).eq("status", "active").single();
      if (!member) return json({ error: "Join this club first." }, 403);
      const keys = await clubKeys(svc, club_id);
      if (!keys) return json({ error: "This club hasn't switched on card payments." }, 400);

      const { data: existing } = await svc
        .from("club_customers").select("*").eq("club_id", club_id).eq("profile_id", uid).maybeSingle();

      if (action === "setup") {
        const returnUrl = String(body.return_url ?? "");
        if (!/^https?:\/\//.test(returnUrl)) return json({ error: "Bad return_url." }, 400);
        let customerId = existing?.stripe_customer_id;
        if (!customerId) {
          const { data: prof } = await svc.from("profiles").select("full_name, email").eq("id", uid).single();
          const customer = await stripe(keys.secret_key, "customers", {
            email: prof?.email ?? "", name: prof?.full_name ?? "", "metadata[profile_id]": uid,
          });
          customerId = customer.id;
          await svc.from("club_customers").upsert({
            club_id, profile_id: uid, stripe_customer_id: customerId, updated_at: new Date().toISOString(),
          });
        }
        const session = await stripe(keys.secret_key, "checkout/sessions", {
          mode: "setup",
          customer: customerId!,
          success_url: `${returnUrl}?setup={CHECKOUT_SESSION_ID}`,
          cancel_url: returnUrl,
          "metadata[club_id]": club_id,
        });
        return json({ url: session.url });
      }

      // setup_confirm
      const sessionId = String(body.session_id ?? "");
      if (!sessionId.startsWith("cs_")) return json({ error: "Bad session_id." }, 400);
      const session = await stripe(keys.secret_key, `checkout/sessions/${sessionId}`);
      if (session?.metadata?.club_id !== club_id || !session?.setup_intent) return json({ error: "Session mismatch." }, 400);
      const si = await stripe(keys.secret_key, `setup_intents/${session.setup_intent}`);
      if (!si?.payment_method) return json({ saved: false });
      const pm = await stripe(keys.secret_key, `payment_methods/${si.payment_method}`);
      const label = pm.card ? `${pm.card.brand} •••• ${pm.card.last4}`
        : pm.bacs_debit ? `Direct Debit •••• ${pm.bacs_debit.last4}`
        : pm.type;
      await svc.from("club_customers").upsert({
        club_id, profile_id: uid,
        stripe_customer_id: String(si.customer ?? existing?.stripe_customer_id ?? ""),
        payment_method_id: String(si.payment_method),
        method_label: label, auto_pay: true, updated_at: new Date().toISOString(),
      });
      return json({ saved: true, label });
    }

    // ---------- auto-collect: drain due invoices with saved methods ----------
    if (action === "autocollect") {
      if (!(await drainLock(svc, "autocollect", 120))) return json({ collected: 0, skipped: "recently drained" });
      const today = new Date().toISOString().slice(0, 10);

      // settle any clearing off-session Direct Debits first
      const { data: processing } = await svc
        .from("invoices").select("*")
        .in("status", ["due", "overdue"])
        .not("meta->stripe_pi", "is", null)
        .limit(10);
      for (const inv of processing ?? []) {
        const keys = await clubKeys(svc, inv.club_id);
        if (!keys) continue;
        try {
          const pi = await stripe(keys.secret_key, `payment_intents/${inv.meta.stripe_pi}`);
          if (pi.status === "succeeded") {
            await svc.rpc("_settle_invoice", { p_invoice: inv.id, p_method: "online", p_reference: pi.id });
          } else if (["canceled", "requires_payment_method"].includes(pi.status)) {
            const meta = { ...(inv.meta ?? {}) };
            delete meta.dd_processing; delete meta.stripe_pi;
            await svc.from("invoices").update({ meta }).eq("id", inv.id);
          }
        } catch (_e) { /* retry next drain */ }
      }
      const { data: due } = await svc
        .from("invoices")
        .select("*")
        .in("status", ["due", "overdue"])
        .lte("due_date", today)
        .limit(25);
      let collected = 0;
      for (const inv of due ?? []) {
        if (inv.meta?.autopay_attempted === today || inv.meta?.dd_processing) continue;
        const { data: cust } = await svc
          .from("club_customers").select("*")
          .eq("club_id", inv.club_id).eq("profile_id", inv.profile_id)
          .eq("auto_pay", true).not("payment_method_id", "is", null).maybeSingle();
        if (!cust) continue;
        const keys = await clubKeys(svc, inv.club_id);
        if (!keys) continue;
        await svc.from("invoices")
          .update({ meta: { ...(inv.meta ?? {}), autopay_attempted: today } }).eq("id", inv.id);
        try {
          const currency = await clubCurrency(svc, inv.club_id);
          const pi = await stripe(keys.secret_key, "payment_intents", {
            amount: String(Math.round(Number(inv.amount) * 100)),
            currency,
            customer: cust.stripe_customer_id,
            payment_method: cust.payment_method_id,
            off_session: "true",
            confirm: "true",
            description: inv.description.slice(0, 120),
            "metadata[invoice_id]": inv.id,
          });
          if (pi.status === "succeeded") {
            await svc.rpc("_settle_invoice", { p_invoice: inv.id, p_method: "online", p_reference: pi.id });
            collected++;
          } else if (pi.status === "processing") {
            await svc.from("invoices")
              .update({ meta: { ...(inv.meta ?? {}), autopay_attempted: today, dd_processing: true, stripe_pi: pi.id } })
              .eq("id", inv.id);
          }
        } catch (_e) {
          // card declined / mandate failed — the normal chasing flow takes over
        }
      }
      return json({ collected });
    }

    return json({ error: "Unknown action." }, 400);
  } catch (e) {
    return json({ error: (e as Error).message }, 500);
  }
});
