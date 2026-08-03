// Ignyte Club Manager — card payments edge function.
//
// Each club connects its OWN Stripe account (a restricted key stored in
// club_payment_keys, readable only by the service role). Families pay an
// invoice through Stripe Checkout on the club's account — the money never
// touches Ignyte, and Ignyte adds no fee on top.
//
// actions:
//   { action: "checkout", invoice_id, return_url } -> { url }
//   { action: "confirm",  invoice_id, session_id } -> { paid }
//
// Deploy: supabase functions deploy pay --no-verify-jwt=false
// (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / SUPABASE_ANON_KEY are injected.)

import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const auth = req.headers.get("Authorization") ?? "";
    const body = await req.json().catch(() => ({}));
    const { action, invoice_id } = body as { action: string; invoice_id: string };
    if (!invoice_id) return json({ error: "invoice_id required" }, 400);

    // Who is asking? (validates the JWT)
    const anon = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: auth } } },
    );
    const { data: userData, error: userErr } = await anon.auth.getUser();
    if (userErr || !userData?.user) return json({ error: "Sign in first." }, 401);

    // Service client for privileged reads/writes.
    const svc = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data: inv } = await svc.from("invoices").select("*").eq("id", invoice_id).single();
    if (!inv) return json({ error: "Invoice not found." }, 404);
    if (inv.profile_id !== userData.user.id) {
      // club admins may reconcile any of their club's invoices
      const { data: adm } = await svc
        .from("club_members")
        .select("role")
        .eq("club_id", inv.club_id)
        .eq("profile_id", userData.user.id)
        .eq("status", "active")
        .single();
      if (adm?.role !== "admin" || action === "checkout") return json({ error: "Not your invoice." }, 403);
    }

    const { data: keys } = await svc
      .from("club_payment_keys")
      .select("secret_key, pass_fees, fee_percent, fee_fixed")
      .eq("club_id", inv.club_id)
      .single();
    if (!keys) return json({ error: "This club hasn't switched on card payments." }, 400);

    const { data: settings } = await svc
      .from("club_settings")
      .select("currency")
      .eq("club_id", inv.club_id)
      .single();
    const currency = CURRENCIES[settings?.currency ?? "£"] ?? "gbp";

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
        const fee =
          Math.round((Number(inv.amount) * Number(keys.fee_percent)) ) + // pennies from %: amount*100 * pct/100
          Math.round(Number(keys.fee_fixed) * 100);
        if (fee > 0) {
          params["line_items[1][quantity]"] = "1";
          params["line_items[1][price_data][currency]"] = currency;
          params["line_items[1][price_data][unit_amount]"] = String(fee);
          params["line_items[1][price_data][product_data][name]"] = "Payment processing fee";
        }
      }
      // No payment_method_types: Stripe shows every method the club has enabled
      // in its own dashboard — cards, Apple/Google Pay, Bacs Direct Debit, PayPal…
      const session = await stripe(keys.secret_key, "checkout/sessions", params);
      await svc
        .from("invoices")
        .update({ meta: { ...(inv.meta ?? {}), stripe_session: session.id } })
        .eq("id", inv.id);
      return json({ url: session.url });
    }

    if (action === "confirm") {
      // session_id comes from the checkout return URL; reconciles (e.g. a Bacs
      // Direct Debit clearing days later) fall back to the stored session.
      const sessionId = String(body.session_id ?? inv.meta?.stripe_session ?? "");
      if (!sessionId.startsWith("cs_")) return json({ error: "No online payment to check for this invoice." }, 400);
      const session = await stripe(keys.secret_key, `checkout/sessions/${sessionId}`);
      if (session?.metadata?.invoice_id !== inv.id) return json({ error: "Session mismatch." }, 400);

      if (session?.payment_status === "paid" || session?.payment_status === "no_payment_required") {
        const { error: settleErr } = await svc.rpc("_settle_invoice", {
          p_invoice: inv.id,
          p_method: "online",
          p_reference: String(session.payment_intent ?? sessionId),
        });
        if (settleErr) return json({ error: settleErr.message }, 500);
        return json({ paid: true });
      }

      // Completed checkout, money not landed yet = async method (Direct Debit).
      if (session?.status === "complete") {
        if (!inv.meta?.dd_processing) {
          await svc
            .from("invoices")
            .update({ meta: { ...(inv.meta ?? {}), stripe_session: sessionId, dd_processing: true } })
            .eq("id", inv.id);
        }
        return json({ paid: false, processing: true });
      }
      return json({ paid: false });
    }

    return json({ error: "Unknown action." }, 400);
  } catch (e) {
    return json({ error: (e as Error).message }, 500);
  }
});
