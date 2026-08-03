-- ============================================================================
-- IGNYTE CLUB MANAGER — v6 "GET PAID" (ADDITIVE — run after v5)
-- ----------------------------------------------------------------------------
--   1. CARD PAYMENTS — each club connects its OWN Stripe account (restricted
--      key). Families hit "Pay by card" on an invoice → Stripe Checkout on the
--      club's account → invoice settles itself. Ignyte adds 0%; the only fee
--      is Stripe's own. Optional fee pass-on adds a card-fee line at checkout.
--   2. REGISTERS — 'ill' and 'injured' attendance reasons (the register tells
--      the truth, and coaches spot patterns).
--   3. TRIAL FOLLOW-UPS — the day after an attended trial, the family gets a
--      nudge to enrol and the admins get a heads-up. Trials become a pipeline.
--   4. FAIR WAITING LISTS — siblings of already-enrolled athletes get first
--      claim when a class space opens (families train together).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Attendance reasons (safe: values only added, used at runtime)
-- ---------------------------------------------------------------------------
alter type public.attendance_status add value if not exists 'ill';
alter type public.attendance_status add value if not exists 'injured';

-- ---------------------------------------------------------------------------
-- Per-club Stripe keys. RLS enabled with NO policies: nobody but the
-- service_role (edge functions) can ever read a key back out.
-- ---------------------------------------------------------------------------
create table public.club_payment_keys (
  club_id uuid primary key references public.clubs (id) on delete cascade,
  provider text not null default 'stripe' check (provider = 'stripe'),
  secret_key text not null,
  pass_fees boolean not null default false,
  fee_percent numeric(5, 2) not null default 1.5 check (fee_percent between 0 and 10),
  fee_fixed numeric(6, 2) not null default 0.20 check (fee_fixed between 0 and 5),
  updated_by uuid references public.profiles (id),
  updated_at timestamptz not null default now()
);
alter table public.club_payment_keys enable row level security;

alter table public.club_settings
  add column if not exists card_payments_enabled boolean not null default false;

