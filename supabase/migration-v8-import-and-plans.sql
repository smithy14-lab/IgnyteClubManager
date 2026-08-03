-- ============================================================================
-- IGNYTE CLUB MANAGER — v8 "SWITCHING ON" (ADDITIVE — run after v7)
-- ----------------------------------------------------------------------------
--   1. MODULAR PLANS — free (absolute basics) / privates (everything 1-2-1)
--      / club (the lot). Enforced in the database by insert gates, so no
--      code path can leak a paid feature to a free club.
--   2. MIGRATION ENGINE — clubs arriving from another system: SQL side of
--      coach + family import (invites & auth live in the admin-import edge
--      function; these RPCs are service-role only).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Plans: add 'privates' between free and club
-- ---------------------------------------------------------------------------
alter table public.clubs drop constraint clubs_plan_check;
alter table public.clubs add constraint clubs_plan_check
  check (plan in ('free', 'privates', 'club', 'comped'));

create or replace function public.club_plan (p_club uuid) returns text
language sql stable security definer set search_path = public as $$
  select plan from clubs where id = p_club
$$;

-- Feature gates as insert triggers: every write path is covered, forever.
create or replace function public.gate_privates () returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.club_id is not null and club_plan(new.club_id) = 'free' then
    raise exception 'That''s part of the Privates plan (from £15/mo) — upgrade to switch it on.';
  end if;
  return new;
end;
$$;

-- athlete_skills has no club_id — the skill row carries it.
create or replace function public.gate_privates_skill () returns trigger
language plpgsql security definer set search_path = public as $$
declare v_club uuid := (select club_id from skills where id = new.skill_id);
begin
  if v_club is not null and club_plan(v_club) = 'free' then
    raise exception 'That''s part of the Privates plan (from £15/mo) — upgrade to switch it on.';
  end if;
  return new;
end;
$$;

create or replace function public.gate_club_tier () returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if club_plan(new.club_id) not in ('club', 'comped') then
    raise exception 'Group classes & memberships are part of the Club plan (£29/mo) — upgrade to switch them on.';
  end if;
  return new;
end;
$$;

-- Free tier: the basics stop at 40 athletes per club.
create or replace function public.gate_free_athlete_cap () returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if club_plan(new.club_id) = 'free'
     and (select count(*) from athlete_enrolments where club_id = new.club_id) >= 40 then
    raise exception 'The free plan covers up to 40 athletes — upgrade to keep growing.';
  end if;
  return new;
end;
$$;

-- Privates-tier features: invoicing/payments, skill journeys & media.
create trigger plan_gate_invoices before insert on public.invoices
  for each row execute function public.gate_privates ();
create trigger plan_gate_payment_keys before insert on public.club_payment_keys
  for each row execute function public.gate_privates ();
create trigger plan_gate_athlete_skills before insert on public.athlete_skills
  for each row execute function public.gate_privates_skill ();
create trigger plan_gate_progress_notes before insert on public.progress_notes
  for each row execute function public.gate_privates ();
create trigger plan_gate_skill_media before insert on public.skill_media
  for each row execute function public.gate_privates ();
create trigger plan_gate_broadcasts before insert on public.broadcasts
  for each row execute function public.gate_privates ();

-- Club-tier features: classes, trials, membership plans & memberships.
create trigger plan_gate_class_groups before insert on public.class_groups
  for each row execute function public.gate_club_tier ();
create trigger plan_gate_class_enrolments before insert on public.class_enrolments
  for each row execute function public.gate_club_tier ();
create trigger plan_gate_class_trials before insert on public.class_trials
  for each row execute function public.gate_club_tier ();
create trigger plan_gate_membership_plans before insert on public.membership_plans
  for each row execute function public.gate_club_tier ();
create trigger plan_gate_memberships before insert on public.memberships
  for each row execute function public.gate_club_tier ();

create trigger plan_gate_athlete_cap before insert on public.athlete_enrolments
  for each row execute function public.gate_free_athlete_cap ();

