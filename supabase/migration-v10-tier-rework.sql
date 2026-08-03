-- ============================================================================
-- IGNYTE CLUB MANAGER — v10 "PACKAGES & MODULES" (ADDITIVE — run after v9)
-- ----------------------------------------------------------------------------
-- Final packaging. Everything is a module; plans are bundles of modules, and
-- any module can also be bought à la carte on top of Free:
--
--   FREE  £0   — website builder, group classes & booking, registers, waiting
--                lists, free trials, up to 30 athletes.
--   Add-on: PRIVATES £10/mo   — 1-2-1 lesson management: slots, weekly series,
--                credits & makeup, skill journeys & videos, invoicing & online
--                payments, broadcasts, exports, paid trials.
--   Add-on: WEBSITE PRO £10/mo — custom domain + club mailbox + your branding.
--   SMALL £15/mo — Free + Privates + up to 100 athletes.
--   CLUB  £35/mo — everything: unlimited athletes, memberships & auto-billing,
--                Website Pro, migration engine, priority support.
--
-- One resolver — club_has(club, feature) — answers "does this club hold this
-- module, via plan or purchase?", and every gate asks it.
-- ============================================================================

-- 'privates' plan value becomes 'small'
alter table public.clubs drop constraint clubs_plan_check;
update public.clubs set plan = 'small' where plan = 'privates';
alter table public.clubs add constraint clubs_plan_check
  check (plan in ('free', 'small', 'club', 'comped'));

-- The capability resolver: plan bundles OR à la carte addons.
create or replace function public.club_has (p_club uuid, p_feature text) returns boolean
language sql stable security definer set search_path = public as $$
  select case p_feature
    when 'privates' then plan in ('small', 'club', 'comped') or 'privates' = any (addons)
    when 'websitepro' then plan in ('club', 'comped') or 'websitepro' = any (addons)
    when 'memberships' then plan in ('club', 'comped') or 'memberships' = any (addons)
    else false
  end
  from clubs where id = p_club
$$;

-- Classes are free for everyone now.
drop trigger if exists plan_gate_class_groups on public.class_groups;
drop trigger if exists plan_gate_class_enrolments on public.class_enrolments;
drop trigger if exists plan_gate_class_trials on public.class_trials;

-- Money / journeys / broadcasts ride with the Privates module.
create or replace function public.gate_privates () returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.club_id is not null and not club_has(new.club_id, 'privates') then
    raise exception 'That''s part of the Privates add-on (£10/mo) or the Small plan (£15/mo) — upgrade to switch it on.';
  end if;
  return new;
end;
$$;
create or replace function public.gate_privates_skill () returns trigger
language plpgsql security definer set search_path = public as $$
declare v_club uuid := (select club_id from skills where id = new.skill_id);
begin
  if v_club is not null and not club_has(v_club, 'privates') then
    raise exception 'That''s part of the Privates add-on (£10/mo) or the Small plan (£15/mo) — upgrade to switch it on.';
  end if;
  return new;
end;
$$;

-- 1-2-1 slots need the Privates module.
create or replace function public.gate_small_slots () returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not club_has(new.club_id, 'privates') then
    raise exception '1-2-1 private lessons are the Privates add-on (£10/mo) or the Small plan (£15/mo) — group classes are free.';
  end if;
  return new;
end;
$$;
drop trigger if exists plan_gate_slots on public.slots;
create trigger plan_gate_slots before insert on public.slots
  for each row execute function public.gate_small_slots ();

-- Memberships stay with Club (or a granted module).
create or replace function public.gate_club_tier () returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not club_has(new.club_id, 'memberships') then
    raise exception 'Memberships are part of the Club plan (£35/mo) — upgrade to switch them on.';
  end if;
  return new;
end;
$$;

-- Tiered athlete caps: free 30, small 100, club/comped unlimited.
create or replace function public.gate_free_athlete_cap () returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_plan text := club_plan(new.club_id);
  v_cap int := case v_plan when 'free' then 30 when 'small' then 100 else null end;
