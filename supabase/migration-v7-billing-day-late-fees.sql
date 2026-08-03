-- ============================================================================
-- IGNYTE CLUB MANAGER — v7 "BILLING RHYTHM" (ADDITIVE — run after v6)
-- ----------------------------------------------------------------------------
--   1. BILLING DAY — each club picks the day of the month (1–28) its
--      membership invoices go out. The generator now runs daily and fires
--      only on each club's chosen day.
--   2. LATE FEES — optional per-club: after N grace days overdue, a fixed
--      late fee is added to the invoice once, and the payer is told.
-- ============================================================================

alter table public.club_settings
  add column if not exists billing_day int not null default 1 check (billing_day between 1 and 28),
  add column if not exists late_fee_amount numeric(8, 2) not null default 0 check (late_fee_amount between 0 and 100),
  add column if not exists late_fee_after_days int not null default 7 check (late_fee_after_days between 0 and 60);

-- Membership generator: now daily, per-club billing day.
create or replace function public.generate_membership_invoices () returns int
language plpgsql security definer set search_path = public as $$
declare
  r record;
  v_count int := 0;
begin
  for r in
    select m.id from memberships m
    join clubs c on c.id = m.club_id and c.status = 'active'
    join club_settings cs on cs.club_id = m.club_id
    where m.status = 'active'
      and coalesce(cs.billing_day, 1) = least(extract(day from current_date)::int, 28)
  loop
    if _membership_invoice(r.id, current_date) is not null then v_count := v_count + 1; end if;
  end loop;
  return v_count;
end;
$$;

-- Overdue sweep: flip due -> overdue, then apply late fees past the grace window.
create or replace function public.mark_overdue_invoices () returns int
language plpgsql security definer set search_path = public as $$
declare
  r record;
  v_count int := 0;
  v_symbol text;
begin
  for r in
    select i.* from invoices i
    join clubs c on c.id = i.club_id and c.status = 'active'
    where i.status = 'due' and i.due_date < current_date
  loop
    update invoices set status = 'overdue' where id = r.id;
    select currency into v_symbol from club_settings where club_id = r.club_id;
    perform notify(r.profile_id, r.club_id, 'invoice_overdue', 'Invoice overdue',
      r.description || ' — ' || coalesce(v_symbol, '£') || r.amount || ' was due '
      || to_char(r.due_date, 'DD Mon') || '. See your Money page for how to pay.',
      jsonb_build_object('invoice_id', r.id));
    v_count := v_count + 1;
  end loop;

  for r in
    select i.id, i.profile_id, i.club_id, i.description, cs.late_fee_amount, cs.currency
    from invoices i
    join clubs c on c.id = i.club_id and c.status = 'active'
    join club_settings cs on cs.club_id = i.club_id
    where i.status = 'overdue'
      and cs.late_fee_amount > 0
      and i.due_date < current_date - cs.late_fee_after_days
      and (i.meta ->> 'late_fee_applied') is null
      and (i.meta ->> 'dd_processing') is null -- a clearing Direct Debit is not late
  loop
    update invoices set
      amount = amount + r.late_fee_amount,
      meta = meta || jsonb_build_object('late_fee_applied', r.late_fee_amount)
    where id = r.id;
    perform notify(r.profile_id, r.club_id, 'late_fee', 'Late fee added',
      'A ' || coalesce(r.currency, '£') || r.late_fee_amount || ' late fee was added to "'
      || r.description || '" — the club''s grace period has passed. Paying today stops any further action.',
      jsonb_build_object('invoice_id', r.id));
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- Payment settings now carry billing day + late fee policy.
drop function if exists public.update_payment_settings (uuid, text, text, text, int);
create or replace function public.update_payment_settings (
  p_club uuid, p_currency text, p_instructions text, p_link text, p_due_days int,
  p_billing_day int default null, p_late_fee numeric default null, p_late_fee_days int default null
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin_of(p_club) then raise exception 'Admins only.'; end if;
  if p_link is not null and p_link <> '' and p_link !~ '^https://' then
    raise exception 'The payment link must start with https://';
  end if;
  update club_settings set
    currency = coalesce(nullif(trim(p_currency), ''), '£'),
    payment_instructions = nullif(trim(p_instructions), ''),
    payment_link_url = nullif(trim(p_link), ''),
    invoice_due_days = coalesce(p_due_days, 7),
    billing_day = coalesce(p_billing_day, billing_day),
    late_fee_amount = coalesce(p_late_fee, late_fee_amount),
    late_fee_after_days = coalesce(p_late_fee_days, late_fee_after_days)
  where club_id = p_club;
  perform owner_log(p_club, 'update_payment_settings', null);
end;
$$;

revoke execute on function
  public.update_payment_settings (uuid, text, text, text, int, int, numeric, int)
from public, anon, authenticated;
grant execute on function
  public.update_payment_settings (uuid, text, text, text, int, int, numeric, int)
to authenticated, service_role;

-- The membership generator now runs daily (billing day is per club).
do $cron$
begin
  perform cron.unschedule('ignyte-membership-invoices');
  perform cron.schedule('ignyte-membership-invoices', '0 6 * * *', 'select public.generate_membership_invoices()');
exception when others then
  raise notice 'pg_cron unavailable (%).', sqlerrm;
end;
$cron$;
