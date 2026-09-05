-- ============================================================================
-- IGNYTE 1-2-1 — Supabase schema (fresh start)
-- ----------------------------------------------------------------------------
-- A focused private-lesson system for cheer & dance clubs. One shared
-- platform, many walled clubs. Six portals over one login:
--   Ignyte owner (platform) · club owner · club admin · coach · parent · athlete
-- A person can hold several roles in a club (roles[] on the membership row).
-- Row-level security isolates clubs; every write goes through a SECURITY
-- DEFINER function that checks the caller's role.
--
-- Running this file WIPES the public schema (auth logins survive) and installs
-- the new one. It is idempotent: safe to run again.
-- ============================================================================

drop schema if exists public cascade;
create schema public;
grant usage on schema public to postgres, anon, authenticated, service_role;
grant all on schema public to postgres, service_role;
alter default privileges in schema public grant all on tables to postgres, anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to postgres, anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to postgres, anon, authenticated, service_role;
drop trigger if exists on_auth_user_created on auth.users;

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null,
  email text not null,
  phone text,
  is_platform_owner boolean not null default false,
  created_at timestamptz not null default now()
);
create index profiles_email_idx on public.profiles (lower(email));

create table public.clubs (
  id uuid primary key default gen_random_uuid (),
  name text not null check (char_length(name) between 2 and 60),
  slug text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,28}[a-z0-9]$'),
  join_code text not null unique default upper(substr(md5(gen_random_uuid()::text), 1, 6)),
  venue text,
  timezone text not null default 'Europe/London',
  lesson_minutes int not null default 30 check (lesson_minutes between 15 and 180),
  lesson_price_pence int not null default 2500 check (lesson_price_pence >= 0),
  currency text not null default 'GBP',
  cancel_hours int not null default 24 check (cancel_hours between 0 and 168),
  status text not null default 'active' check (status in ('active', 'suspended')),
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now()
);

create table public.club_members (
  club_id uuid not null references public.clubs (id) on delete cascade,
  profile_id uuid not null references public.profiles (id) on delete cascade,
  roles text[] not null default '{}' check (roles <@ array['owner', 'admin', 'coach', 'parent', 'athlete']),
  status text not null default 'active' check (status in ('active', 'removed')),
  created_at timestamptz not null default now(),
  primary key (club_id, profile_id)
);
create index club_members_profile_idx on public.club_members (profile_id);

-- Staff invited by email before they have a login. Merged on first sign-in.
create table public.invites (
  id uuid primary key default gen_random_uuid (),
  club_id uuid not null references public.clubs (id) on delete cascade,
  email text not null,
  roles text[] not null check (roles <@ array['owner', 'admin', 'coach', 'parent']),
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  accepted_at timestamptz
);
create index invites_email_idx on public.invites (lower(email)) where accepted_at is null;

-- One athlete record per club. Owned by a parent login, the athlete's own
-- login, or both (a parent who also trains has parent_id = profile_id).
create table public.athletes (
  id uuid primary key default gen_random_uuid (),
  club_id uuid not null references public.clubs (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 60),
  dob date,
  parent_id uuid references public.profiles (id) on delete set null,
  profile_id uuid references public.profiles (id) on delete set null,
  medical_notes text,
  notes text,
  goals text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  check (parent_id is not null or profile_id is not null)
);
create index athletes_club_idx on public.athletes (club_id);
create index athletes_parent_idx on public.athletes (parent_id);
create index athletes_profile_idx on public.athletes (profile_id);

-- A slot is one bookable 1-2-1 lesson time with a coach.
create table public.slots (
  id uuid primary key default gen_random_uuid (),
  club_id uuid not null references public.clubs (id) on delete cascade,
  coach_id uuid not null references public.profiles (id) on delete cascade,
  starts_at timestamptz not null,
  minutes int not null check (minutes between 15 and 180),
  price_pence int not null default 0 check (price_pence >= 0),
  status text not null default 'open' check (status in ('open', 'booked', 'cancelled')),
  series_id uuid,
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  unique (coach_id, starts_at)
);
create index slots_club_time_idx on public.slots (club_id, starts_at);

create table public.lessons (
  id uuid primary key default gen_random_uuid (),
  slot_id uuid not null references public.slots (id) on delete cascade,
  club_id uuid not null references public.clubs (id) on delete cascade,
  coach_id uuid not null references public.profiles (id) on delete cascade,
  athlete_id uuid not null references public.athletes (id) on delete cascade,
  booked_by uuid references public.profiles (id),
  status text not null default 'booked' check (status in ('booked', 'completed', 'no_show', 'cancelled')),
  coach_notes text,
  homework text,
  worked_on text[] not null default '{}',
  paid boolean not null default false,
  paid_at timestamptz,
  late_cancel boolean not null default false,
  cancelled_at timestamptz,
  cancelled_by uuid references public.profiles (id),
  created_at timestamptz not null default now()
);
create unique index lessons_active_slot_idx on public.lessons (slot_id) where status <> 'cancelled';
create index lessons_athlete_idx on public.lessons (athlete_id);
create index lessons_coach_idx on public.lessons (coach_id);
create index lessons_club_idx on public.lessons (club_id);

