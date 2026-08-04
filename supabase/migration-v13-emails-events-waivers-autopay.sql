-- ============================================================================
-- IGNYTE CLUB MANAGER — v13 "THE WORKS" (ADDITIVE — run after v12)
-- ----------------------------------------------------------------------------
--   1. EMAIL — notifications gain an email pipeline (drained by the
--      send-emails edge function via Resend; per-user opt-out).
--   2. WAIVERS — clubs publish T&Cs/consent; members sign by typed name;
--      re-signing required when the text changes; admins see who's signed.
--   3. EVENTS — comps, showcases, camps: date, fee, capacity; sign-ups
--      auto-invoice with the money module; events show on the club website.
--   4. AUTO-PAY — families save a card/Direct Debit once (Stripe mode=setup);
--      due invoices then collect themselves off-session.
--   5. MEDIA — public 'club-media' storage bucket for shop/site images.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Email pipeline
-- ---------------------------------------------------------------------------
alter table public.notifications add column if not exists emailed_at timestamptz;
alter table public.profiles add column if not exists email_notifications boolean not null default true;
create index if not exists notifications_email_idx on public.notifications (created_at)
  where emailed_at is null;

-- tiny service-only kv (drain locks etc)
create table if not exists public.app_kv (
  k text primary key,
  v text,
  updated_at timestamptz not null default now()
);
alter table public.app_kv enable row level security; -- no policies: service role only

-- ---------------------------------------------------------------------------
-- 2. Waivers & consent
-- ---------------------------------------------------------------------------
alter table public.club_settings
  add column if not exists waiver_text text,
  add column if not exists waiver_updated_at timestamptz;

create table public.waiver_signatures (
  club_id uuid not null references public.clubs (id) on delete cascade,
  profile_id uuid not null references public.profiles (id) on delete cascade,
  waiver_version timestamptz not null,
  signed_name text not null check (char_length(signed_name) between 2 and 80),
  signed_at timestamptz not null default now(),
  primary key (club_id, profile_id, waiver_version)
);
alter table public.waiver_signatures enable row level security;
create policy waiver_sigs_select on public.waiver_signatures for select to authenticated
  using (profile_id = auth.uid() or is_admin_of(club_id));

create or replace function public.update_club_waiver (p_club uuid, p_text text)
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if not is_admin_of(p_club) then raise exception 'Admins only.'; end if;
  update club_settings set waiver_text = nullif(trim(p_text), ''),
    waiver_updated_at = case when nullif(trim(p_text), '') is null then null else now() end
  where club_id = p_club;
  if nullif(trim(p_text), '') is not null then
    for r in select profile_id from club_members
             where club_id = p_club and status = 'active' and role in ('parent', 'athlete') loop
      perform notify(r.profile_id, p_club, 'waiver', '📜 Please sign the club agreement',
        (select name from clubs where id = p_club) || ' updated its terms & consent — sign from your Waiver page.',
        '{}'::jsonb);
    end loop;
  end if;
  perform owner_log(p_club, 'update_waiver', null);
end;
$$;

create or replace function public.sign_waiver (p_club uuid, p_name text)
returns void language plpgsql security definer set search_path = public as $$
declare v_version timestamptz;
begin
  if not exists (select 1 from club_members
      where club_id = p_club and profile_id = auth.uid() and status = 'active') then
    raise exception 'Join the club first.';
  end if;
  select waiver_updated_at into v_version from club_settings where club_id = p_club;
  if v_version is null then raise exception 'This club has no waiver to sign.'; end if;
  if char_length(trim(p_name)) < 2 then raise exception 'Type your full name to sign.'; end if;
  insert into waiver_signatures (club_id, profile_id, waiver_version, signed_name)
  values (p_club, auth.uid(), v_version, trim(p_name))
  on conflict do nothing;
end;
$$;