-- Admin stores/rotates the club's key. We never echo it back.
create or replace function public.admin_set_stripe_key (
  p_club uuid, p_secret text, p_pass_fees boolean default false,
  p_fee_percent numeric default 1.5, p_fee_fixed numeric default 0.20
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin_of(p_club) then raise exception 'Admins only.'; end if;
  if nullif(trim(p_secret), '') is null then
    delete from club_payment_keys where club_id = p_club;
    update club_settings set card_payments_enabled = false where club_id = p_club;
    perform owner_log(p_club, 'stripe_disconnected', null);
    return;
  end if;
  if p_secret !~ '^(rk|sk)_(live|test)_' then
    raise exception 'That doesn''t look like a Stripe secret key — copy the Restricted key (rk_live_…) from Stripe → Developers → API keys.';
  end if;
  insert into club_payment_keys (club_id, secret_key, pass_fees, fee_percent, fee_fixed, updated_by)
  values (p_club, trim(p_secret), coalesce(p_pass_fees, false), coalesce(p_fee_percent, 1.5), coalesce(p_fee_fixed, 0.20), auth.uid())
  on conflict (club_id) do update set
    secret_key = excluded.secret_key, pass_fees = excluded.pass_fees,
    fee_percent = excluded.fee_percent, fee_fixed = excluded.fee_fixed,
    updated_by = excluded.updated_by, updated_at = now();
  update club_settings set card_payments_enabled = true where club_id = p_club;
  perform owner_log(p_club, 'stripe_connected', case when p_secret like 'rk_%' then 'restricted key' else 'secret key' end);
end;
$$;

-- Settle an invoice from a verified card payment. service_role only — called
-- by the edge function after Stripe confirms the Checkout Session is paid.
create or replace function public._settle_invoice (p_invoice uuid, p_method text, p_reference text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_i invoices%rowtype;
  v_credits int;
  v_symbol text;
begin
  select * into v_i from invoices where id = p_invoice for update;
  if v_i.id is null then raise exception 'Invoice not found.'; end if;
  if v_i.status not in ('due', 'overdue') then return; end if; -- idempotent for retries

  update invoices set status = 'paid', paid_at = now(), paid_method = p_method, paid_reference = p_reference
    where id = p_invoice;
  insert into payments (club_id, invoice_id, profile_id, amount, method, reference, received_by)
  values (v_i.club_id, p_invoice, v_i.profile_id, v_i.amount, p_method, p_reference, null);

  v_credits := coalesce((v_i.meta ->> 'grant_credits')::int, 0);
  if v_credits > 0 then
    insert into credit_ledger (club_id, profile_id, delta, reason, created_by)
    values (v_i.club_id, v_i.profile_id, v_credits, 'Included with: ' || v_i.description, null);
  end if;

  select currency into v_symbol from club_settings where club_id = v_i.club_id;
  perform notify(v_i.profile_id, v_i.club_id, 'payment_received', 'Payment received — thank you! ✅',
    v_i.description || ' (' || coalesce(v_symbol, '£') || v_i.amount || ') is paid.'
    || case when v_credits > 0 then ' ' || v_credits || ' lesson credit(s) added.' else '' end,
    jsonb_build_object('invoice_id', p_invoice));
end;
$$;

-- ---------------------------------------------------------------------------
-- Trial follow-ups: the day after an attended trial with no enrolment,
-- nudge the family and brief the admins. Once per trial.
-- ---------------------------------------------------------------------------
create or replace function public.send_trial_followups () returns int
language plpgsql security definer set search_path = public as $$
declare
  r record;
  a record;
  v_count int := 0;
begin
  for r in
    select t.id, t.club_id, t.class_id, t.booked_by, t.athlete_id,
           g.name as class_name, ath.name as athlete_name, s.session_date
    from class_trials t
    join clubs c on c.id = t.club_id and c.status = 'active'
    join class_groups g on g.id = t.class_id
    join class_sessions s on s.id = t.session_id
    join athletes ath on ath.id = t.athlete_id
    where t.status = 'attended'
      and s.session_date < current_date
      and not exists (select 1 from class_enrolments e
                      where e.class_id = t.class_id and e.athlete_id = t.athlete_id
                        and e.status in ('enrolled', 'waiting'))
      and not exists (select 1 from notifications n
                      where n.type = 'trial_followup' and (n.data ->> 'trial_id')::uuid = t.id)
  loop
    perform notify(r.booked_by, r.club_id, 'trial_followup', 'How was the taster? ⭐',
      r.athlete_name || ' tried ' || r.class_name || ' — spaces go fast, secure a regular spot from the Classes page.',
      jsonb_build_object('trial_id', r.id, 'class_id', r.class_id));
    for a in select profile_id from club_members
             where club_id = r.club_id and role = 'admin' and status = 'active' loop
      perform notify(a.profile_id, r.club_id, 'trial_followup', 'Trial to follow up',
        r.athlete_name || ' trialled ' || r.class_name || ' on ' || to_char(r.session_date, 'DD Mon')
        || ' and hasn''t enrolled yet — a quick message might land the sign-up.',
        jsonb_build_object('trial_id', r.id, 'class_id', r.class_id));
    end loop;
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- Sibling-priority waiting list: when a class space opens, a waiting athlete
-- whose sibling already trains in the class jumps the queue (then FIFO).
-- ---------------------------------------------------------------------------
create or replace function public.leave_class (p_class uuid, p_athlete uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_g class_groups%rowtype;
  v_was text;
  v_next record;
begin
  select * into v_g from class_groups where id = p_class for update;
  if v_g.id is null then raise exception 'Class not found.'; end if;
  if not (owns_athlete(p_athlete) or is_admin_of(v_g.club_id)) then
    raise exception 'You can only manage your own athletes.';
  end if;
  select status into v_was from class_enrolments where class_id = p_class and athlete_id = p_athlete;
  if v_was is null or v_was = 'left' then raise exception 'This athlete isn''t in this class.'; end if;
  update class_enrolments set status = 'left', left_at = now()
    where class_id = p_class and athlete_id = p_athlete;

  if v_was = 'enrolled' then
    select e.athlete_id, coalesce(a.parent_id, a.profile_id) as owner_id, a.name
      into v_next
      from class_enrolments e
      join athletes a on a.id = e.athlete_id
      where e.class_id = p_class and e.status = 'waiting'
      order by
        exists (select 1 from class_enrolments e2
                join athletes a2 on a2.id = e2.athlete_id
                where e2.class_id = p_class and e2.status = 'enrolled'
                  and a2.parent_id is not null and a2.parent_id = a.parent_id) desc,
        e.created_at
      limit 1;
    if v_next.athlete_id is not null then
      update class_enrolments set status = 'enrolled'
        where class_id = p_class and athlete_id = v_next.athlete_id;
      if v_next.owner_id is not null then
        perform notify(v_next.owner_id, v_g.club_id, 'class_space', 'A space opened up! 🎉',
          v_next.name || ' has moved off the waiting list into ' || v_g.name || '.',
          jsonb_build_object('class_id', p_class));
      end if;
    end if;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Lock-down & grants
-- ---------------------------------------------------------------------------
revoke execute on function
  public.admin_set_stripe_key (uuid, text, boolean, numeric, numeric),
  public._settle_invoice (uuid, text, text),
  public.send_trial_followups ()
from public, anon, authenticated;

grant execute on function
  public.admin_set_stripe_key (uuid, text, boolean, numeric, numeric)
to authenticated, service_role;

grant execute on function
  public._settle_invoice (uuid, text, text),
  public.send_trial_followups ()
to service_role;

-- ---------------------------------------------------------------------------
-- Cron (guarded)
-- ---------------------------------------------------------------------------
do $cron$
begin
  perform cron.schedule('ignyte-trial-followups', '0 18 * * *', 'select public.send_trial_followups()');
exception when others then
  raise notice 'pg_cron unavailable (%).', sqlerrm;
end;
$cron$;