-- Skill journey per athlete: what they're working on, achieved, mastered.
create table public.progress (
  id uuid primary key default gen_random_uuid (),
  club_id uuid not null references public.clubs (id) on delete cascade,
  athlete_id uuid not null references public.athletes (id) on delete cascade,
  skill text not null check (char_length(skill) between 1 and 60),
  status text not null check (status in ('working_on', 'achieved', 'mastered')),
  note text,
  updated_by uuid references public.profiles (id),
  updated_at timestamptz not null default now(),
  unique (athlete_id, skill)
);

-- ---------------------------------------------------------------------------
-- Helpers (SECURITY DEFINER so policies never recurse into RLS)
-- ---------------------------------------------------------------------------
create or replace function public.is_platform_owner () returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_platform_owner from profiles where id = auth.uid()), false)
$$;

create or replace function public.my_roles (p_club uuid) returns text[]
language sql stable security definer set search_path = public as $$
  select case when is_platform_owner() then array['owner', 'admin', 'coach', 'parent', 'athlete']
    else coalesce((select roles from club_members where club_id = p_club and profile_id = auth.uid() and status = 'active'), '{}') end
$$;

create or replace function public.has_role (p_club uuid, variadic p_roles text[]) returns boolean
language sql stable security definer set search_path = public as $$
  select my_roles(p_club) && p_roles
$$;

create or replace function public.is_member (p_club uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select is_platform_owner() or exists (
    select 1 from club_members where club_id = p_club and profile_id = auth.uid() and status = 'active')
$$;

create or replace function public.athlete_is_mine (p_athlete uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from athletes where id = p_athlete and (parent_id = auth.uid() or profile_id = auth.uid()))
$$;

create or replace function public.shares_club (p_profile uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from club_members a join club_members b on a.club_id = b.club_id
    where a.profile_id = auth.uid() and b.profile_id = p_profile and a.status = 'active' and b.status = 'active')
$$;

create or replace function public.my_email () returns text
language sql stable security definer set search_path = public as $$
  select lower(email) from profiles where id = auth.uid()
$$;

-- ---------------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.clubs enable row level security;
alter table public.club_members enable row level security;
alter table public.invites enable row level security;
alter table public.athletes enable row level security;
alter table public.slots enable row level security;
alter table public.lessons enable row level security;
alter table public.progress enable row level security;

create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or is_platform_owner() or shares_club(id));
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- Nobody promotes themselves: the platform-owner flag only changes via SQL.
create or replace function public.guard_platform_owner () returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null then new.is_platform_owner := old.is_platform_owner; new.email := old.email; end if;
  return new;
end;
$$;
create trigger profiles_guard before update on public.profiles
for each row execute function public.guard_platform_owner ();

create policy clubs_select on public.clubs for select to authenticated using (is_member(id));

create policy members_select on public.club_members for select to authenticated
  using (profile_id = auth.uid() or has_role(club_id, 'owner', 'admin', 'coach'));

create policy invites_select on public.invites for select to authenticated
  using (has_role(club_id, 'owner', 'admin') or lower(email) = my_email());
create policy invites_delete on public.invites for delete to authenticated
  using (has_role(club_id, 'owner', 'admin'));

create policy athletes_select on public.athletes for select to authenticated
  using (parent_id = auth.uid() or profile_id = auth.uid() or has_role(club_id, 'owner', 'admin', 'coach'));

create policy slots_select on public.slots for select to authenticated using (is_member(club_id));

create policy lessons_select on public.lessons for select to authenticated
  using (booked_by = auth.uid() or coach_id = auth.uid() or athlete_is_mine(athlete_id) or has_role(club_id, 'owner', 'admin'));

create policy progress_select on public.progress for select to authenticated
  using (athlete_is_mine(athlete_id) or has_role(club_id, 'owner', 'admin', 'coach'));

-- ---------------------------------------------------------------------------
-- Sign-up: profile row + merge any staff invites for that email
-- ---------------------------------------------------------------------------
create or replace function public._merge_roles (p_club uuid, p_profile uuid, p_roles text[]) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into club_members (club_id, profile_id, roles, status)
  values (p_club, p_profile, p_roles, 'active')
  on conflict (club_id, profile_id) do update
    set roles = (select array_agg(distinct r) from unnest(club_members.roles || excluded.roles) r),
        status = 'active';
end;
$$;

create or replace function public._accept_invites_for (p_profile uuid, p_email text) returns int
language plpgsql security definer set search_path = public as $$
declare
  r record;
  n int := 0;
begin
  for r in select * from invites where lower(email) = lower(p_email) and accepted_at is null loop
    perform _merge_roles(r.club_id, p_profile, r.roles);
    update invites set accepted_at = now() where id = r.id;
    n := n + 1;
  end loop;
  return n;
end;
$$;

create or replace function public.handle_new_user () returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, full_name, email, phone)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data ->> 'full_name', ''), split_part(coalesce(new.email, 'member'), '@', 1)),
    coalesce(new.email, ''),
    nullif(new.raw_user_meta_data ->> 'phone', '')
  )
  on conflict (id) do nothing;
  perform _accept_invites_for(new.id, coalesce(new.email, ''));
  return new;
end;
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user ();