create or replace function public.waiver_status (p_club uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'required', s.waiver_updated_at is not null,
    'text', s.waiver_text,
    'updated_at', s.waiver_updated_at,
    'signed', exists (select 1 from waiver_signatures w
                      where w.club_id = p_club and w.profile_id = auth.uid()
                        and w.waiver_version = s.waiver_updated_at))
  from club_settings s where s.club_id = p_club
    and p_club in (select my_club_ids())
$$;

-- ---------------------------------------------------------------------------
-- 3. Events
-- ---------------------------------------------------------------------------
create table public.events (
  id uuid primary key default gen_random_uuid (),
  club_id uuid not null references public.clubs (id) on delete cascade,
  name text not null check (char_length(name) between 2 and 80),
  description text,
  event_date date not null,
  start_time time,
  end_time time,
  location_id uuid references public.locations (id),
  fee numeric(8, 2) check (fee >= 0),
  capacity int check (capacity > 0),
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create index events_club_idx on public.events (club_id, event_date);

create table public.event_signups (
  id uuid primary key default gen_random_uuid (),
  event_id uuid not null references public.events (id) on delete cascade,
  club_id uuid not null references public.clubs (id) on delete cascade,
  athlete_id uuid not null references public.athletes (id) on delete cascade,
  booked_by uuid not null references public.profiles (id),
  status text not null default 'booked' check (status in ('booked', 'cancelled')),
  invoice_id uuid references public.invoices (id) on delete set null,
  created_at timestamptz not null default now()
);
create unique index event_signups_uniq on public.event_signups (event_id, athlete_id) where (status = 'booked');
create index event_signups_club_idx on public.event_signups (club_id);

alter table public.events enable row level security;
alter table public.event_signups enable row level security;
create policy events_select on public.events for select to authenticated
  using (club_id in (select my_club_ids()));
create policy event_signups_select on public.event_signups for select to authenticated
  using ((club_id in (select my_club_ids())) and
         (booked_by = auth.uid() or owns_athlete(athlete_id) or is_coach_of(club_id)));

-- invoices grow an 'event' source
alter table public.invoices drop constraint invoices_source_check;
alter table public.invoices add constraint invoices_source_check
  check (source in ('manual', 'membership', 'credit_pack', 'trial', 'lessons', 'class', 'shop', 'event'));

create or replace function public.admin_save_event (
  p_club uuid, p_id uuid, p_name text, p_date date,
  p_start time default null, p_end time default null, p_location uuid default null,
  p_fee numeric default null, p_capacity int default null,
  p_description text default null, p_active boolean default true
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid := p_id;
begin
  if not is_admin_of(p_club) then raise exception 'Only club admins can manage events.'; end if;
  if v_id is null then
    insert into events (club_id, name, description, event_date, start_time, end_time, location_id, fee, capacity, active)
    values (p_club, trim(p_name), p_description, p_date, p_start, p_end, p_location, p_fee, p_capacity, p_active)
    returning id into v_id;
  else
    update events set name = trim(p_name), description = p_description, event_date = p_date,
      start_time = p_start, end_time = p_end, location_id = p_location,
      fee = p_fee, capacity = p_capacity, active = p_active
    where id = v_id and club_id = p_club;
    if not found then raise exception 'Event not found.'; end if;
  end if;
  perform owner_log(p_club, 'save_event', trim(p_name));
  return v_id;
end;
$$;

create or replace function public.signup_event (p_event uuid, p_athlete uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_e events%rowtype;
  v_id uuid;
  v_inv uuid;
  v_due int;
  v_symbol text;
  v_admin boolean;
  r record;
begin
  select * into v_e from events where id = p_event for update;
  if v_e.id is null or not v_e.active then raise exception 'Event not found.'; end if;
  if v_e.event_date < current_date then raise exception 'This event has already happened.'; end if;
  v_admin := is_admin_of(v_e.club_id);
  if not (owns_athlete(p_athlete) or v_admin) then
    raise exception 'You can only sign up your own athletes.';
  end if;
  perform assert_club_active(v_e.club_id);
  if not athlete_in_club(p_athlete, v_e.club_id) then
    raise exception 'This athlete isn''t enrolled at this club yet.';
  end if;
  if v_e.capacity is not null and not v_admin
     and (select count(*) from event_signups where event_id = p_event and status = 'booked') >= v_e.capacity then
    raise exception 'This event is full.';
  end if;

  insert into event_signups (event_id, club_id, athlete_id, booked_by)
  values (p_event, v_e.club_id, p_athlete, auth.uid())
  returning id into v_id;

  select currency, invoice_due_days into v_symbol, v_due from club_settings where club_id = v_e.club_id;
  if coalesce(v_e.fee, 0) > 0 and club_has(v_e.club_id, 'privates') then
    insert into invoices (club_id, profile_id, description, amount, due_date, source, meta, created_by)
    values (v_e.club_id, auth.uid(),
            v_e.name || ' — ' || (select name from athletes where id = p_athlete),
            v_e.fee, least(v_e.event_date, current_date + coalesce(v_due, 7)),
            'event', jsonb_build_object('event_signup_id', v_id), auth.uid())
    returning id into v_inv;
    update event_signups set invoice_id = v_inv where id = v_id;
  end if;

  perform notify(auth.uid(), v_e.club_id, 'event_signup', 'Signed up! 🎪',
    (select name from athletes where id = p_athlete) || ' is in for ' || v_e.name
    || ' (' || to_char(v_e.event_date, 'FMDay DD Mon') || ')'
    || case when v_inv is not null then ' — the fee is on your Money page.' else '.' end,
    jsonb_build_object('event_id', p_event));
  for r in select profile_id from club_members
           where club_id = v_e.club_id and role = 'admin' and status = 'active' and profile_id <> auth.uid() loop
    perform notify(r.profile_id, v_e.club_id, 'event_signup', 'Event sign-up',
      (select name from athletes where id = p_athlete) || ' signed up for ' || v_e.name || '.',
      jsonb_build_object('event_id', p_event));
  end loop;
  return jsonb_build_object('signup_id', v_id, 'invoiced', v_inv is not null);
exception when unique_violation then
  raise exception 'This athlete is already signed up.';
end;
$$;

create or replace function public.cancel_event_signup (p_signup uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_s event_signups%rowtype;
begin
  select * into v_s from event_signups where id = p_signup for update;
  if v_s.id is null then raise exception 'Sign-up not found.'; end if;
  if not (v_s.booked_by = auth.uid() or owns_athlete(v_s.athlete_id) or is_admin_of(v_s.club_id)) then
    raise exception 'Not your sign-up.';
  end if;
  if v_s.status <> 'booked' then raise exception 'Already cancelled.'; end if;
  update event_signups set status = 'cancelled' where id = p_signup;
  if v_s.invoice_id is not null then
    update invoices set status = 'void' where id = v_s.invoice_id and status in ('due', 'overdue');
  end if;
end;
$$;

-- The club website advertises upcoming events.
create or replace function public.get_club_public (p_slug text) returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(t) from (
    select c.name, c.slug, c.blurb, c.logo_path, c.accent_color, c.status,
      has_website(c.id) as website,
      (select coalesce(jsonb_agg(jsonb_build_object('slug', pg.slug, 'title', pg.title, 'body', pg.body) order by pg.sort, pg.title), '[]'::jsonb)
       from club_pages pg where pg.club_id = c.id and pg.published and has_website(c.id)) as pages,
      (select coalesce(jsonb_agg(jsonb_build_object('name', p.full_name, 'disciplines', cp.disciplines, 'levels', cp.levels) order by p.full_name), '[]'::jsonb)
       from club_members m join profiles p on p.id = m.profile_id
       left join coach_profiles cp on cp.club_id = c.id and cp.coach_id = p.id
       where m.club_id = c.id and m.role = 'coach' and m.status = 'active') as coaches,
      (select count(*) from slots s where s.club_id = c.id and s.slot_date >= current_date and s.slot_date < current_date + 14) as upcoming_slots,
      (select coalesce(jsonb_agg(l.name), '[]'::jsonb) from locations l where l.club_id = c.id and l.active) as locations,
      (select coalesce(jsonb_agg(jsonb_build_object(
          'name', g.name, 'discipline', g.discipline, 'day_of_week', g.day_of_week,
          'start_time', g.start_time, 'end_time', g.end_time,
          'age_min', g.age_min, 'age_max', g.age_max,
          'monthly_fee', g.monthly_fee, 'price_per_session', g.price_per_session,
          'trial_allowed', g.trial_allowed
        ) order by g.day_of_week, g.start_time), '[]'::jsonb)
       from class_groups g where g.club_id = c.id and g.active) as classes,
      (select coalesce(jsonb_agg(jsonb_build_object(
          'name', sp.name, 'description', sp.description, 'price', sp.price,
          'options', sp.options, 'image_url', sp.image_url,
          'in_stock', (sp.stock is null or sp.stock > 0)
        ) order by sp.sort, sp.name), '[]'::jsonb)
       from shop_products sp where sp.club_id = c.id and sp.active) as shop,
      (select coalesce(jsonb_agg(jsonb_build_object(
          'name', e.name, 'description', e.description, 'event_date', e.event_date,
          'start_time', e.start_time, 'fee', e.fee
        ) order by e.event_date), '[]'::jsonb)
       from events e where e.club_id = c.id and e.active and e.event_date >= current_date) as events
    from clubs c where c.slug = lower(p_slug) and c.status = 'active' and c.searchable
  ) t
$$;

-- ---------------------------------------------------------------------------
-- 4. Auto-pay: saved payment methods per payer per club (managed by the pay
--    edge function; keys never leave the service role)
-- ---------------------------------------------------------------------------
create table public.club_customers (
  club_id uuid not null references public.clubs (id) on delete cascade,
  profile_id uuid not null references public.profiles (id) on delete cascade,
  stripe_customer_id text not null,
  payment_method_id text,
  method_label text,
  auto_pay boolean not null default true,
  updated_at timestamptz not null default now(),
  primary key (club_id, profile_id)
);
alter table public.club_customers enable row level security;
create policy club_customers_select on public.club_customers for select to authenticated
  using (profile_id = auth.uid() or is_admin_of(club_id));

create or replace function public.set_auto_pay (p_club uuid, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  update club_customers set auto_pay = p_on, updated_at = now()
  where club_id = p_club and profile_id = auth.uid();
  if not found then raise exception 'Save a payment method first.'; end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Media bucket (guarded: storage schema exists on Supabase only)
-- ---------------------------------------------------------------------------
do $media$
begin
  insert into storage.buckets (id, name, public) values ('club-media', 'club-media', true)
  on conflict (id) do nothing;
  begin
    create policy club_media_admin_write on storage.objects for insert to authenticated
      with check (bucket_id = 'club-media' and is_admin_of(((storage.foldername(name))[1])::uuid));
    create policy club_media_admin_delete on storage.objects for delete to authenticated
      using (bucket_id = 'club-media' and is_admin_of(((storage.foldername(name))[1])::uuid));
  exception when duplicate_object then null;
  end;
exception when others then
  raise notice 'storage unavailable (%).', sqlerrm;
end;
$media$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function
  public.update_club_waiver (uuid, text),
  public.sign_waiver (uuid, text),
  public.waiver_status (uuid),
  public.admin_save_event (uuid, uuid, text, date, time, time, uuid, numeric, int, text, boolean),
  public.signup_event (uuid, uuid),
  public.cancel_event_signup (uuid),
  public.set_auto_pay (uuid, boolean)
from public, anon, authenticated;

grant execute on function
  public.update_club_waiver (uuid, text),
  public.sign_waiver (uuid, text),
  public.waiver_status (uuid),
  public.admin_save_event (uuid, uuid, text, date, time, time, uuid, numeric, int, text, boolean),
  public.signup_event (uuid, uuid),
  public.cancel_event_signup (uuid),
  public.set_auto_pay (uuid, boolean)
to authenticated, service_role;