-- Branding (accent/logo) moves to the Club tier.
create or replace function public.update_club_branding (
  p_club uuid, p_name text default null, p_blurb text default null,
  p_accent text default null, p_logo_path text default null, p_searchable boolean default null
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin_of(p_club) then raise exception 'Admins only.'; end if;
  if (p_accent is not null or p_logo_path is not null)
     and (select plan from clubs where id = p_club) not in ('club', 'comped') then
    raise exception 'Custom colours and logos are part of the Club plan (£29/mo).';
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

-- Owner can set the new plan value.
create or replace function public.owner_set_plan (p_club uuid, p_plan text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_owner() then raise exception 'Owner only.'; end if;
  if p_plan not in ('free', 'privates', 'club', 'comped') then raise exception 'Bad plan.'; end if;
  update clubs set plan = p_plan where id = p_club;
  insert into owner_audit (club_id, action, detail) values (p_club, 'set_plan', p_plan);
end;
$$;

-- ---------------------------------------------------------------------------
-- Migration engine (service-role only; the admin-import edge function has
-- already verified the caller is one of the club's admins and has created /
-- looked up the auth user, sending Supabase's set-your-password invite email)
-- ---------------------------------------------------------------------------
create or replace function public.admin_import_coach (
  p_club uuid, p_profile uuid, p_disciplines text[] default null,
  p_levels text default null, p_rate numeric default null
) returns void language plpgsql security definer set search_path = public as $$
begin
  insert into club_members (club_id, profile_id, role, status)
  values (p_club, p_profile, 'coach', 'active')
  on conflict (club_id, profile_id) do update set role = 'coach', status = 'active';
  update coach_profiles set
    disciplines = coalesce(p_disciplines, disciplines),
    levels = coalesce(p_levels, levels),
    rate_per_lesson = coalesce(p_rate, rate_per_lesson)
  where club_id = p_club and coach_id = p_profile;
  perform notify(p_profile, p_club, 'imported', 'Welcome to the team! 🔥',
    'You''ve been added as a coach at ' || (select name from clubs where id = p_club)
    || '. Add yourself to the slots you can work from the Coaching hub.', '{}'::jsonb);
  insert into owner_audit (club_id, action, detail) values (p_club, 'import_coach', p_profile::text);
end;
$$;

-- Athletes arrive as [{"name": "...", "dob": "YYYY-MM-DD", "notes": "..."}].
-- If a coach + slot are given, each athlete gets their existing weekly session
-- re-created (whole series when p_weekly) — booked as the parent, no cut-offs.
create or replace function public.admin_import_family (
  p_club uuid, p_profile uuid, p_athletes jsonb,
  p_coach uuid default null, p_slot uuid default null, p_weekly boolean default true
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  a jsonb;
  v_aid uuid;
  v_slot slots%rowtype;
  v_series_booking uuid;
  v_booked int := 0;
  v_athletes int := 0;
  r record;
begin
  insert into club_members (club_id, profile_id, role, status)
  values (p_club, p_profile, 'parent', 'active')
  on conflict (club_id, profile_id) do update set status = 'active';
  update profiles set last_club_id = p_club where id = p_profile and last_club_id is null;

  for a in select * from jsonb_array_elements(coalesce(p_athletes, '[]'::jsonb)) loop
    select id into v_aid from athletes
      where parent_id = p_profile and lower(name) = lower(a ->> 'name');
    if v_aid is null then
      insert into athletes (parent_id, name, dob, notes)
      values (p_profile, a ->> 'name', (a ->> 'dob')::date, nullif(a ->> 'notes', ''))
      returning id into v_aid;
    end if;
    insert into athlete_enrolments (athlete_id, club_id) values (v_aid, p_club)
    on conflict do nothing;
    v_athletes := v_athletes + 1;

    if p_coach is not null and p_slot is not null then
      select * into v_slot from slots where id = p_slot and club_id = p_club;
      if v_slot.id is null then raise exception 'Pick one of this club''s slots.'; end if;
      if p_weekly and v_slot.series_id is not null then
        insert into booking_series (club_id, series_id, athlete_id, coach_id, booked_by)
        values (p_club, v_slot.series_id, v_aid, p_coach, p_profile)
        returning id into v_series_booking;
        for r in select s.id from slots s where s.series_id = v_slot.series_id
                 and s.slot_date >= greatest(v_slot.slot_date, current_date) order by s.slot_date loop
          begin
            perform _create_booking(r.id, v_aid, p_coach, p_profile, v_series_booking, true);
            v_booked := v_booked + 1;
          exception when others then null;
          end;
        end loop;
      else
        begin
          perform _create_booking(p_slot, v_aid, p_coach, p_profile, null, true);
          v_booked := v_booked + 1;
        exception when others then null;
        end;
      end if;
    end if;
  end loop;

  perform notify(p_profile, p_club, 'imported', 'Your lessons came with you 🎉',
    (select name from clubs where id = p_club) || ' has set up your family'
    || case when v_booked > 0 then ' and ' || v_booked || ' upcoming lesson(s)' else '' end
    || '. Everything is ready in the app.', '{}'::jsonb);
  insert into owner_audit (club_id, action, detail)
  values (p_club, 'import_family', v_athletes || ' athletes, ' || v_booked || ' bookings');
  return jsonb_build_object('athletes', v_athletes, 'booked', v_booked);
end;
$$;

revoke execute on function
  public.club_plan (uuid),
  public.admin_import_coach (uuid, uuid, text[], text, numeric),
  public.admin_import_family (uuid, uuid, jsonb, uuid, uuid, boolean)
from public, anon, authenticated;

grant execute on function public.club_plan (uuid) to authenticated, service_role;
grant execute on function
  public.admin_import_coach (uuid, uuid, text[], text, numeric),
  public.admin_import_family (uuid, uuid, jsonb, uuid, uuid, boolean),
  public._create_booking (uuid, uuid, uuid, uuid, uuid, boolean)
to service_role;