-- Existing logins get a profile straight away (this file runs on a reset).
insert into public.profiles (id, full_name, email, phone)
select u.id,
  coalesce(nullif(u.raw_user_meta_data ->> 'full_name', ''), split_part(coalesce(u.email, 'member'), '@', 1)),
  coalesce(u.email, ''),
  nullif(u.raw_user_meta_data ->> 'phone', '')
from auth.users u
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- RPC: app context in one round-trip
-- ---------------------------------------------------------------------------
create or replace function public.accept_invites () returns int
language plpgsql security definer set search_path = public as $$
begin
  return _accept_invites_for(auth.uid(), my_email());
end;
$$;

create or replace function public.my_context () returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_profile jsonb;
  v_clubs jsonb;
begin
  perform _accept_invites_for(v_uid, my_email());
  select to_jsonb(p) into v_profile from profiles p where p.id = v_uid;
  if v_profile is null then return null; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', c.id, 'name', c.name, 'slug', c.slug, 'join_code', case when m.roles && array['owner','admin','coach'] then c.join_code end,
      'venue', c.venue, 'timezone', c.timezone, 'lesson_minutes', c.lesson_minutes,
      'lesson_price_pence', c.lesson_price_pence, 'currency', c.currency, 'cancel_hours', c.cancel_hours,
      'status', c.status, 'roles', m.roles) order by c.name), '[]'::jsonb)
  into v_clubs
  from club_members m join clubs c on c.id = m.club_id
  where m.profile_id = v_uid and m.status = 'active';
  return jsonb_build_object('profile', v_profile, 'clubs', v_clubs);
end;
$$;