begin
  if v_cap is not null
     and (select count(*) from athlete_enrolments where club_id = new.club_id) >= v_cap then
    raise exception 'The % plan covers up to % athletes — upgrade to keep growing.',
      case v_plan when 'free' then 'Free' else 'Small' end, v_cap;
  end if;
  return new;
end;
$$;

-- The website builder is included for every club.
create or replace function public.has_website (p_club uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from clubs where id = p_club)
$$;

-- Free clubs run free trials only — paid-trial invoicing needs Privates.
create or replace function public.book_class_trial (p_class uuid, p_athlete uuid, p_session uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_g class_groups%rowtype;
  v_s class_sessions%rowtype;
  v_taken int;
  v_id uuid;
  v_due_days int;
  v_athlete text := (select name from athletes where id = p_athlete);
begin
  select * into v_g from class_groups where id = p_class;
  if v_g.id is null or not v_g.active then raise exception 'Class not found.'; end if;
  if not v_g.trial_allowed then raise exception 'This class doesn''t take trials — enrol instead.'; end if;
  if not (owns_athlete(p_athlete) or is_admin_of(v_g.club_id)) then
    raise exception 'You can only book trials for your own athletes.';
  end if;
  perform assert_club_active(v_g.club_id);
  if not athlete_in_club(p_athlete, v_g.club_id) then
    raise exception 'This athlete isn''t enrolled at this club yet — add them under Athletes first.';
  end if;
  select * into v_s from class_sessions where id = p_session and class_id = p_class for update;
  if v_s.id is null or v_s.cancelled or v_s.session_date < current_date then
    raise exception 'Pick an upcoming session for the trial.';
  end if;
  if exists (select 1 from class_enrolments where class_id = p_class and athlete_id = p_athlete and status in ('enrolled', 'waiting')) then
    raise exception 'This athlete is already on this class''s list.';
  end if;
  select (select count(*) from class_enrolments where class_id = p_class and status = 'enrolled')
       + (select count(*) from class_trials where session_id = p_session and status = 'booked')
    into v_taken;
  if v_taken >= v_g.capacity then raise exception 'That session is full — try another week.'; end if;

  insert into class_trials (club_id, class_id, session_id, athlete_id, booked_by)
  values (v_g.club_id, p_class, p_session, p_athlete, auth.uid())
  returning id into v_id;

  if coalesce(v_g.trial_price, 0) > 0 and club_has(v_g.club_id, 'privates') then
    select invoice_due_days into v_due_days from club_settings where club_id = v_g.club_id;
    insert into invoices (club_id, profile_id, description, amount, due_date, source, meta, created_by)
    values (v_g.club_id, auth.uid(),
            'Trial — ' || v_g.name || ' (' || v_athlete || ', ' || to_char(v_s.session_date, 'DD Mon') || ')',
            v_g.trial_price, least(v_s.session_date, current_date + coalesce(v_due_days, 7)),
            'trial', jsonb_build_object('trial_id', v_id), auth.uid());
  end if;

  perform notify(auth.uid(), v_g.club_id, 'trial_booked', 'Trial booked! ⭐',
    v_athlete || ' is trying ' || v_g.name || ' on ' || to_char(v_s.session_date, 'FMDay DD Mon')
    || case when coalesce(v_g.trial_price, 0) > 0 and club_has(v_g.club_id, 'privates')
        then ' — the trial invoice is in your Money page.' else ' — first taste is free!' end,
    jsonb_build_object('trial_id', v_id));
  if v_g.lead_coach_id is not null and v_g.lead_coach_id <> auth.uid() then
    perform notify(v_g.lead_coach_id, v_g.club_id, 'trial_booked', 'Trial booked',
      v_athlete || ' is trialling ' || v_g.name || ' on ' || to_char(v_s.session_date, 'FMDay DD Mon') || '.',
      jsonb_build_object('trial_id', v_id));
  end if;
  return v_id;
end;
$$;

-- Branding: Website Pro module (or Club plan).
create or replace function public.update_club_branding (
  p_club uuid, p_name text default null, p_blurb text default null,
  p_accent text default null, p_logo_path text default null, p_searchable boolean default null
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin_of(p_club) then raise exception 'Admins only.'; end if;
  if (p_accent is not null or p_logo_path is not null)
     and not club_has(p_club, 'websitepro') then
    raise exception 'Custom colours and logos are part of Website Pro (£10/mo) or the Club plan (£35/mo).';
  end if;
  update clubs set
    name = coalesce(nullif(trim(p_name), ''), name),
    blurb = coalesce(p_blurb, blurb),
    accent_color = coalesce(p_accent, accent_color),
    logo_path = coalesce(p_logo_path, logo_path),
    searchable = coalesce(p_searchable, searchable)
  where id = p_club;
  perform owner_log(p_club, 'update_branding', null);
end;
$$;

create or replace function public.owner_set_plan (p_club uuid, p_plan text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_owner() then raise exception 'Owner only.'; end if;
  if p_plan not in ('free', 'small', 'club', 'comped') then raise exception 'Bad plan.'; end if;
  update clubs set plan = p_plan where id = p_club;
  insert into owner_audit (club_id, action, detail) values (p_club, 'set_plan', p_plan);
end;
$$;

-- ---------------------------------------------------------------------------
-- Custom domain & club mailbox (Website Pro / Club)
-- ---------------------------------------------------------------------------
alter table public.clubs
  add column if not exists custom_domain text unique,
  add column if not exists custom_domain_status text check (custom_domain_status in ('requested', 'live')),
  add column if not exists mailbox_alias text;

create or replace function public.admin_request_domain (p_club uuid, p_domain text, p_mailbox text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_domain text := lower(trim(p_domain));
  r record;
begin
  if not is_admin_of(p_club) then raise exception 'Admins only.'; end if;
  if not club_has(p_club, 'websitepro') then
    raise exception 'Custom domains & mailboxes are part of Website Pro (£10/mo) or the Club plan (£35/mo).';
  end if;
  if v_domain !~ '^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$' then
    raise exception 'Enter the bare domain, like stormallstars.co.uk';
  end if;
  update clubs set custom_domain = v_domain, custom_domain_status = 'requested',
    mailbox_alias = nullif(lower(trim(coalesce(p_mailbox, ''))), '')
  where id = p_club;
  for r in select id from profiles where role = 'owner' loop
    perform notify(r.id, null, 'domain_request', '🌐 Custom domain request',
      (select name from clubs where id = p_club) || ' asked for ' || v_domain
      || coalesce(' (mailbox: ' || nullif(lower(trim(coalesce(p_mailbox, ''))), '') || '@' || v_domain || ')', '')
      || ' — wire it up in Cloudflare, then mark it live from Owner HQ.', '{}'::jsonb);
  end loop;
  insert into owner_audit (club_id, action, detail) values (p_club, 'domain_requested', v_domain);
end;
$$;

create or replace function public.owner_set_domain_status (p_club uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_owner() then raise exception 'Owner only.'; end if;
  if p_status not in ('requested', 'live') then raise exception 'Bad status.'; end if;
  update clubs set custom_domain_status = p_status where id = p_club and custom_domain is not null;
  insert into owner_audit (club_id, action, detail) values (p_club, 'domain_status', p_status);
end;
$$;

-- The worker serves club sites on their own domains: hostname -> slug.
create or replace function public.resolve_club_domain (p_host text) returns text
language sql stable security definer set search_path = public as $$
  select slug from clubs
  where custom_domain = lower(trim(p_host)) and custom_domain_status = 'live' and status = 'active'
$$;

revoke execute on function
  public.club_has (uuid, text),
  public.admin_request_domain (uuid, text, text),
  public.owner_set_domain_status (uuid, text),
  public.resolve_club_domain (text)
from public, anon, authenticated;

grant execute on function
  public.club_has (uuid, text),
  public.admin_request_domain (uuid, text, text),
  public.owner_set_domain_status (uuid, text)
to authenticated, service_role;

grant execute on function
  public.resolve_club_domain (text)
to anon, authenticated, service_role;