-- ---------------------------------------------------------------------------
-- RPC: platform owner (Ignyte HQ)
-- ---------------------------------------------------------------------------
create or replace function public.hq_create_club (p_name text, p_slug text, p_owner_email text, p_venue text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_club uuid;
  v_owner uuid;
begin
  if not is_platform_owner() then raise exception 'Ignyte owner only.'; end if;
  insert into clubs (name, slug, venue, created_by) values (p_name, lower(p_slug), nullif(p_venue, ''), auth.uid()) returning id into v_club;
  select id into v_owner from profiles where lower(email) = lower(p_owner_email);
  if v_owner is not null then
    perform _merge_roles(v_club, v_owner, array['owner']);
  else
    insert into invites (club_id, email, roles, created_by) values (v_club, lower(p_owner_email), array['owner'], auth.uid());
  end if;
  return jsonb_build_object('club_id', v_club, 'owner_status', case when v_owner is null then 'invited' else 'added' end,
    'join_code', (select join_code from clubs where id = v_club));
end;
$$;

create or replace function public.hq_set_club_status (p_club uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_platform_owner() then raise exception 'Ignyte owner only.'; end if;
  update clubs set status = p_status where id = p_club;
end;
$$;

create or replace function public.hq_overview () returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_platform_owner() then raise exception 'Ignyte owner only.'; end if;
  return jsonb_build_object(
    'clubs', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', c.id, 'name', c.name, 'slug', c.slug, 'status', c.status, 'venue', c.venue, 'join_code', c.join_code,
        'created_at', c.created_at,
        'owners', (select coalesce(string_agg(p.full_name || ' <' || p.email || '>', ', '), '')
                   from club_members m join profiles p on p.id = m.profile_id
                   where m.club_id = c.id and 'owner' = any (m.roles) and m.status = 'active'),
        'pending_owner', (select string_agg(email, ', ') from invites i where i.club_id = c.id and 'owner' = any (i.roles) and accepted_at is null),
        'members', (select count(*) from club_members m where m.club_id = c.id and m.status = 'active'),
        'coaches', (select count(*) from club_members m where m.club_id = c.id and m.status = 'active' and 'coach' = any (m.roles)),
        'athletes', (select count(*) from athletes a where a.club_id = c.id and a.active),
        'lessons_30d', (select count(*) from lessons l join slots s on s.id = l.slot_id where l.club_id = c.id and l.status <> 'cancelled' and s.starts_at > now() - interval '30 days' and s.starts_at <= now()),
        'upcoming', (select count(*) from lessons l join slots s on s.id = l.slot_id where l.club_id = c.id and l.status = 'booked' and s.starts_at > now()),
        'open_slots', (select count(*) from slots s where s.club_id = c.id and s.status = 'open' and s.starts_at > now())
      ) order by c.created_at desc), '[]'::jsonb) from clubs c),
    'totals', jsonb_build_object(
      'clubs', (select count(*) from clubs where status = 'active'),
      'people', (select count(*) from profiles),
      'lessons_30d', (select count(*) from lessons l join slots s on s.id = l.slot_id where l.status <> 'cancelled' and s.starts_at > now() - interval '30 days' and s.starts_at <= now()))
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- RPC: club settings & people (owner / admin)
-- ---------------------------------------------------------------------------
create or replace function public.update_club (p_club uuid, p_name text, p_venue text, p_lesson_minutes int, p_price_pence int, p_cancel_hours int, p_timezone text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not has_role(p_club, 'owner', 'admin') then raise exception 'Club owner or admin only.'; end if;
  update clubs set name = p_name, venue = nullif(p_venue, ''), lesson_minutes = p_lesson_minutes,
    lesson_price_pence = p_price_pence, cancel_hours = p_cancel_hours, timezone = coalesce(p_timezone, timezone)
  where id = p_club;
end;
$$;

create or replace function public.regenerate_join_code (p_club uuid) returns text
language plpgsql security definer set search_path = public as $$
declare v text;
begin
  if not has_role(p_club, 'owner', 'admin') then raise exception 'Club owner or admin only.'; end if;
  update clubs set join_code = upper(substr(md5(gen_random_uuid()::text), 1, 6)) where id = p_club returning join_code into v;
  return v;
end;
$$;

-- Add someone to the club by email. If they already have a login they're in
-- straight away; otherwise they get the roles the moment they sign up.
create or replace function public.invite_person (p_club uuid, p_email text, p_roles text[]) returns text
language plpgsql security definer set search_path = public as $$
declare v_profile uuid;
begin
  if not has_role(p_club, 'owner', 'admin') then raise exception 'Club owner or admin only.'; end if;
  if 'owner' = any (p_roles) and not has_role(p_club, 'owner') then raise exception 'Only the club owner can add another owner.'; end if;
  if coalesce(array_length(p_roles, 1), 0) = 0 then raise exception 'Pick at least one role.'; end if;
  select id into v_profile from profiles where lower(email) = lower(trim(p_email));
  if v_profile is not null then
    perform _merge_roles(p_club, v_profile, p_roles);
    return 'added';
  end if;
  insert into invites (club_id, email, roles, created_by) values (p_club, lower(trim(p_email)), p_roles, auth.uid());
  return 'invited';
end;
$$;

create or replace function public.set_member_roles (p_club uuid, p_profile uuid, p_roles text[]) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not has_role(p_club, 'owner', 'admin') then raise exception 'Club owner or admin only.'; end if;
  if not has_role(p_club, 'owner') and ('owner' = any (p_roles) or exists (
        select 1 from club_members where club_id = p_club and profile_id = p_profile and 'owner' = any (roles))) then
    raise exception 'Only the club owner can change owner roles.';
  end if;
  if p_profile = auth.uid() and not ('owner' = any (p_roles)) and has_role(p_club, 'owner') and not is_platform_owner() then
    raise exception 'You cannot remove your own owner role.';
  end if;
  if coalesce(array_length(p_roles, 1), 0) = 0 then
    update club_members set status = 'removed', roles = '{}' where club_id = p_club and profile_id = p_profile;
  else
    update club_members set roles = p_roles, status = 'active' where club_id = p_club and profile_id = p_profile;
  end if;
end;
$$;

create or replace function public.update_person (p_club uuid, p_profile uuid, p_name text, p_phone text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (p_profile = auth.uid() or has_role(p_club, 'owner', 'admin')) then raise exception 'Club owner or admin only.'; end if;
  if not exists (select 1 from club_members where club_id = p_club and profile_id = p_profile) and p_profile <> auth.uid() then
    raise exception 'That person is not in this club.';
  end if;
  update profiles set full_name = p_name, phone = nullif(p_phone, '') where id = p_profile;
end;
$$;

-- Everyone in the club with their athletes — for the People tab.
create or replace function public.club_people (p_club uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not has_role(p_club, 'owner', 'admin', 'coach') then raise exception 'Staff only.'; end if;
  return jsonb_build_object(
    'members', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id, 'name', p.full_name, 'email', p.email, 'phone', p.phone, 'roles', m.roles, 'joined', m.created_at
      ) order by p.full_name), '[]'::jsonb)
      from club_members m join profiles p on p.id = m.profile_id where m.club_id = p_club and m.status = 'active'),
    'invites', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'email', i.email, 'roles', i.roles) order by i.created_at), '[]'::jsonb)
      from invites i where i.club_id = p_club and i.accepted_at is null),
    'athletes', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', a.id, 'name', a.name, 'dob', a.dob, 'active', a.active, 'medical', a.medical_notes, 'notes', a.notes, 'goals', a.goals,
        'parent_id', a.parent_id, 'profile_id', a.profile_id,
        'parent_name', pp.full_name, 'parent_phone', pp.phone, 'parent_email', pp.email,
        'own_name', ap.full_name, 'own_phone', ap.phone, 'own_email', ap.email,
        'lessons', (select count(*) from lessons l where l.athlete_id = a.id and l.status = 'completed'),
        'next', (select min(s.starts_at) from lessons l join slots s on s.id = l.slot_id where l.athlete_id = a.id and l.status = 'booked' and s.starts_at > now())
      ) order by a.name), '[]'::jsonb)
      from athletes a left join profiles pp on pp.id = a.parent_id left join profiles ap on ap.id = a.profile_id
      where a.club_id = p_club)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- RPC: families & athletes
-- ---------------------------------------------------------------------------
create or replace function public.join_club (p_code text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_club uuid;
begin
  select id into v_club from clubs where join_code = upper(trim(p_code)) and status = 'active';
  if v_club is null then raise exception 'That club code isn''t right — check it with your club.'; end if;
  perform _merge_roles(v_club, auth.uid(), array['parent']);
  return v_club;
end;
$$;

-- Create or update an athlete. Parents manage their own children (and
-- themselves with p_self); staff can manage any athlete in the club and
-- create one for a parent (p_parent).
create or replace function public.save_athlete (
  p_club uuid, p_id uuid, p_name text, p_dob date, p_medical text default null, p_notes text default null,
  p_goals text default null, p_self boolean default false, p_parent uuid default null, p_active boolean default true
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_staff boolean := has_role(p_club, 'owner', 'admin', 'coach');
  v_id uuid := p_id;
  v_parent uuid;
  v_profile uuid;
begin
  if not is_member(p_club) then raise exception 'Join the club first.'; end if;
  if v_id is null then
    if p_self then
      v_parent := null; v_profile := v_uid;
      if exists (select 1 from athletes where club_id = p_club and profile_id = v_uid) then
        raise exception 'You are already set up as an athlete here.';
      end if;
    else
      v_parent := coalesce(case when v_staff then p_parent end, v_uid); v_profile := null;
    end if;
    insert into athletes (club_id, name, dob, parent_id, profile_id, medical_notes, notes, goals)
    values (p_club, trim(p_name), p_dob, v_parent, v_profile, nullif(p_medical, ''), nullif(p_notes, ''), nullif(p_goals, ''))
    returning id into v_id;
    if v_profile = v_uid then perform _merge_roles(p_club, v_uid, array['athlete']); end if;
    if v_parent is not null then perform _merge_roles(p_club, v_parent, array['parent']); end if;
  else
    if not (athlete_is_mine(v_id) or v_staff) then raise exception 'Not your athlete.'; end if;
    update athletes set name = trim(p_name), dob = p_dob, medical_notes = nullif(p_medical, ''),
      notes = nullif(p_notes, ''), goals = coalesce(nullif(p_goals, ''), goals), active = p_active
    where id = v_id and club_id = p_club;
  end if;
  return v_id;
end;
$$;

-- Link an athlete record to a login (e.g. a 16-year-old gets their own
-- account). Staff or the parent may do this by email.
create or replace function public.link_athlete_login (p_athlete uuid, p_email text) returns text
language plpgsql security definer set search_path = public as $$
declare a athletes; v_profile uuid;
begin
  select * into a from athletes where id = p_athlete;
  if a.id is null then raise exception 'Athlete not found.'; end if;
  if not (a.parent_id = auth.uid() or has_role(a.club_id, 'owner', 'admin', 'coach')) then raise exception 'Not allowed.'; end if;
  select id into v_profile from profiles where lower(email) = lower(trim(p_email));
  if v_profile is null then raise exception 'No Ignyte login with that email yet — ask them to create an account first.'; end if;
  update athletes set profile_id = v_profile where id = p_athlete;
  perform _merge_roles(a.club_id, v_profile, array['athlete']);
  return 'linked';
end;
$$;

-- ---------------------------------------------------------------------------
-- RPC: slots (coach availability)
-- ---------------------------------------------------------------------------
-- Creates p_count back-to-back slots starting at p_start, repeated weekly for
-- p_weeks weeks. DST-safe via the club's timezone. Existing times are skipped.
create or replace function public.add_slots (
  p_club uuid, p_coach uuid, p_start timestamptz, p_minutes int default null, p_count int default 1,
  p_weeks int default 1, p_price_pence int default null
) returns int
language plpgsql security definer set search_path = public as $$
declare
  c clubs;
  v_local timestamp;
  v_mins int;
  v_price int;
  v_series uuid := gen_random_uuid();
  n int := 0;
  w int; i int;
begin
  select * into c from clubs where id = p_club;
  if c.id is null then raise exception 'Club not found.'; end if;
  if not (has_role(p_club, 'owner', 'admin') or (p_coach = auth.uid() and has_role(p_club, 'coach'))) then
    raise exception 'Coaches can add their own slots; owners and admins can add anyone''s.';
  end if;
  if not exists (select 1 from club_members where club_id = p_club and profile_id = p_coach and 'coach' = any (roles) and status = 'active') then
    raise exception 'That person is not a coach in this club.';
  end if;
  v_mins := coalesce(p_minutes, c.lesson_minutes);
  v_price := coalesce(p_price_pence, c.lesson_price_pence);
  if p_count < 1 or p_count > 24 or p_weeks < 1 or p_weeks > 26 then raise exception 'Up to 24 slots a day, up to 26 weeks.'; end if;
  v_local := p_start at time zone c.timezone;
  for w in 0 .. p_weeks - 1 loop
    for i in 0 .. p_count - 1 loop
      insert into slots (club_id, coach_id, starts_at, minutes, price_pence, series_id, created_by)
      values (p_club, p_coach, (v_local + make_interval(days => 7 * w, mins => v_mins * i)) at time zone c.timezone, v_mins, v_price, v_series, auth.uid())
      on conflict (coach_id, starts_at) do nothing;
      if found then n := n + 1; end if;
    end loop;
  end loop;
  return n;
end;
$$;

-- Remove a slot (open → deleted; booked → lesson cancelled, slot cancelled).
create or replace function public.remove_slot (p_slot uuid) returns text
language plpgsql security definer set search_path = public as $$
declare s slots;
begin
  select * into s from slots where id = p_slot;
  if s.id is null then raise exception 'Slot not found.'; end if;
  if not (s.coach_id = auth.uid() or has_role(s.club_id, 'owner', 'admin')) then raise exception 'Not your slot.'; end if;
  if s.status = 'booked' then
    update lessons set status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid() where slot_id = s.id and status = 'booked';
    update slots set status = 'cancelled' where id = s.id;
    return 'cancelled';
  end if;
  delete from slots where id = s.id;
  return 'deleted';
end;
$$;

-- ---------------------------------------------------------------------------
-- RPC: lessons
-- ---------------------------------------------------------------------------
create or replace function public.book_slot (p_slot uuid, p_athlete uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  s slots; a athletes; v_id uuid;
begin
  select * into s from slots where id = p_slot for update;
  if s.id is null then raise exception 'That slot no longer exists.'; end if;
  select * into a from athletes where id = p_athlete;
  if a.id is null or a.club_id <> s.club_id then raise exception 'That athlete is not in this club.'; end if;
  if not (athlete_is_mine(a.id) or s.coach_id = auth.uid() or has_role(s.club_id, 'owner', 'admin')) then
    raise exception 'You can only book for your own athletes.';
  end if;
  if s.status <> 'open' then raise exception 'Sorry, that time has just been taken.'; end if;
  if s.starts_at < now() then raise exception 'That time has already passed.'; end if;
  if exists (select 1 from lessons l join slots x on x.id = l.slot_id
             where l.athlete_id = a.id and l.status = 'booked' and x.starts_at < s.starts_at + make_interval(mins => s.minutes)
               and x.starts_at + make_interval(mins => x.minutes) > s.starts_at) then
    raise exception '% already has a lesson at that time.', a.name;
  end if;
  insert into lessons (slot_id, club_id, coach_id, athlete_id, booked_by)
  values (s.id, s.club_id, s.coach_id, a.id, auth.uid()) returning id into v_id;
  update slots set status = 'booked' where id = s.id;
  return v_id;
end;
$$;

create or replace function public.cancel_lesson (p_lesson uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l lessons; s slots; c clubs; v_late boolean; v_staff boolean;
begin
  select * into l from lessons where id = p_lesson for update;
  if l.id is null then raise exception 'Lesson not found.'; end if;
  select * into s from slots where id = l.slot_id;
  select * into c from clubs where id = l.club_id;
  v_staff := l.coach_id = auth.uid() or has_role(l.club_id, 'owner', 'admin');
  if not (v_staff or l.booked_by = auth.uid() or athlete_is_mine(l.athlete_id)) then raise exception 'Not your lesson.'; end if;
  if l.status <> 'booked' then raise exception 'That lesson is already %.', replace(l.status, '_', ' '); end if;
  v_late := (not v_staff) and s.starts_at < now() + make_interval(hours => c.cancel_hours);
  update lessons set status = 'cancelled', late_cancel = v_late, cancelled_at = now(), cancelled_by = auth.uid() where id = l.id;
  if s.starts_at > now() then update slots set status = 'open' where id = s.id; end if;
  return jsonb_build_object('late', v_late, 'cancel_hours', c.cancel_hours);
end;
$$;

-- Coach wraps up a lesson: attended / no-show, notes for the family, homework,
-- and the skills worked on (each is also bumped in the athlete's progress).
create or replace function public.complete_lesson (p_lesson uuid, p_status text, p_notes text default null, p_homework text default null, p_worked_on text[] default '{}')
returns void
language plpgsql security definer set search_path = public as $$
declare l lessons; sk text;
begin
  select * into l from lessons where id = p_lesson;
  if l.id is null then raise exception 'Lesson not found.'; end if;
  if not (l.coach_id = auth.uid() or has_role(l.club_id, 'owner', 'admin')) then raise exception 'Coach only.'; end if;
  if p_status not in ('completed', 'no_show', 'booked') then raise exception 'Bad status.'; end if;
  update lessons set status = p_status, coach_notes = nullif(p_notes, ''), homework = nullif(p_homework, ''),
    worked_on = coalesce(p_worked_on, '{}') where id = l.id;
  foreach sk in array coalesce(p_worked_on, '{}') loop
    insert into progress (club_id, athlete_id, skill, status, updated_by)
    values (l.club_id, l.athlete_id, trim(sk), 'working_on', auth.uid())
    on conflict (athlete_id, skill) do update set updated_at = now(), updated_by = auth.uid();
  end loop;
end;
$$;

create or replace function public.set_progress (p_athlete uuid, p_skill text, p_status text, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare a athletes;
begin
  select * into a from athletes where id = p_athlete;
  if a.id is null then raise exception 'Athlete not found.'; end if;
  if not has_role(a.club_id, 'owner', 'admin', 'coach') then raise exception 'Coach only.'; end if;
  if p_status is null or p_status = '' then
    delete from progress where athlete_id = p_athlete and skill = trim(p_skill);
    return;
  end if;
  insert into progress (club_id, athlete_id, skill, status, note, updated_by)
  values (a.club_id, p_athlete, trim(p_skill), p_status, nullif(p_note, ''), auth.uid())
  on conflict (athlete_id, skill) do update
    set status = excluded.status, note = coalesce(excluded.note, progress.note), updated_by = auth.uid(), updated_at = now();
end;
$$;

create or replace function public.mark_paid (p_lesson uuid, p_paid boolean) returns void
language plpgsql security definer set search_path = public as $$
declare l lessons;
begin
  select * into l from lessons where id = p_lesson;
  if l.id is null then raise exception 'Lesson not found.'; end if;
  if not (has_role(l.club_id, 'owner', 'admin') or l.coach_id = auth.uid()) then raise exception 'Staff only.'; end if;
  update lessons set paid = p_paid, paid_at = case when p_paid then now() end where id = l.id;
end;
$$;

-- ---------------------------------------------------------------------------
-- RPC: the schedule (one query powers booking, family, coach and admin views)
-- ---------------------------------------------------------------------------
-- Returns slots in the range with their lesson (if any). Contact details and
-- medical notes are included only for the slot's coach, club staff, or when
-- the athlete is the caller's own. Other families' booked slots show as
-- "booked" with no names.
create or replace function public.club_schedule (p_club uuid, p_from timestamptz, p_to timestamptz) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_staff boolean := has_role(p_club, 'owner', 'admin');
begin
  if not is_member(p_club) then raise exception 'Not a member of this club.'; end if;
  return (
    select coalesce(jsonb_agg(row_json order by starts_at), '[]'::jsonb) from (
      select s.starts_at, jsonb_build_object(
        'slot_id', s.id, 'starts_at', s.starts_at, 'minutes', s.minutes, 'price_pence', s.price_pence, 'slot_status', s.status,
        'coach_id', s.coach_id, 'coach_name', cp.full_name,
        'lesson_id', l.id, 'lesson_status', l.status, 'paid', l.paid, 'notes', case when vis then l.coach_notes end,
        'homework', case when vis then l.homework end, 'worked_on', case when vis then l.worked_on end,
        'athlete_id', case when vis then a.id end, 'athlete_name', case when vis then a.name end,
        'athlete_age', case when vis and a.dob is not null then date_part('year', age(a.dob))::int end,
        'medical', case when vis and (v_staff or s.coach_id = v_uid) then a.medical_notes end,
        'goals', case when vis then a.goals end,
        'contact_name', case when vis and (v_staff or s.coach_id = v_uid) then coalesce(pp.full_name, ap.full_name) end,
        'contact_phone', case when vis and (v_staff or s.coach_id = v_uid) then coalesce(pp.phone, ap.phone) end,
        'contact_email', case when vis and (v_staff or s.coach_id = v_uid) then coalesce(pp.email, ap.email) end,
        'mine', coalesce(a.parent_id = v_uid or a.profile_id = v_uid, false)
      ) as row_json
      from slots s
      join profiles cp on cp.id = s.coach_id
      left join lessons l on l.slot_id = s.id and l.status <> 'cancelled'
      left join athletes a on a.id = l.athlete_id
      left join profiles pp on pp.id = a.parent_id
      left join profiles ap on ap.id = a.profile_id
      cross join lateral (select (l.id is not null) and (v_staff or s.coach_id = v_uid or has_role(p_club, 'coach') or a.parent_id = v_uid or a.profile_id = v_uid) as vis) v
      where s.club_id = p_club and s.starts_at >= p_from and s.starts_at < p_to and s.status <> 'cancelled'
    ) q
  );
end;
$$;

-- A family's (or athlete's) own lessons across time, newest first.
create or replace function public.my_lessons (p_club uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'lesson_id', l.id, 'status', l.status, 'paid', l.paid, 'late_cancel', l.late_cancel, 'starts_at', s.starts_at, 'minutes', s.minutes,
    'price_pence', s.price_pence, 'coach_name', cp.full_name, 'athlete_id', a.id, 'athlete_name', a.name,
    'notes', l.coach_notes, 'homework', l.homework, 'worked_on', l.worked_on
  ) order by s.starts_at desc), '[]'::jsonb)
  from lessons l join slots s on s.id = l.slot_id join athletes a on a.id = l.athlete_id join profiles cp on cp.id = l.coach_id
  where l.club_id = p_club and (a.parent_id = auth.uid() or a.profile_id = auth.uid() or l.booked_by = auth.uid())
$$;

-- Athlete's story: lessons + progress in one call (family, athlete, coach, staff).
create or replace function public.athlete_journey (p_athlete uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a athletes;
begin
  select * into a from athletes where id = p_athlete;
  if a.id is null then raise exception 'Athlete not found.'; end if;
  if not (athlete_is_mine(a.id) or has_role(a.club_id, 'owner', 'admin', 'coach')) then raise exception 'Not allowed.'; end if;
  return jsonb_build_object(
    'athlete', jsonb_build_object('id', a.id, 'name', a.name, 'dob', a.dob, 'goals', a.goals, 'notes', a.notes, 'medical', a.medical_notes, 'club_id', a.club_id,
      'age', case when a.dob is not null then date_part('year', age(a.dob))::int end),
    'progress', (select coalesce(jsonb_agg(jsonb_build_object('skill', p.skill, 'status', p.status, 'note', p.note, 'updated_at', p.updated_at) order by
        case p.status when 'working_on' then 0 when 'achieved' then 1 else 2 end, p.updated_at desc), '[]'::jsonb) from progress p where p.athlete_id = a.id),
    'lessons', (select coalesce(jsonb_agg(jsonb_build_object('lesson_id', l.id, 'status', l.status, 'starts_at', s.starts_at, 'coach_name', cp.full_name,
        'notes', l.coach_notes, 'homework', l.homework, 'worked_on', l.worked_on, 'paid', l.paid, 'price_pence', s.price_pence) order by s.starts_at desc), '[]'::jsonb)
      from lessons l join slots s on s.id = l.slot_id join profiles cp on cp.id = l.coach_id where l.athlete_id = a.id and l.status <> 'cancelled'),
    'stats', jsonb_build_object(
      'completed', (select count(*) from lessons where athlete_id = a.id and status = 'completed'),
      'achieved', (select count(*) from progress where athlete_id = a.id and status in ('achieved', 'mastered')),
      'working_on', (select count(*) from progress where athlete_id = a.id and status = 'working_on'))
  );
end;
$$;

-- Money view for staff: unpaid lessons and simple totals.
create or replace function public.club_money (p_club uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not has_role(p_club, 'owner', 'admin') then raise exception 'Club owner or admin only.'; end if;
  return jsonb_build_object(
    'unpaid', (select coalesce(jsonb_agg(jsonb_build_object('lesson_id', l.id, 'starts_at', s.starts_at, 'status', l.status, 'price_pence', s.price_pence,
        'athlete_name', a.name, 'coach_name', cp.full_name, 'payer_name', coalesce(pp.full_name, ap.full_name), 'payer_email', coalesce(pp.email, ap.email), 'late_cancel', l.late_cancel
      ) order by s.starts_at), '[]'::jsonb)
      from lessons l join slots s on s.id = l.slot_id join athletes a on a.id = l.athlete_id join profiles cp on cp.id = l.coach_id
      left join profiles pp on pp.id = a.parent_id left join profiles ap on ap.id = a.profile_id
      where l.club_id = p_club and not l.paid and (l.status in ('completed', 'no_show') or (l.status = 'cancelled' and l.late_cancel) or (l.status = 'booked' and s.starts_at < now()))),
    'collected_30d', (select coalesce(sum(s.price_pence), 0) from lessons l join slots s on s.id = l.slot_id where l.club_id = p_club and l.paid and l.paid_at > now() - interval '30 days'),
    'owed', (select coalesce(sum(s.price_pence), 0) from lessons l join slots s on s.id = l.slot_id
      where l.club_id = p_club and not l.paid and (l.status in ('completed', 'no_show') or (l.status = 'cancelled' and l.late_cancel) or (l.status = 'booked' and s.starts_at < now()))),
    'lessons_30d', (select count(*) from lessons l join slots s on s.id = l.slot_id where l.club_id = p_club and l.status = 'completed' and s.starts_at > now() - interval '30 days')
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
grant select on all tables in schema public to authenticated;
grant update on public.profiles to authenticated;
grant delete on public.invites to authenticated;
revoke all on all tables in schema public from anon;
revoke execute on all functions in schema public from anon, public;
grant execute on all functions in schema public to authenticated;
alter default privileges in schema public revoke execute on functions from public;

-- ---------------------------------------------------------------------------
-- Platform owner + demo club (harmless if the logins don't exist)
-- ---------------------------------------------------------------------------
update public.profiles set is_platform_owner = true where lower(email) = 'smithy.ns83@gmail.com';

do $$
declare
  v_club uuid;
  v_owner uuid := (select id from profiles where lower(email) = 'smithy.ns83+club@gmail.com');
  v_coach uuid := (select id from profiles where lower(email) = 'smithy.ns83+coach@gmail.com');
  v_parent uuid := (select id from profiles where lower(email) = 'smithy.ns83+probe1@gmail.com');
  v_ath uuid;
  v_next timestamp;
  d int;
begin
  if v_owner is null then return; end if;
  insert into clubs (name, slug, join_code, venue, created_by) values ('Storm 1-2-1 Academy', 'storm-121', 'STORM1', 'Storm Gym', v_owner) returning id into v_club;
  perform _merge_roles(v_club, v_owner, array['owner']);
  if v_coach is not null then perform _merge_roles(v_club, v_coach, array['coach']); end if;
  if v_parent is not null then
    perform _merge_roles(v_club, v_parent, array['parent']);
    insert into athletes (club_id, name, dob, parent_id, medical_notes, goals) values (v_club, 'Ava Probe', '2015-03-14', v_parent, 'Mild asthma — inhaler in bag', 'Standing back handspring by Christmas') returning id into v_ath;
    insert into progress (club_id, athlete_id, skill, status, updated_by) values
      (v_club, v_ath, 'Cartwheel', 'mastered', v_coach), (v_club, v_ath, 'Round-off', 'achieved', v_coach), (v_club, v_ath, 'Back walkover', 'working_on', v_coach);
    insert into athletes (club_id, name, dob, parent_id) values (v_club, 'Max Probe', '2013-09-02', v_parent);
  end if;
  if v_coach is not null then
    -- next 4 Tuesdays and Thursdays, 16:30–18:30 in 30-min slots
    v_next := date_trunc('day', now() at time zone 'Europe/London') + interval '1 day';
    for d in 0 .. 27 loop
      if extract(isodow from v_next + make_interval(days => d)) in (2, 4) then
        insert into slots (club_id, coach_id, starts_at, minutes, price_pence, created_by)
        select v_club, v_coach, (v_next + make_interval(days => d, mins => 16 * 60 + 30 + 30 * i)) at time zone 'Europe/London', 30, 2500, v_owner
        from generate_series(0, 3) i
        on conflict (coach_id, starts_at) do nothing;
      end if;
    end loop;
  end if;
end $$;
