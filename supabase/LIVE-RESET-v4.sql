-- ============================================================
-- LIVE RESET TO MULTI-CLUB v4 — run this WHOLE file ONCE in the
-- Supabase SQL editor. It wipes the old app schema (auth logins
-- survive), installs the multi-club schema, and re-seeds demo data.
-- ============================================================
do $$ begin
  perform cron.unschedule('ignyte-register-reminders');
exception when others then null; end $$;
do $$ begin
  perform cron.unschedule('ignyte-rebook-nudges');
exception when others then null; end $$;

drop schema public cascade;
create schema public;
grant usage on schema public to postgres, anon, authenticated, service_role;
grant all on schema public to postgres, service_role;
alter default privileges in schema public grant all on tables to postgres, anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to postgres, anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to postgres, anon, authenticated, service_role;

-- ============================================================================
-- IGNYTE CLUB MANAGER — Supabase schema v4 (MULTI-CLUB)
-- ----------------------------------------------------------------------------
-- One shared platform, many walled clubs. Every club-owned row carries
-- club_id; a membership table records role-per-club on a single login; RLS
-- enforces isolation in the database itself. Children are ONE record with
-- per-club enrolments (medical notes/consent never diverge). Join rules:
-- club code = instant membership; no code = request + admin approval.
-- Suspended club = full lock (owner retains access). Owner mutations inside
-- clubs require a time-boxed support grant and are audited.
-- ============================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
create type public.user_role as enum ('parent', 'athlete', 'coach', 'admin', 'owner');
create type public.club_role as enum ('parent', 'athlete', 'coach', 'admin');
create type public.member_status as enum ('active', 'pending', 'removed');
create type public.booking_status as enum ('booked', 'cancelled', 'late_cancelled');
create type public.attendance_status as enum ('present', 'absent');
create type public.waitlist_status as enum ('waiting', 'offered', 'booked', 'expired', 'cancelled');
create type public.skill_status as enum ('not_started', 'working_on', 'achieved', 'mastered');

-- ---------------------------------------------------------------------------
-- Tenant root + membership
-- ---------------------------------------------------------------------------
create table public.clubs (
  id uuid primary key default gen_random_uuid (),
  name text not null check (char_length(name) between 2 and 60),
  slug text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,28}[a-z0-9]$'),
  join_code text not null unique default upper(substr(md5(gen_random_uuid()::text), 1, 6)),
  status text not null default 'active' check (status in ('active', 'suspended', 'churned')),
  plan text not null default 'free' check (plan in ('free', 'club', 'comped')),
  blurb text,
  logo_path text,
  accent_color text check (accent_color ~ '^#[0-9a-fA-F]{6}$'),
  searchable boolean not null default true,
  contact_name text,
  contact_email text,
  billing_notes text,
  created_at timestamptz not null default now()
);

create table public.club_members (
  club_id uuid not null references public.clubs (id) on delete cascade,
  profile_id uuid not null,
  role public.club_role not null default 'parent',
  status public.member_status not null default 'active',
  created_at timestamptz not null default now(),
  primary key (club_id, profile_id)
);
create index club_members_profile_idx on public.club_members (profile_id, status);

-- Staff join by invite only (public paths can never mint coach/admin).
create table public.club_invites (
  id uuid primary key default gen_random_uuid (),
  club_id uuid not null references public.clubs (id) on delete cascade,
  role public.club_role not null check (role in ('coach', 'admin')),
  email text,
  created_by uuid not null,
  expires_at timestamptz not null default now() + interval '7 days',
  used_by uuid,
  used_at timestamptz,
  revoked boolean not null default false,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- People
-- ---------------------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null,
  email text not null,
  phone text,
  role public.user_role not null default 'parent', -- only 'owner' is meaningful platform-wide
  last_club_id uuid references public.clubs (id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.club_members
  add constraint club_members_profile_fk foreign key (profile_id) references public.profiles (id) on delete cascade;
alter table public.club_invites
  add constraint club_invites_creator_fk foreign key (created_by) references public.profiles (id) on delete cascade;

-- ONE record per child, family-owned; medical + consent never diverge.
create table public.athletes (
  id uuid primary key default gen_random_uuid (),
  parent_id uuid references public.profiles (id) on delete cascade,
  profile_id uuid unique references public.profiles (id) on delete cascade,
  name text not null,
  dob date not null,
  notes text,
  medical_notes text,
  media_consent boolean not null default false,
  created_at timestamptz not null default now(),
  constraint athlete_has_owner check (parent_id is not null or profile_id is not null)
);

-- A child may train at several clubs: one enrolment row per club.
create table public.athlete_enrolments (
  athlete_id uuid not null references public.athletes (id) on delete cascade,
  club_id uuid not null references public.clubs (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (athlete_id, club_id)
);
create index enrolments_club_idx on public.athlete_enrolments (club_id);

-- ---------------------------------------------------------------------------
-- Per-club configuration & operations
-- ---------------------------------------------------------------------------
create table public.club_settings (
  club_id uuid primary key references public.clubs (id) on delete cascade,
  timezone text not null default 'Europe/London',
  disciplines text[] not null default array['tumble', 'dance'],
  cancellation_notice_hours int not null default 24,
  cancellation_policy text not null
    default 'You can cancel at any time. Cancellations with less than 24 hours'' notice are still payable; the space is then offered to the waiting list.',
  waitlist_offer_hours int not null default 24,
  late_cancel_makeup_tokens boolean not null default true
);

create table public.locations (
  id uuid primary key default gen_random_uuid (),
  club_id uuid not null references public.clubs (id) on delete cascade,
  name text not null,
  address text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create index locations_club_idx on public.locations (club_id);

create table public.coach_profiles (
  club_id uuid not null references public.clubs (id) on delete cascade,
  coach_id uuid not null references public.profiles (id) on delete cascade,
  disciplines text[] not null default array['tumble', 'dance'],
  levels text,
  rate_per_lesson numeric(8, 2),
  bio text,
  booking_notice_mins int not null default 120 check (booking_notice_mins between 0 and 10080),
  booking_notice_adjacent_mins int not null default 15 check (booking_notice_adjacent_mins between 0 and 10080),
  updated_at timestamptz not null default now(),
  primary key (club_id, coach_id)
);

create table public.slots (
  id uuid primary key default gen_random_uuid (),
  club_id uuid not null references public.clubs (id) on delete cascade,
  slot_date date not null,
  start_time time not null,
  end_time time not null,
  capacity int not null check (capacity > 0),
  series_id uuid,
  location_id uuid references public.locations (id),
  notes text,
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  constraint slot_times check (end_time > start_time)
);
create index slots_club_date_idx on public.slots (club_id, slot_date, start_time);
create index slots_series_idx on public.slots (series_id) where series_id is not null;

create table public.slot_coaches (
  slot_id uuid not null references public.slots (id) on delete cascade,
  coach_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (slot_id, coach_id)
);

create table public.booking_series (
  id uuid primary key default gen_random_uuid (),
  club_id uuid not null references public.clubs (id) on delete cascade,
  series_id uuid not null,
  athlete_id uuid not null references public.athletes (id) on delete cascade,
  coach_id uuid not null references public.profiles (id),
  booked_by uuid not null references public.profiles (id),
  discipline_focus text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create index booking_series_club_idx on public.booking_series (club_id);

create table public.bookings (
  id uuid primary key default gen_random_uuid (),
  club_id uuid not null references public.clubs (id) on delete cascade,
  slot_id uuid not null references public.slots (id) on delete cascade,
  athlete_id uuid not null references public.athletes (id) on delete cascade,
  coach_id uuid not null references public.profiles (id),
  booked_by uuid not null references public.profiles (id),
  series_booking_id uuid references public.booking_series (id) on delete set null,
  discipline_focus text,
  status public.booking_status not null default 'booked',
  attendance public.attendance_status,
  attendance_marked_by uuid references public.profiles (id),
  attendance_marked_at timestamptz,
  cancelled_at timestamptz,
  cancelled_by uuid references public.profiles (id),
  created_at timestamptz not null default now()
);
create unique index bookings_coach_slot_uniq on public.bookings (slot_id, coach_id) where (status = 'booked');
create unique index bookings_athlete_slot_uniq on public.bookings (slot_id, athlete_id) where (status = 'booked');
create index bookings_club_idx on public.bookings (club_id);
create index bookings_athlete_idx on public.bookings (athlete_id);
create index bookings_coach_idx on public.bookings (coach_id);

create table public.waitlist (
  id uuid primary key default gen_random_uuid (),
  club_id uuid not null references public.clubs (id) on delete cascade,
  slot_id uuid not null references public.slots (id) on delete cascade,
  athlete_id uuid not null references public.athletes (id) on delete cascade,
  requested_coach_id uuid references public.profiles (id),
  created_by uuid not null references public.profiles (id),
  status public.waitlist_status not null default 'waiting',
  offered_at timestamptz,
  offer_expires_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index waitlist_active_uniq on public.waitlist (slot_id, athlete_id) where (status in ('waiting', 'offered'));
create index waitlist_club_idx on public.waitlist (club_id);

create table public.notifications (
  id uuid primary key default gen_random_uuid (),
  profile_id uuid not null references public.profiles (id) on delete cascade,
  club_id uuid references public.clubs (id) on delete set null, -- null = platform notice
  type text not null,
  title text not null,
  body text not null,
  data jsonb not null default '{}'::jsonb,
  read boolean not null default false,
  created_at timestamptz not null default now()
);
create index notifications_profile_idx on public.notifications (profile_id, read, created_at desc);

-- Skill library: club_id null = the platform template (owner-curated),
-- cloned into each club at provisioning.
create table public.skills (
  id serial primary key,
  club_id uuid references public.clubs (id) on delete cascade,
  discipline text not null,
  category text not null,
  name text not null,
  level int not null default 1,
  sort int not null default 0
);
create index skills_club_idx on public.skills (club_id);

create table public.athlete_skills (
  athlete_id uuid not null references public.athletes (id) on delete cascade,
  skill_id int not null references public.skills (id) on delete cascade,
  status public.skill_status not null default 'working_on',
  notes text,
  updated_by uuid references public.profiles (id),
  updated_at timestamptz not null default now(),
  primary key (athlete_id, skill_id)
);

create table public.progress_notes (
  id uuid primary key default gen_random_uuid (),
  club_id uuid not null references public.clubs (id) on delete cascade,
  athlete_id uuid not null references public.athletes (id) on delete cascade,
  coach_id uuid not null references public.profiles (id),
  booking_id uuid references public.bookings (id) on delete set null,
  note text not null,
  created_at timestamptz not null default now()
);
create index progress_notes_athlete_idx on public.progress_notes (athlete_id, club_id, created_at desc);

create table public.credit_ledger (
  id uuid primary key default gen_random_uuid (),
  club_id uuid not null references public.clubs (id) on delete cascade,
  profile_id uuid not null references public.profiles (id) on delete cascade,
  delta int not null check (delta between -1000 and 1000),
  reason text not null,
  booking_id uuid references public.bookings (id) on delete set null,
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now()
);
create index credit_ledger_profile_idx on public.credit_ledger (club_id, profile_id, created_at desc);

create table public.broadcasts (
  id uuid primary key default gen_random_uuid (),
  club_id uuid not null references public.clubs (id) on delete cascade,
  sender_id uuid not null references public.profiles (id),
  audience text not null check (audience in ('everyone', 'parents', 'coaches')),
  title text not null,
  body text not null,
  recipient_count int not null default 0,
  created_at timestamptz not null default now()
);

create table public.skill_media (
  id uuid primary key default gen_random_uuid (),
  club_id uuid not null references public.clubs (id) on delete cascade,
  athlete_id uuid not null references public.athletes (id) on delete cascade,
  skill_id int references public.skills (id) on delete set null,
  uploaded_by uuid not null references public.profiles (id),
  path text not null,
  note text,
  created_at timestamptz not null default now()
);

-- Platform-level: sales pipeline + owner audit.
create table public.club_leads (
  id uuid primary key default gen_random_uuid (),
  club_name text not null,
  contact_name text not null,
  email text not null,
  message text,
  status text not null default 'new' check (status in ('new', 'contacted', 'converted', 'closed')),
  created_at timestamptz not null default now()
);

create table public.owner_support_grants (
  club_id uuid primary key references public.clubs (id) on delete cascade,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create table public.owner_audit (
  id uuid primary key default gen_random_uuid (),
  club_id uuid references public.clubs (id) on delete set null,
  action text not null,
  detail text,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Helpers (security definer: never recurse through RLS)
-- ---------------------------------------------------------------------------
create or replace function public.is_owner () returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role from profiles where id = auth.uid()) = 'owner', false)
$$;

-- Clubs the caller can SEE. Members lose visibility while a club is
-- suspended/churned (full lock); the owner always sees everything.
create or replace function public.my_club_ids () returns setof uuid
language sql stable security definer set search_path = public as $$
  select c.id from clubs c
  where (select role from profiles where id = auth.uid()) = 'owner'
     or (c.status = 'active' and exists (
          select 1 from club_members m
          where m.club_id = c.id and m.profile_id = auth.uid() and m.status = 'active'))
$$;

create or replace function public.member_role (p_club uuid) returns public.club_role
language sql stable security definer set search_path = public as $$
  select role from club_members
  where club_id = p_club and profile_id = auth.uid() and status = 'active'
$$;

-- Owner mutations inside a club need a live, time-boxed support grant.
create or replace function public.is_owner_with_grant (p_club uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select is_owner() and exists (
    select 1 from owner_support_grants g where g.club_id = p_club and g.expires_at > now())
$$;

create or replace function public.is_admin_of (p_club uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(member_role(p_club) = 'admin', false) or is_owner_with_grant(p_club)
$$;

create or replace function public.is_coach_of (p_club uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(member_role(p_club) in ('coach', 'admin'), false) or is_owner_with_grant(p_club)
$$;

create or replace function public.owner_log (p_club uuid, p_action text, p_detail text default null)
returns void language sql security definer set search_path = public as $$
  insert into owner_audit (club_id, action, detail)
  select p_club, p_action, p_detail where is_owner()
$$;

create or replace function public.assert_club_active (p_club uuid)
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if (select status from clubs where id = p_club) <> 'active' then
    raise exception 'This club is currently unavailable.';
  end if;
end;
$$;

create or replace function public.owns_athlete (aid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from athletes a
    where a.id = aid and (a.parent_id = auth.uid() or a.profile_id = auth.uid()))
$$;

create or replace function public.athlete_in_club (aid uuid, p_club uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from athlete_enrolments e where e.athlete_id = aid and e.club_id = p_club)
$$;

-- Staff (coach/admin/owner-grant) of any club the athlete is enrolled in.
create or replace function public.staff_of_athlete (aid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from athlete_enrolments e
    where e.athlete_id = aid
      and (coalesce(member_role(e.club_id) in ('coach', 'admin'), false) or is_owner())
  )
$$;

create or replace function public.club_tz (p_club uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select timezone from club_settings where club_id = p_club), 'Europe/London')
$$;

create or replace function public.slot_starts_at (p_slot public.slots) returns timestamptz
language sql stable security definer set search_path = public as $$
  select (p_slot.slot_date + p_slot.start_time) at time zone club_tz(p_slot.club_id)
$$;

create or replace function public.notify (
  p_profile uuid, p_club uuid, p_type text, p_title text, p_body text, p_data jsonb default '{}'::jsonb
) returns void language sql security definer set search_path = public as $$
  insert into notifications (profile_id, club_id, type, title, body, data)
  values (p_profile, p_club, p_type, p_title, p_body, p_data)
$$;

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------
-- New signup: profile (+ athlete record for 18+ athletes). Club joining is a
-- soft attempt from metadata: join_code => instant member; join_slug alone =>
-- pending request. Failure never aborts the signup.
create or replace function public.handle_new_user () returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_role user_role := 'parent';
  v_dob date;
  v_club uuid;
begin
  if new.raw_user_meta_data ->> 'role' = 'athlete' then v_role := 'athlete'; end if;

  insert into profiles (id, full_name, email, phone, role)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data ->> 'full_name', ''), split_part(new.email, '@', 1)),
    new.email,
    nullif(new.raw_user_meta_data ->> 'phone', ''),
    v_role
  );

  if v_role = 'athlete' then
    v_dob := (new.raw_user_meta_data ->> 'dob')::date;
    if v_dob is null or v_dob > (current_date - interval '18 years') then
      raise exception 'Athletes must be 18 or over to hold their own account. Ask a parent/guardian to register instead.';
    end if;
    insert into athletes (profile_id, name, dob)
    values (new.id, coalesce(nullif(new.raw_user_meta_data ->> 'full_name', ''), split_part(new.email, '@', 1)), v_dob);
  end if;

  -- soft join attempt
  begin
    if nullif(new.raw_user_meta_data ->> 'join_code', '') is not null then
      select id into v_club from clubs
        where join_code = upper(new.raw_user_meta_data ->> 'join_code') and status = 'active';
      if v_club is not null then
        insert into club_members (club_id, profile_id, role, status)
        values (v_club, new.id, case when v_role = 'athlete' then 'athlete'::club_role else 'parent' end, 'active')
        on conflict do nothing;
        update profiles set last_club_id = v_club where id = new.id;
      end if;
    elsif nullif(new.raw_user_meta_data ->> 'join_slug', '') is not null then
      select id into v_club from clubs
        where slug = lower(new.raw_user_meta_data ->> 'join_slug') and status = 'active';
      if v_club is not null then
        insert into club_members (club_id, profile_id, role, status)
        values (v_club, new.id, case when v_role = 'athlete' then 'athlete'::club_role else 'parent' end, 'pending')
        on conflict do nothing;
      end if;
    end if;
  exception when others then null;
  end;
  return new;
end;
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user ();

-- profiles.role changes: owner only (it's the platform super-role switch).
create or replace function public.guard_role_change () returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.role is distinct from old.role and auth.uid() is not null and not is_owner() then
    raise exception 'Only the platform owner can change account-level roles.';
  end if;
  return new;
end;
$$;
create trigger profiles_role_guard
before update on public.profiles
for each row execute function public.guard_role_change ();

-- Coach membership => per-club coach profile row.
create or replace function public.ensure_coach_profile () returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.role in ('coach', 'admin') and new.status = 'active' then
    insert into coach_profiles (club_id, coach_id) values (new.club_id, new.profile_id)
    on conflict do nothing;
  end if;
  return new;
end;
$$;
create trigger members_coach_profile
after insert or update of role, status on public.club_members
for each row execute function public.ensure_coach_profile ();

-- ---------------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------------
alter table public.clubs enable row level security;
alter table public.club_members enable row level security;
alter table public.club_invites enable row level security;
alter table public.profiles enable row level security;
alter table public.athletes enable row level security;
alter table public.athlete_enrolments enable row level security;
alter table public.club_settings enable row level security;
alter table public.locations enable row level security;
alter table public.coach_profiles enable row level security;
alter table public.slots enable row level security;
alter table public.slot_coaches enable row level security;
alter table public.booking_series enable row level security;
alter table public.bookings enable row level security;
alter table public.waitlist enable row level security;
alter table public.notifications enable row level security;
alter table public.skills enable row level security;
alter table public.athlete_skills enable row level security;
alter table public.progress_notes enable row level security;
alter table public.credit_ledger enable row level security;
alter table public.broadcasts enable row level security;
alter table public.skill_media enable row level security;
alter table public.club_leads enable row level security;
alter table public.owner_support_grants enable row level security;
alter table public.owner_audit enable row level security;

-- clubs: members (any status — the lock screen needs name/status) + owner.
create policy clubs_select on public.clubs for select to authenticated
  using (is_owner() or exists (
    select 1 from club_members m where m.club_id = id and m.profile_id = auth.uid()));
create policy clubs_owner_write on public.clubs for all to authenticated
  using (is_owner()) with check (is_owner());

-- memberships: your own rows always; staff see their club's roster.
create policy members_select on public.club_members for select to authenticated
  using (profile_id = auth.uid() or is_coach_of(club_id) or is_owner());

create policy invites_select on public.club_invites for select to authenticated
  using (is_admin_of(club_id));

-- profiles: self; owner; staff of a shared club; members can see their clubs' staff.
create policy profiles_select on public.profiles for select to authenticated
  using (
    id = auth.uid() or is_owner()
    or exists (select 1 from club_members m1
               join club_members m2 on m2.club_id = m1.club_id
               where m1.profile_id = auth.uid() and m1.status = 'active'
                 and m2.profile_id = profiles.id and m2.status = 'active'
                 and (m1.role in ('coach', 'admin') or m2.role in ('coach', 'admin')))
  );
create policy profiles_update_self on public.profiles for update to authenticated
  using (id = auth.uid() or is_owner()) with check (id = auth.uid() or is_owner());

-- athletes: family; staff of an enrolled club.
create policy athletes_select on public.athletes for select to authenticated
  using (owns_athlete(id) or staff_of_athlete(id) or is_owner());
create policy athletes_insert on public.athletes for insert to authenticated
  with check (parent_id = auth.uid() or is_owner());
create policy athletes_update on public.athletes for update to authenticated
  using (owns_athlete(id) or is_owner());
create policy athletes_delete on public.athletes for delete to authenticated
  using (parent_id = auth.uid() or is_owner());

create policy enrolments_select on public.athlete_enrolments for select to authenticated
  using (owns_athlete(athlete_id) or is_coach_of(club_id) or is_owner());

-- club-scoped reads: active members via my_club_ids (suspended => invisible).
create policy settings_select on public.club_settings for select to authenticated
  using (club_id in (select my_club_ids()));
create policy locations_select on public.locations for select to authenticated
  using (club_id in (select my_club_ids()));
create policy locations_admin_write on public.locations for all to authenticated
  using (is_admin_of(club_id)) with check (is_admin_of(club_id));
create policy coach_profiles_select on public.coach_profiles for select to authenticated
  using (club_id in (select my_club_ids()));
create policy coach_profiles_write on public.coach_profiles for all to authenticated
  using ((coach_id = auth.uid() and member_role(club_id) in ('coach', 'admin')) or is_admin_of(club_id))
  with check ((coach_id = auth.uid() and member_role(club_id) in ('coach', 'admin')) or is_admin_of(club_id));
create policy slots_select on public.slots for select to authenticated
  using (club_id in (select my_club_ids()));
create policy slot_coaches_select on public.slot_coaches for select to authenticated
  using (exists (select 1 from slots s where s.id = slot_id and s.club_id in (select my_club_ids())));

create policy series_select on public.booking_series for select to authenticated
  using ((club_id in (select my_club_ids())) and
         (booked_by = auth.uid() or coach_id = auth.uid() or owns_athlete(athlete_id) or is_admin_of(club_id)));
create policy bookings_select on public.bookings for select to authenticated
  using ((club_id in (select my_club_ids())) and
         (booked_by = auth.uid() or coach_id = auth.uid() or owns_athlete(athlete_id) or is_admin_of(club_id)));
create policy waitlist_select on public.waitlist for select to authenticated
  using ((club_id in (select my_club_ids())) and
         (created_by = auth.uid() or owns_athlete(athlete_id) or is_admin_of(club_id)));

create policy notifications_select on public.notifications for select to authenticated
  using (profile_id = auth.uid());
create policy notifications_update on public.notifications for update to authenticated
  using (profile_id = auth.uid()) with check (profile_id = auth.uid());

-- skills: template rows (club_id null) readable by all; club rows by members.
create policy skills_select on public.skills for select to authenticated
  using (club_id is null or club_id in (select my_club_ids()));
create policy skills_admin_write on public.skills for all to authenticated
  using ((club_id is not null and is_admin_of(club_id)) or (club_id is null and is_owner()))
  with check ((club_id is not null and is_admin_of(club_id)) or (club_id is null and is_owner()));

create policy athlete_skills_select on public.athlete_skills for select to authenticated
  using (owns_athlete(athlete_id) or staff_of_athlete(athlete_id) or is_owner());
create policy progress_notes_select on public.progress_notes for select to authenticated
  using ((club_id in (select my_club_ids())) and (owns_athlete(athlete_id) or is_coach_of(club_id)));
create policy skill_media_select on public.skill_media for select to authenticated
  using ((club_id in (select my_club_ids())) and (owns_athlete(athlete_id) or is_coach_of(club_id)));
create policy skill_media_delete on public.skill_media for delete to authenticated
  using (uploaded_by = auth.uid() or is_admin_of(club_id));

create policy credit_ledger_select on public.credit_ledger for select to authenticated
  using ((club_id in (select my_club_ids())) and (profile_id = auth.uid() or is_admin_of(club_id)));

create policy broadcasts_select on public.broadcasts for select to authenticated
  using (is_admin_of(club_id));

create policy club_leads_insert on public.club_leads for insert to anon, authenticated with check (true);
create policy club_leads_owner on public.club_leads for select to authenticated using (is_owner());
create policy club_leads_owner_update on public.club_leads for update to authenticated
  using (is_owner()) with check (is_owner());

create policy support_grants_owner on public.owner_support_grants for all to authenticated
  using (is_owner()) with check (is_owner());
create policy owner_audit_select on public.owner_audit for select to authenticated using (is_owner());

-- ===========================================================================
-- RPCs — every write flows through these (security definer; club-aware).
-- ===========================================================================

-- ---------- public / discovery ----------
create or replace function public.get_club_public (p_slug text) returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(t) from (
    select c.name, c.slug, c.blurb, c.logo_path, c.accent_color, c.status,
      (select coalesce(jsonb_agg(jsonb_build_object('name', p.full_name, 'disciplines', cp.disciplines, 'levels', cp.levels) order by p.full_name), '[]'::jsonb)
       from club_members m join profiles p on p.id = m.profile_id
       left join coach_profiles cp on cp.club_id = c.id and cp.coach_id = p.id
       where m.club_id = c.id and m.role = 'coach' and m.status = 'active') as coaches,
      (select count(*) from slots s where s.club_id = c.id and s.slot_date >= current_date and s.slot_date < current_date + 14) as upcoming_slots,
      (select coalesce(jsonb_agg(l.name), '[]'::jsonb) from locations l where l.club_id = c.id and l.active) as locations
    from clubs c where c.slug = lower(p_slug) and c.status = 'active' and c.searchable
  ) t
$$;

create or replace function public.clubs_search (p_q text) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('name', name, 'slug', slug, 'blurb', blurb) order by name), '[]'::jsonb)
  from clubs
  where status = 'active' and searchable and (p_q is null or p_q = '' or name ilike '%' || p_q || '%')
  limit 25
$$;

-- ---------- joining ----------
create or replace function public.join_by_code (p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_club clubs%rowtype;
  v_role club_role;
begin
  select * into v_club from clubs where join_code = upper(trim(p_code)) and status = 'active';
  if v_club.id is null then raise exception 'That code doesn''t match any club.'; end if;
  v_role := case when (select role from profiles where id = auth.uid()) = 'athlete' then 'athlete'::club_role else 'parent' end;
  insert into club_members (club_id, profile_id, role, status)
  values (v_club.id, auth.uid(), v_role, 'active')
  on conflict (club_id, profile_id) do update set status = 'active'
    where club_members.status <> 'active';
  update profiles set last_club_id = v_club.id where id = auth.uid();
  return jsonb_build_object('club_id', v_club.id, 'name', v_club.name, 'slug', v_club.slug);
end;
$$;

create or replace function public.request_join (p_slug text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_club clubs%rowtype;
  v_role club_role;
  r record;
begin
  select * into v_club from clubs where slug = lower(trim(p_slug)) and status = 'active';
  if v_club.id is null then raise exception 'Club not found.'; end if;
  if exists (select 1 from club_members where club_id = v_club.id and profile_id = auth.uid() and status = 'active') then
    return jsonb_build_object('status', 'active', 'club_id', v_club.id);
  end if;
  v_role := case when (select role from profiles where id = auth.uid()) = 'athlete' then 'athlete'::club_role else 'parent' end;
  insert into club_members (club_id, profile_id, role, status)
  values (v_club.id, auth.uid(), v_role, 'pending')
  on conflict (club_id, profile_id) do update set status = 'pending'
    where club_members.status = 'removed';
  for r in select profile_id from club_members where club_id = v_club.id and role = 'admin' and status = 'active' loop
    perform notify(r.profile_id, v_club.id, 'join_request', 'New join request',
      (select full_name from profiles where id = auth.uid()) || ' asked to join ' || v_club.name || ' — approve them in Admin → People.',
      jsonb_build_object('profile_id', auth.uid()));
  end loop;
  return jsonb_build_object('status', 'pending', 'club_id', v_club.id);
end;
$$;

create or replace function public.approve_member (p_club uuid, p_profile uuid, p_approve boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin_of(p_club) then raise exception 'Admins only.'; end if;
  if p_approve then
    update club_members set status = 'active' where club_id = p_club and profile_id = p_profile and status = 'pending';
    perform notify(p_profile, p_club, 'join_approved', 'Welcome aboard! 🎉',
      'Your request to join ' || (select name from clubs where id = p_club) || ' was approved.', '{}'::jsonb);
    perform owner_log(p_club, 'approve_member', p_profile::text);
  else
    delete from club_members where club_id = p_club and profile_id = p_profile and status = 'pending';
    perform notify(p_profile, null, 'join_declined', 'Join request declined',
      (select name from clubs where id = p_club) || ' declined your join request. Contact the club if you think this is a mistake.', '{}'::jsonb);
  end if;
end;
$$;

create or replace function public.remove_member (p_club uuid, p_profile uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin_of(p_club) then raise exception 'Admins only.'; end if;
  if p_profile = auth.uid() then raise exception 'You can''t remove yourself.'; end if;
  update club_members set status = 'removed' where club_id = p_club and profile_id = p_profile;
  perform owner_log(p_club, 'remove_member', p_profile::text);
end;
$$;

create or replace function public.set_member_role (p_club uuid, p_profile uuid, p_role public.club_role)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin_of(p_club) then raise exception 'Admins only.'; end if;
  update club_members set role = p_role where club_id = p_club and profile_id = p_profile and status = 'active';
  perform owner_log(p_club, 'set_member_role', p_profile::text || '=>' || p_role);
end;
$$;

-- ---------- staff invites ----------
create or replace function public.create_club_invite (p_club uuid, p_role public.club_role, p_email text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not is_admin_of(p_club) then raise exception 'Admins only.'; end if;
  if p_role not in ('coach', 'admin') then raise exception 'Invites are for staff roles.'; end if;
  insert into club_invites (club_id, role, email, created_by)
  values (p_club, p_role, lower(nullif(trim(p_email), '')), auth.uid())
  returning id into v_id;
  perform owner_log(p_club, 'create_invite', p_role::text);
  return v_id;
end;
$$;

create or replace function public.accept_club_invite (p_invite uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_i club_invites%rowtype;
begin
  select * into v_i from club_invites where id = p_invite for update;
  if v_i.id is null or v_i.revoked or v_i.used_by is not null or v_i.expires_at < now() then
    raise exception 'This invite is no longer valid — ask the club for a new one.';
  end if;
  if v_i.email is not null and v_i.email <> (select lower(email) from profiles where id = auth.uid()) then
    raise exception 'This invite was sent to a different email address.';
  end if;
  perform assert_club_active(v_i.club_id);
  insert into club_members (club_id, profile_id, role, status)
  values (v_i.club_id, auth.uid(), v_i.role, 'active')
  on conflict (club_id, profile_id) do update set role = excluded.role, status = 'active';
  update club_invites set used_by = auth.uid(), used_at = now() where id = p_invite;
  update profiles set last_club_id = v_i.club_id where id = auth.uid();
  return jsonb_build_object('club_id', v_i.club_id, 'role', v_i.role,
    'name', (select name from clubs where id = v_i.club_id));
end;
$$;

create or replace function public.revoke_club_invite (p_invite uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update club_invites set revoked = true
  where id = p_invite and is_admin_of(club_id);
end;
$$;

-- Anonymous invite preview (club name + role, nothing else).
create or replace function public.get_invite_public (p_invite uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('club', c.name, 'role', i.role,
    'valid', (not i.revoked and i.used_by is null and i.expires_at > now() and c.status = 'active'))
  from club_invites i join clubs c on c.id = i.club_id where i.id = p_invite
$$;

-- ---------- provisioning (full self-serve) ----------
create or replace function public.provision_club (
  p_name text, p_slug text, p_timezone text default 'Europe/London',
  p_disciplines text[] default array['tumble', 'dance'], p_location text default 'Main venue'
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_club uuid;
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  insert into clubs (name, slug, contact_name, contact_email)
  values (trim(p_name), lower(trim(p_slug)),
    (select full_name from profiles where id = auth.uid()),
    (select email from profiles where id = auth.uid()))
  returning id into v_club;
  insert into club_settings (club_id, timezone, disciplines) values (v_club, p_timezone, p_disciplines);
  insert into club_members (club_id, profile_id, role, status) values (v_club, auth.uid(), 'admin', 'active');
  insert into locations (club_id, name) values (v_club, coalesce(nullif(trim(p_location), ''), 'Main venue'));
  insert into skills (club_id, discipline, category, name, level, sort)
    select v_club, discipline, category, name, level, sort from skills where club_id is null;
  update profiles set last_club_id = v_club where id = auth.uid();
  insert into owner_audit (club_id, action, detail) values (v_club, 'club_provisioned', trim(p_name));
  return jsonb_build_object('club_id', v_club, 'slug', lower(trim(p_slug)),
    'join_code', (select join_code from clubs where id = v_club));
end;
$$;

-- ---------- club settings & branding ----------
create or replace function public.update_club_branding (
  p_club uuid, p_name text default null, p_blurb text default null,
  p_accent text default null, p_logo_path text default null, p_searchable boolean default null
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin_of(p_club) then raise exception 'Admins only.'; end if;
  if (p_accent is not null or p_logo_path is not null)
     and (select plan from clubs where id = p_club) = 'free' then
    raise exception 'Custom colours and logos are part of the paid Club plan.';
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

create or replace function public.rotate_join_code (p_club uuid) returns text
language plpgsql security definer set search_path = public as $$
declare v_code text;
begin
  if not is_admin_of(p_club) then raise exception 'Admins only.'; end if;
  v_code := upper(substr(md5(gen_random_uuid()::text), 1, 6));
  update clubs set join_code = v_code where id = p_club;
  return v_code;
end;
$$;

create or replace function public.update_club_settings (
  p_club uuid, p_timezone text, p_disciplines text[], p_notice_hours int,
  p_policy text, p_offer_hours int, p_makeups boolean
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin_of(p_club) then raise exception 'Admins only.'; end if;
  update club_settings set timezone = p_timezone, disciplines = p_disciplines,
    cancellation_notice_hours = p_notice_hours, cancellation_policy = p_policy,
    waitlist_offer_hours = p_offer_hours, late_cancel_makeup_tokens = p_makeups
  where club_id = p_club;
  perform owner_log(p_club, 'update_settings', null);
end;
$$;

-- ---------- athletes & enrolment ----------
create or replace function public.enrol_athlete (p_athlete uuid, p_club uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not (owns_athlete(p_athlete) or is_admin_of(p_club)) then
    raise exception 'You can only enrol your own athletes.';
  end if;
  perform assert_club_active(p_club);
  if not exists (select 1 from club_members where club_id = p_club and profile_id = auth.uid() and status = 'active')
     and not is_admin_of(p_club) then
    raise exception 'Join the club before enrolling athletes.';
  end if;
  insert into athlete_enrolments (athlete_id, club_id) values (p_athlete, p_club)
  on conflict do nothing;
end;
$$;

create or replace function public.unenrol_athlete (p_athlete uuid, p_club uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not (owns_athlete(p_athlete) or is_admin_of(p_club)) then
    raise exception 'You can only manage your own athletes.';
  end if;
  if exists (select 1 from bookings b join slots s on s.id = b.slot_id
             where b.athlete_id = p_athlete and b.club_id = p_club and b.status = 'booked'
               and slot_starts_at(s) > now()) then
    raise exception 'Cancel this athlete''s upcoming lessons at the club first.';
  end if;
  delete from athlete_enrolments where athlete_id = p_athlete and club_id = p_club;
end;
$$;

-- ---------- slots (admin) ----------
create or replace function public.admin_create_slots (
  p_club uuid, p_date date, p_start time, p_capacity int,
  p_weeks int default 1, p_end time default null, p_interval_mins int default 30,
  p_location uuid default null, p_notes text default null
) returns int language plpgsql security definer set search_path = public as $$
declare
  v_loc uuid;
  v_t time;
  v_slot_end time;
  v_series uuid;
  v_created int := 0;
  i int;
begin
  if not is_admin_of(p_club) then raise exception 'Only club admins can create slots.'; end if;
  perform assert_club_active(p_club);
  if p_weeks < 1 or p_weeks > 52 then raise exception 'Weeks must be between 1 and 52.'; end if;
  if p_interval_mins not in (30, 60) then raise exception 'Interval must be 30 or 60 minutes.'; end if;
  if p_end is not null and p_end <= p_start then raise exception 'End time must be after the start time.'; end if;

  v_loc := coalesce(p_location, (select id from locations where club_id = p_club and active order by created_at limit 1));
  if v_loc is null or (select club_id from locations where id = v_loc) <> p_club then
    raise exception 'Pick one of this club''s locations (add one under Admin → Locations).';
  end if;

  v_t := p_start;
  loop
    v_slot_end := v_t + make_interval(mins => p_interval_mins);
    exit when p_end is not null and v_slot_end > p_end;
    v_series := case when p_weeks > 1 then gen_random_uuid() end;
    for i in 0 .. p_weeks - 1 loop
      insert into slots (club_id, slot_date, start_time, end_time, capacity, series_id, location_id, notes, created_by)
      values (p_club, p_date + (i * 7), v_t, v_slot_end, p_capacity, v_series, v_loc, p_notes, auth.uid());
      v_created := v_created + 1;
    end loop;
    exit when p_end is null;
    v_t := v_slot_end;
  end loop;
  perform owner_log(p_club, 'create_slots', v_created::text);
  return v_created;
end;
$$;

create or replace function public.admin_extend_series (p_series_id uuid, p_weeks int)
returns int language plpgsql security definer set search_path = public as $$
declare
  v_last slots%rowtype;
  v_new_id uuid;
  v_created int := 0;
  i int;
  r record;
begin
  select * into v_last from slots where series_id = p_series_id order by slot_date desc limit 1;
  if v_last.id is null then raise exception 'Series not found.'; end if;
  if not is_admin_of(v_last.club_id) then raise exception 'Only club admins can extend a series.'; end if;
  perform assert_club_active(v_last.club_id);

  for i in 1 .. p_weeks loop
    insert into slots (club_id, slot_date, start_time, end_time, capacity, series_id, location_id, notes, created_by)
    values (v_last.club_id, v_last.slot_date + (i * 7), v_last.start_time, v_last.end_time, v_last.capacity,
            p_series_id, v_last.location_id, v_last.notes, auth.uid())
    returning id into v_new_id;
    v_created := v_created + 1;
    insert into slot_coaches (slot_id, coach_id)
      select v_new_id, sc.coach_id from slot_coaches sc where sc.slot_id = v_last.id;
    for r in select * from booking_series bs where bs.series_id = p_series_id and bs.active loop
      begin
        perform _create_booking(v_new_id, r.athlete_id, r.coach_id, r.booked_by, r.id, true);
      exception when others then null;
      end;
    end loop;
  end loop;
  return v_created;
end;
$$;

create or replace function public.admin_delete_slot (p_slot_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_slot slots%rowtype;
  r record;
begin
  select * into v_slot from slots where id = p_slot_id for update;
  if v_slot.id is null then raise exception 'Slot not found.'; end if;
  if not is_admin_of(v_slot.club_id) then raise exception 'Only club admins can remove slots.'; end if;
  for r in select * from bookings where slot_id = p_slot_id and status = 'booked' loop
    update bookings set status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid() where id = r.id;
    perform notify(r.booked_by, v_slot.club_id, 'booking_cancelled', 'Lesson cancelled by the club',
      'Your ' || to_char(v_slot.slot_date, 'FMDay DD Mon') || ' ' || to_char(v_slot.start_time, 'HH24:MI')
      || ' lesson was cancelled by the club.', jsonb_build_object('slot_id', p_slot_id));
  end loop;
  for r in select distinct created_by from waitlist where slot_id = p_slot_id and status in ('waiting', 'offered') loop
    perform notify(r.created_by, v_slot.club_id, 'slot_removed', 'Slot removed',
      'A slot you were waiting on was removed by the club.', jsonb_build_object('slot_id', p_slot_id));
  end loop;
  delete from slots where id = p_slot_id;
  perform owner_log(v_slot.club_id, 'delete_slot', p_slot_id::text);
end;
$$;

-- ---------- coach slot membership ----------
create or replace function public.coach_join_slot (p_slot_id uuid, p_whole_series boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare v_slot slots%rowtype;
begin
  select * into v_slot from slots where id = p_slot_id;
  if v_slot.id is null then raise exception 'Slot not found.'; end if;
  if not is_coach_of(v_slot.club_id) then raise exception 'Only this club''s coaches can join its slots.'; end if;
  perform assert_club_active(v_slot.club_id);
  if p_whole_series and v_slot.series_id is not null then
    insert into slot_coaches (slot_id, coach_id)
      select s.id, auth.uid() from slots s
      where s.series_id = v_slot.series_id and s.slot_date >= v_slot.slot_date
    on conflict do nothing;
  else
    insert into slot_coaches (slot_id, coach_id) values (p_slot_id, auth.uid()) on conflict do nothing;
  end if;
end;
$$;

create or replace function public.coach_leave_slot (p_slot_id uuid, p_whole_series boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare v_slot slots%rowtype;
begin
  select * into v_slot from slots where id = p_slot_id;
  if v_slot.id is null then raise exception 'Slot not found.'; end if;
  if p_whole_series and v_slot.series_id is not null then
    if exists (select 1 from bookings b join slots s on s.id = b.slot_id
               where s.series_id = v_slot.series_id and s.slot_date >= v_slot.slot_date
                 and b.coach_id = auth.uid() and b.status = 'booked') then
      raise exception 'You still have booked lessons in this series — cancel those first.';
    end if;
    delete from slot_coaches sc using slots s
      where sc.slot_id = s.id and s.series_id = v_slot.series_id
        and s.slot_date >= v_slot.slot_date and sc.coach_id = auth.uid();
  else
    if exists (select 1 from bookings where slot_id = p_slot_id and coach_id = auth.uid() and status = 'booked') then
      raise exception 'You still have a booked lesson in this slot — cancel it first.';
    end if;
    delete from slot_coaches where slot_id = p_slot_id and coach_id = auth.uid();
  end if;
end;
$$;

-- ---------- the slot board ----------
create or replace function public.get_slot_board (p_club uuid, p_from date, p_to date)
returns jsonb language sql stable security definer set search_path = public as $$
  select case
    when p_club not in (select my_club_ids()) then '[]'::jsonb
    else coalesce((
      select jsonb_agg(to_jsonb(t) order by t.slot_date, t.start_time) from (
        select
          s.id, s.slot_date, s.start_time, s.end_time, s.capacity, s.series_id, s.notes,
          s.location_id, l.name as location,
          (select count(*) from bookings b where b.slot_id = s.id and b.status = 'booked') as booked,
          (select count(*) from waitlist w where w.slot_id = s.id and w.status in ('waiting', 'offered')) as waiting,
          coalesce((
            select jsonb_agg(jsonb_build_object(
              'id', p.id, 'name', p.full_name,
              'busy', exists (select 1 from bookings b2 where b2.slot_id = s.id and b2.coach_id = p.id and b2.status = 'booked'),
              'disciplines', cp.disciplines, 'levels', cp.levels, 'rate', cp.rate_per_lesson
            ) order by p.full_name)
            from slot_coaches sc
            join profiles p on p.id = sc.coach_id
            left join coach_profiles cp on cp.club_id = s.club_id and cp.coach_id = p.id
            where sc.slot_id = s.id
          ), '[]'::jsonb) as coaches
        from slots s
        left join locations l on l.id = s.location_id
        where s.club_id = p_club and s.slot_date between p_from and p_to
      ) t), '[]'::jsonb)
  end
$$;

-- ---------- booking core ----------
create or replace function public._create_booking (
  p_slot_id uuid, p_athlete_id uuid, p_coach_id uuid, p_booked_by uuid,
  p_series_booking_id uuid default null, p_skip_notice boolean default false
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_slot slots%rowtype;
  v_id uuid;
  v_notice int;
  v_adj int;
  v_adjacent boolean;
begin
  select * into v_slot from slots where id = p_slot_id for update;
  if v_slot.id is null then raise exception 'Slot not found.'; end if;
  if slot_starts_at(v_slot) < now() then raise exception 'That slot is in the past.'; end if;
  if not athlete_in_club(p_athlete_id, v_slot.club_id) then
    raise exception 'This athlete isn''t enrolled at this club yet.';
  end if;
  if not exists (select 1 from slot_coaches where slot_id = p_slot_id and coach_id = p_coach_id) then
    raise exception 'That coach is not available in this slot.';
  end if;

  if not p_skip_notice then
    select coalesce(cp.booking_notice_mins, 120), coalesce(cp.booking_notice_adjacent_mins, 15)
      into v_notice, v_adj from (values (1)) as one
      left join coach_profiles cp on cp.club_id = v_slot.club_id and cp.coach_id = p_coach_id;
    select exists (
      select 1 from bookings b join slots s2 on s2.id = b.slot_id
      where b.coach_id = p_coach_id and b.status = 'booked' and s2.id <> v_slot.id
        and s2.slot_date = v_slot.slot_date
        and s2.location_id is not distinct from v_slot.location_id
        and ((s2.end_time <= v_slot.start_time and v_slot.start_time - s2.end_time <= interval '60 minutes')
          or (s2.start_time >= v_slot.end_time and s2.start_time - v_slot.end_time <= interval '60 minutes'))
    ) into v_adjacent;
    if now() > slot_starts_at(v_slot) - make_interval(mins => case when v_adjacent then v_adj else v_notice end) then
      raise exception 'Online booking with this coach closes % minutes before the lesson — please contact the club.',
        case when v_adjacent then v_adj else v_notice end;
    end if;
  end if;

  if exists (select 1 from bookings where slot_id = p_slot_id and coach_id = p_coach_id and status = 'booked') then
    raise exception 'That coach is already booked in this slot.';
  end if;
  if exists (select 1 from bookings where slot_id = p_slot_id and athlete_id = p_athlete_id and status = 'booked') then
    raise exception 'This athlete already has a lesson in this slot.';
  end if;
  if (select count(*) from bookings where slot_id = p_slot_id and status = 'booked') >= v_slot.capacity then
    raise exception 'This slot is full.';
  end if;

  insert into bookings (club_id, slot_id, athlete_id, coach_id, booked_by, series_booking_id)
  values (v_slot.club_id, p_slot_id, p_athlete_id, p_coach_id, p_booked_by, p_series_booking_id)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.book_slot (
  p_slot_id uuid, p_athlete_id uuid, p_coach_id uuid,
  p_weekly boolean default false, p_discipline text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_slot slots%rowtype;
  v_series_booking uuid;
  v_booked int := 0;
  v_skipped int := 0;
  v_athlete text;
  v_when text;
  v_ds text[];
  v_bid uuid;
  v_credit_used boolean := false;
  v_admin boolean;
  r record;
begin
  select * into v_slot from slots where id = p_slot_id;
  if v_slot.id is null then raise exception 'Slot not found.'; end if;
  v_admin := is_admin_of(v_slot.club_id);
  if not (owns_athlete(p_athlete_id) or v_admin) then
    raise exception 'You can only book for your own athletes.';
  end if;
  perform assert_club_active(v_slot.club_id);
  if not v_admin and not exists (select 1 from club_members
      where club_id = v_slot.club_id and profile_id = auth.uid() and status = 'active') then
    raise exception 'Join this club before booking.';
  end if;

  if p_discipline is not null then
    if not (p_discipline = 'both' or p_discipline = any ((select disciplines from club_settings where club_id = v_slot.club_id))) then
      raise exception 'Unknown discipline for this club.';
    end if;
    select disciplines into v_ds from coach_profiles where club_id = v_slot.club_id and coach_id = p_coach_id;
    if v_ds is not null then
      if p_discipline = 'both' and cardinality(v_ds) < 2 then
        raise exception 'That coach doesn''t cover both disciplines.';
      elsif p_discipline <> 'both' and not (p_discipline = any (v_ds)) then
        raise exception 'That coach doesn''t coach %.', p_discipline;
      end if;
    end if;
  end if;

  select name into v_athlete from athletes where id = p_athlete_id;
  v_when := to_char(v_slot.slot_date, 'FMDay DD Mon') || ' at ' || to_char(v_slot.start_time, 'HH24:MI');

  if p_weekly then
    if v_slot.series_id is null then raise exception 'This slot is a one-off and can''t be booked weekly.'; end if;
    insert into booking_series (club_id, series_id, athlete_id, coach_id, booked_by, discipline_focus)
    values (v_slot.club_id, v_slot.series_id, p_athlete_id, p_coach_id, auth.uid(), p_discipline)
    returning id into v_series_booking;

    for r in select * from slots s where s.series_id = v_slot.series_id
             and s.slot_date >= v_slot.slot_date order by s.slot_date loop
      begin
        v_bid := _create_booking(r.id, p_athlete_id, p_coach_id, auth.uid(), v_series_booking, v_admin);
        update bookings set discipline_focus = p_discipline where id = v_bid;
        v_booked := v_booked + 1;
      exception when others then
        v_skipped := v_skipped + 1;
      end;
    end loop;
    if v_booked = 0 then raise exception 'No weeks in this series could be booked with that coach.'; end if;
    perform notify(auth.uid(), v_slot.club_id, 'booking_confirmed', 'Weekly lesson booked',
      v_booked || ' weekly lessons booked from ' || v_when || '.', jsonb_build_object('series_booking_id', v_series_booking));
    perform notify(p_coach_id, v_slot.club_id, 'new_booking', 'New weekly booking',
      v_athlete || ' booked ' || v_booked || ' weekly lessons with you from ' || v_when
      || coalesce(' (' || p_discipline || ')', '') || '.', jsonb_build_object('series_booking_id', v_series_booking));
    return jsonb_build_object('series_booking_id', v_series_booking, 'booked', v_booked, 'skipped', v_skipped);
  else
    v_bid := _create_booking(p_slot_id, p_athlete_id, p_coach_id, auth.uid(), null, v_admin);
    update bookings set discipline_focus = p_discipline where id = v_bid;

    if (select coalesce(sum(delta), 0) from credit_ledger
        where club_id = v_slot.club_id and profile_id = auth.uid()) > 0 then
      insert into credit_ledger (club_id, profile_id, delta, reason, booking_id, created_by)
      values (v_slot.club_id, auth.uid(), -1, 'Lesson credit used', v_bid, auth.uid());
      v_credit_used := true;
    end if;

    perform notify(auth.uid(), v_slot.club_id, 'booking_confirmed', 'Lesson booked',
      'Lesson booked for ' || v_when || '.' || case when v_credit_used then ' 1 lesson credit used.' else '' end,
      jsonb_build_object('slot_id', p_slot_id));
    perform notify(p_coach_id, v_slot.club_id, 'new_booking', 'New booking',
      v_athlete || ' booked a lesson with you on ' || v_when
      || coalesce(' (' || p_discipline || ')', '') || '.', jsonb_build_object('slot_id', p_slot_id));
    return jsonb_build_object('booked', 1, 'skipped', 0, 'credit_used', v_credit_used);
  end if;
end;
$$;

create or replace function public.promote_waitlist (p_slot_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_slot slots%rowtype;
  v_free int;
  v_offer_hours int;
  r record;
  v_has_free_coach boolean;
begin
  select * into v_slot from slots where id = p_slot_id for update;
  if v_slot.id is null then return; end if;
  if slot_starts_at(v_slot) < now() then return; end if;
  if (select status from clubs where id = v_slot.club_id) <> 'active' then return; end if;

  update waitlist set status = 'expired'
    where slot_id = p_slot_id and status = 'offered' and offer_expires_at < now();
  select waitlist_offer_hours into v_offer_hours from club_settings where club_id = v_slot.club_id;

  loop
    v_free := v_slot.capacity
      - (select count(*) from bookings where slot_id = p_slot_id and status = 'booked')
      - (select count(*) from waitlist where slot_id = p_slot_id and status = 'offered');
    exit when v_free <= 0;
    select * into r from waitlist w
      where w.slot_id = p_slot_id and w.status = 'waiting'
        and (w.requested_coach_id is null
          or (exists (select 1 from slot_coaches sc where sc.slot_id = p_slot_id and sc.coach_id = w.requested_coach_id)
              and not exists (select 1 from bookings b where b.slot_id = p_slot_id and b.coach_id = w.requested_coach_id and b.status = 'booked')))
      order by w.created_at limit 1;
    exit when r.id is null;
    if r.requested_coach_id is null then
      select exists (
        select 1 from slot_coaches sc where sc.slot_id = p_slot_id
        and not exists (select 1 from bookings b where b.slot_id = p_slot_id and b.coach_id = sc.coach_id and b.status = 'booked')
      ) into v_has_free_coach;
      exit when not v_has_free_coach;
    end if;
    update waitlist set status = 'offered', offered_at = now(),
      offer_expires_at = now() + make_interval(hours => coalesce(v_offer_hours, 24))
      where id = r.id;
    perform notify(r.created_by, v_slot.club_id, 'waitlist_offer', 'A space has opened up!',
      'A space is free on ' || to_char(v_slot.slot_date, 'FMDay DD Mon') || ' at '
      || to_char(v_slot.start_time, 'HH24:MI') || '. Accept it from your bookings page within '
      || coalesce(v_offer_hours, 24) || ' hours.', jsonb_build_object('waitlist_id', r.id, 'slot_id', p_slot_id));
  end loop;
end;
$$;

create or replace function public.cancel_booking (p_booking_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_b bookings%rowtype;
  v_slot slots%rowtype;
  v_notice int;
  v_late boolean;
  v_makeups boolean;
  v_had_credit boolean;
begin
  select * into v_b from bookings where id = p_booking_id for update;
  if v_b.id is null then raise exception 'Booking not found.'; end if;
  if v_b.status <> 'booked' then raise exception 'This booking is already cancelled.'; end if;
  if not (v_b.booked_by = auth.uid() or v_b.coach_id = auth.uid() or owns_athlete(v_b.athlete_id) or is_admin_of(v_b.club_id)) then
    raise exception 'You can''t cancel this booking.';
  end if;

  select * into v_slot from slots where id = v_b.slot_id;
  select cancellation_notice_hours, late_cancel_makeup_tokens into v_notice, v_makeups
    from club_settings where club_id = v_b.club_id;

  v_late := (v_b.booked_by = auth.uid() or owns_athlete(v_b.athlete_id))
            and not is_admin_of(v_b.club_id)
            and slot_starts_at(v_slot) < now() + make_interval(hours => coalesce(v_notice, 24));

  update bookings
    set status = case when v_late then 'late_cancelled'::booking_status else 'cancelled'::booking_status end,
        cancelled_at = now(), cancelled_by = auth.uid()
    where id = p_booking_id;

  v_had_credit := exists (select 1 from credit_ledger where booking_id = p_booking_id and delta < 0);
  if not v_late then
    if v_had_credit then
      insert into credit_ledger (club_id, profile_id, delta, reason, booking_id, created_by)
      values (v_b.club_id, v_b.booked_by, 1, 'Credit returned — lesson cancelled', p_booking_id, auth.uid());
    end if;
  elsif coalesce(v_makeups, true) then
    insert into credit_ledger (club_id, profile_id, delta, reason, booking_id, created_by)
    values (v_b.club_id, v_b.booked_by, 1, 'Makeup token — late cancellation', p_booking_id, auth.uid());
    perform notify(v_b.booked_by, v_b.club_id, 'credits', 'Makeup token added',
      'Your late cancellation is still payable, but you''ve been given a makeup token to rebook with.',
      jsonb_build_object('booking_id', p_booking_id));
  end if;

  if v_b.coach_id = auth.uid() and v_b.booked_by <> auth.uid() then
    perform notify(v_b.booked_by, v_b.club_id, 'booking_cancelled', 'Lesson cancelled by coach',
      'Your ' || to_char(v_slot.slot_date, 'FMDay DD Mon') || ' ' || to_char(v_slot.start_time, 'HH24:MI')
      || ' lesson was cancelled by the coach.', jsonb_build_object('booking_id', p_booking_id));
  elsif is_admin_of(v_b.club_id) and v_b.booked_by <> auth.uid() then
    perform notify(v_b.booked_by, v_b.club_id, 'booking_cancelled', 'Lesson cancelled by the club',
      'Your ' || to_char(v_slot.slot_date, 'FMDay DD Mon') || ' ' || to_char(v_slot.start_time, 'HH24:MI')
      || ' lesson was cancelled by the club.', jsonb_build_object('booking_id', p_booking_id));
  end if;
  if v_b.coach_id <> auth.uid() then
    perform notify(v_b.coach_id, v_b.club_id, 'booking_cancelled', 'Lesson cancelled',
      (select name from athletes where id = v_b.athlete_id) || '''s '
      || to_char(v_slot.slot_date, 'FMDay DD Mon') || ' ' || to_char(v_slot.start_time, 'HH24:MI')
      || ' lesson was cancelled' || case when v_late then ' (late — still payable)' else '' end || '.',
      jsonb_build_object('booking_id', p_booking_id));
  end if;

  perform promote_waitlist(v_b.slot_id);
  return jsonb_build_object('late', v_late);
end;
$$;

create or replace function public.cancel_booking_series (p_series_booking_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_s booking_series%rowtype;
  v_cancelled int := 0;
  r record;
begin
  select * into v_s from booking_series where id = p_series_booking_id for update;
  if v_s.id is null then raise exception 'Weekly booking not found.'; end if;
  if not (v_s.booked_by = auth.uid() or owns_athlete(v_s.athlete_id) or is_admin_of(v_s.club_id)) then
    raise exception 'You can''t cancel this weekly booking.';
  end if;
  update booking_series set active = false where id = p_series_booking_id;
  for r in select b.id from bookings b join slots s on s.id = b.slot_id
           where b.series_booking_id = p_series_booking_id and b.status = 'booked'
             and slot_starts_at(s) > now() loop
    perform cancel_booking(r.id);
    v_cancelled := v_cancelled + 1;
  end loop;
  return jsonb_build_object('cancelled', v_cancelled);
end;
$$;

create or replace function public.join_waitlist (p_slot_id uuid, p_athlete_id uuid, p_coach_id uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_slot slots%rowtype;
  v_id uuid;
begin
  select * into v_slot from slots where id = p_slot_id;
  if v_slot.id is null then raise exception 'Slot not found.'; end if;
  if not (owns_athlete(p_athlete_id) or is_admin_of(v_slot.club_id)) then
    raise exception 'You can only join the waiting list for your own athletes.';
  end if;
  perform assert_club_active(v_slot.club_id);
  if not athlete_in_club(p_athlete_id, v_slot.club_id) then
    raise exception 'This athlete isn''t enrolled at this club yet.';
  end if;
  if slot_starts_at(v_slot) < now() then raise exception 'That slot is in the past.'; end if;
  if exists (select 1 from bookings where slot_id = p_slot_id and athlete_id = p_athlete_id and status = 'booked') then
    raise exception 'This athlete already has a lesson in this slot.';
  end if;
  if p_coach_id is not null and not exists (select 1 from slot_coaches where slot_id = p_slot_id and coach_id = p_coach_id) then
    raise exception 'That coach is not available in this slot.';
  end if;
  insert into waitlist (club_id, slot_id, athlete_id, requested_coach_id, created_by)
  values (v_slot.club_id, p_slot_id, p_athlete_id, p_coach_id, auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.leave_waitlist (p_waitlist_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_w waitlist%rowtype;
begin
  select * into v_w from waitlist where id = p_waitlist_id for update;
  if v_w.id is null then raise exception 'Waiting list entry not found.'; end if;
  if not (v_w.created_by = auth.uid() or owns_athlete(v_w.athlete_id) or is_admin_of(v_w.club_id)) then
    raise exception 'Not your waiting list entry.';
  end if;
  update waitlist set status = 'cancelled' where id = p_waitlist_id;
  if v_w.status = 'offered' then perform promote_waitlist(v_w.slot_id); end if;
end;
$$;

create or replace function public.accept_waitlist_offer (p_waitlist_id uuid, p_coach_id uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_w waitlist%rowtype;
  v_coach uuid;
  v_booking uuid;
begin
  select * into v_w from waitlist where id = p_waitlist_id for update;
  if v_w.id is null then raise exception 'Waiting list entry not found.'; end if;
  if not (v_w.created_by = auth.uid() or owns_athlete(v_w.athlete_id)) then
    raise exception 'Not your waiting list entry.';
  end if;
  if v_w.status <> 'offered' then raise exception 'This space is not currently offered to you.'; end if;
  if v_w.offer_expires_at < now() then
    update waitlist set status = 'expired' where id = p_waitlist_id;
    perform promote_waitlist(v_w.slot_id);
    raise exception 'This offer has expired.';
  end if;
  perform assert_club_active(v_w.club_id);
  v_coach := coalesce(v_w.requested_coach_id, p_coach_id);
  if v_coach is null then raise exception 'Choose a coach to accept the space.'; end if;
  v_booking := _create_booking(v_w.slot_id, v_w.athlete_id, v_coach, v_w.created_by, null, true);
  update waitlist set status = 'booked' where id = p_waitlist_id;
  perform notify(v_coach, v_w.club_id, 'new_booking', 'New booking (from waiting list)',
    (select name from athletes where id = v_w.athlete_id) || ' accepted a waiting-list space with you.',
    jsonb_build_object('booking_id', v_booking));
  return v_booking;
end;
$$;

-- ---------- register & progression ----------
create or replace function public.take_register (p_booking_id uuid, p_attendance public.attendance_status)
returns void language plpgsql security definer set search_path = public as $$
declare v_b bookings%rowtype;
begin
  select * into v_b from bookings where id = p_booking_id;
  if v_b.id is null then raise exception 'Booking not found.'; end if;
  if not (v_b.coach_id = auth.uid() or is_admin_of(v_b.club_id)) then
    raise exception 'Only the lesson''s coach can take the register.';
  end if;
  if v_b.status <> 'booked' then raise exception 'This booking was cancelled.'; end if;
  update bookings set attendance = p_attendance, attendance_marked_by = auth.uid(), attendance_marked_at = now()
    where id = p_booking_id;
end;
$$;

create or replace function public.update_athlete_skill (
  p_athlete_id uuid, p_skill_id int, p_status public.skill_status, p_notes text default null
) returns void language plpgsql security definer set search_path = public as $$
declare
  v_club uuid;
  v_old public.skill_status;
  v_owner uuid;
  v_athlete text;
  v_skill text;
begin
  select club_id, name into v_club, v_skill from skills where id = p_skill_id;
  if v_club is null then raise exception 'That skill belongs to the platform template.'; end if;
  if not (is_coach_of(v_club)) then raise exception 'Only the club''s coaches can update skills.'; end if;
  if not athlete_in_club(p_athlete_id, v_club) then raise exception 'Athlete is not enrolled at this club.'; end if;

  select status into v_old from athlete_skills where athlete_id = p_athlete_id and skill_id = p_skill_id;
  insert into athlete_skills (athlete_id, skill_id, status, notes, updated_by, updated_at)
  values (p_athlete_id, p_skill_id, p_status, p_notes, auth.uid(), now())
  on conflict (athlete_id, skill_id)
  do update set status = excluded.status, notes = coalesce(excluded.notes, athlete_skills.notes),
                updated_by = excluded.updated_by, updated_at = now();

  if p_status in ('achieved', 'mastered') and (v_old is null or v_old < p_status) then
    select coalesce(a.parent_id, a.profile_id), a.name into v_owner, v_athlete from athletes a where a.id = p_athlete_id;
    if v_owner is not null then
      perform notify(v_owner, v_club, 'skill_milestone',
        case when p_status = 'mastered' then '🏆 Skill mastered!' else '🎉 New skill achieved!' end,
        v_athlete || ' just ' || case when p_status = 'mastered' then 'mastered' else 'achieved' end
        || ' their ' || v_skill || '!',
        jsonb_build_object('athlete_id', p_athlete_id, 'skill_id', p_skill_id, 'status', p_status));
    end if;
  end if;
end;
$$;

create or replace function public.add_progress_note (
  p_club uuid, p_athlete_id uuid, p_note text, p_booking_id uuid default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not is_coach_of(p_club) then raise exception 'Only the club''s coaches can add progress notes.'; end if;
  if not athlete_in_club(p_athlete_id, p_club) then raise exception 'Athlete is not enrolled at this club.'; end if;
  insert into progress_notes (club_id, athlete_id, coach_id, booking_id, note)
  values (p_club, p_athlete_id, auth.uid(), p_booking_id, p_note)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.add_skill_media (
  p_club uuid, p_athlete_id uuid, p_path text, p_skill_id int default null, p_note text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_owner uuid;
  v_athlete text;
begin
  if not (is_coach_of(p_club) or owns_athlete(p_athlete_id)) then
    raise exception 'Only the athlete''s coaches or family can add videos.';
  end if;
  if not athlete_in_club(p_athlete_id, p_club) then raise exception 'Athlete is not enrolled at this club.'; end if;
  if not (select media_consent from athletes where id = p_athlete_id) then
    raise exception 'This athlete doesn''t have media consent enabled — a parent can switch it on under Athletes.';
  end if;
  if position(p_club::text || '/' in p_path) <> 1 then
    raise exception 'Bad media path.';
  end if;
  insert into skill_media (club_id, athlete_id, skill_id, uploaded_by, path, note)
  values (p_club, p_athlete_id, p_skill_id, auth.uid(), p_path, p_note)
  returning id into v_id;
  select coalesce(a.parent_id, a.profile_id), a.name into v_owner, v_athlete from athletes a where a.id = p_athlete_id;
  if v_owner is not null and v_owner <> auth.uid() then
    perform notify(v_owner, p_club, 'skill_media', '🎬 New video added',
      'A new clip of ' || v_athlete || ' was added to their skill journey.',
      jsonb_build_object('athlete_id', p_athlete_id));
  end if;
  return v_id;
end;
$$;

-- ---------- credits & broadcasts ----------
create or replace function public.admin_adjust_credits (p_club uuid, p_profile uuid, p_delta int, p_reason text)
returns int language plpgsql security definer set search_path = public as $$
begin
  if not is_admin_of(p_club) then raise exception 'Only club admins can adjust credits.'; end if;
  if not exists (select 1 from club_members where club_id = p_club and profile_id = p_profile and status = 'active') then
    raise exception 'That person is not an active member of this club.';
  end if;
  insert into credit_ledger (club_id, profile_id, delta, reason, created_by)
  values (p_club, p_profile, p_delta, p_reason, auth.uid());
  perform notify(p_profile, p_club, 'credits', 'Lesson credits updated',
    case when p_delta > 0 then p_delta || ' lesson credit(s) added' else abs(p_delta) || ' lesson credit(s) removed' end
    || ' — ' || p_reason || '.', '{}'::jsonb);
  perform owner_log(p_club, 'adjust_credits', p_profile::text || ' ' || p_delta);
  return (select coalesce(sum(delta), 0) from credit_ledger where club_id = p_club and profile_id = p_profile);
end;
$$;

create or replace function public.admin_broadcast (p_club uuid, p_audience text, p_title text, p_body text)
returns int language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_count int;
begin
  if not is_admin_of(p_club) then raise exception 'Only club admins can send broadcasts.'; end if;
  if p_audience not in ('everyone', 'parents', 'coaches') then raise exception 'Bad audience.'; end if;
  insert into broadcasts (club_id, sender_id, audience, title, body)
  values (p_club, auth.uid(), p_audience, p_title, p_body) returning id into v_id;
  insert into notifications (profile_id, club_id, type, title, body, data)
  select m.profile_id, p_club, 'broadcast', p_title, p_body, jsonb_build_object('broadcast_id', v_id)
  from club_members m
  where m.club_id = p_club and m.status = 'active' and m.profile_id <> auth.uid()
    and case p_audience
      when 'everyone' then true
      when 'parents' then m.role in ('parent', 'athlete')
      when 'coaches' then m.role = 'coach'
    end;
  get diagnostics v_count = row_count;
  update broadcasts set recipient_count = v_count where id = v_id;
  perform owner_log(p_club, 'broadcast', p_title);
  return v_count;
end;
$$;

create or replace function public.broadcast_read_counts (p_club uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not is_admin_of(p_club) then '{}'::jsonb else
    coalesce((select jsonb_object_agg(bid, reads) from (
      select (n.data ->> 'broadcast_id') as bid, count(*) filter (where n.read) as reads
      from notifications n where n.type = 'broadcast' and n.club_id = p_club group by 1
    ) t), '{}'::jsonb) end
$$;

-- ---------- scheduled jobs (loop over active clubs) ----------
create or replace function public.remind_missing_registers () returns int
language plpgsql security definer set search_path = public as $$
declare
  r record;
  v_count int := 0;
begin
  for r in
    select b.id, b.club_id, b.coach_id, a.name as athlete, s.slot_date, s.start_time
    from bookings b
    join clubs c on c.id = b.club_id and c.status = 'active'
    join slots s on s.id = b.slot_id
    join athletes a on a.id = b.athlete_id
    where b.status = 'booked' and b.attendance is null
      and (s.slot_date + s.end_time) at time zone club_tz(b.club_id) < now() - interval '1 hour'
      and not exists (select 1 from notifications n
                      where n.type = 'register_reminder' and (n.data ->> 'booking_id')::uuid = b.id)
  loop
    perform notify(r.coach_id, r.club_id, 'register_reminder', 'Register due',
      'You haven''t taken the register for ' || r.athlete || ' ('
      || to_char(r.slot_date, 'FMDay DD Mon') || ' ' || to_char(r.start_time, 'HH24:MI') || ').',
      jsonb_build_object('booking_id', r.id));
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

create or replace function public.send_rebook_nudges () returns int
language plpgsql security definer set search_path = public as $$
declare
  r record;
  v_count int := 0;
begin
  for r in
    select distinct m.profile_id, m.club_id
    from club_members m
    join clubs c on c.id = m.club_id and c.status = 'active'
    where m.status = 'active' and m.role in ('parent', 'athlete')
      and exists (select 1 from bookings b where b.booked_by = m.profile_id and b.club_id = m.club_id)
      and not exists (select 1 from bookings b join slots s on s.id = b.slot_id
        where b.booked_by = m.profile_id and b.club_id = m.club_id and b.status = 'booked' and s.slot_date >= current_date)
      and (select max(s.slot_date) from bookings b join slots s on s.id = b.slot_id
           where b.booked_by = m.profile_id and b.club_id = m.club_id) < current_date - 14
      and not exists (select 1 from notifications n
        where n.profile_id = m.profile_id and n.club_id = m.club_id and n.type = 'rebook_nudge'
          and n.created_at > now() - interval '14 days')
  loop
    perform notify(r.profile_id, r.club_id, 'rebook_nudge', 'Time for the next lesson?',
      'It''s been a couple of weeks since the last 1-2-1 at ' || (select name from clubs where id = r.club_id)
      || ' — slots fill fast, book the next one from the app.', '{}'::jsonb);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- ---------- owner console ----------
create or replace function public.owner_club_health () returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not is_owner() then '[]'::jsonb else
    coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at desc) from (
      select c.id, c.name, c.slug, c.status, c.plan, c.join_code, c.contact_email, c.created_at,
        (select count(*) from club_members m where m.club_id = c.id and m.status = 'active' and m.role in ('parent', 'athlete')) as families,
        (select count(*) from club_members m where m.club_id = c.id and m.status = 'active' and m.role = 'coach') as coaches,
        (select count(*) from club_members m where m.club_id = c.id and m.status = 'pending') as pending,
        (select round(count(*) / 4.0, 1) from bookings b join slots s on s.id = b.slot_id
          where b.club_id = c.id and b.status = 'booked' and s.slot_date >= current_date - 28 and s.slot_date < current_date + 1) as bookings_per_week,
        (select max(b.created_at) from bookings b where b.club_id = c.id) as last_booking_at
      from clubs c
    ) t), '[]'::jsonb) end
$$;

create or replace function public.owner_set_club_status (p_club uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if not is_owner() then raise exception 'Owner only.'; end if;
  if p_status not in ('active', 'suspended', 'churned') then raise exception 'Bad status.'; end if;
  update clubs set status = p_status where id = p_club;
  insert into owner_audit (club_id, action, detail) values (p_club, 'set_status', p_status);
  if p_status <> 'active' then
    for r in select profile_id from club_members where club_id = p_club and role = 'admin' and status = 'active' loop
      perform notify(r.profile_id, null, 'club_status', 'Club account update',
        (select name from clubs where id = p_club) || ' has been ' ||
        case p_status when 'suspended' then 'suspended — contact Ignyte to reactivate.' else 'closed.' end, '{}'::jsonb);
    end loop;
  end if;
end;
$$;

create or replace function public.owner_set_plan (p_club uuid, p_plan text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_owner() then raise exception 'Owner only.'; end if;
  if p_plan not in ('free', 'club', 'comped') then raise exception 'Bad plan.'; end if;
  update clubs set plan = p_plan where id = p_club;
  insert into owner_audit (club_id, action, detail) values (p_club, 'set_plan', p_plan);
end;
$$;

create or replace function public.owner_grant_support (p_club uuid, p_minutes int default 60)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare v_exp timestamptz := now() + make_interval(mins => least(greatest(p_minutes, 5), 240));
begin
  if not is_owner() then raise exception 'Owner only.'; end if;
  insert into owner_support_grants (club_id, expires_at) values (p_club, v_exp)
  on conflict (club_id) do update set expires_at = v_exp, created_at = now();
  insert into owner_audit (club_id, action, detail) values (p_club, 'support_grant', v_exp::text);
  return v_exp;
end;
$$;

create or replace function public.owner_announce (p_title text, p_body text)
returns int language plpgsql security definer set search_path = public as $$
declare v_count int;
begin
  if not is_owner() then raise exception 'Owner only.'; end if;
  insert into notifications (profile_id, club_id, type, title, body)
  select distinct m.profile_id, null, 'platform', p_title, p_body
  from club_members m join clubs c on c.id = m.club_id
  where m.role = 'admin' and m.status = 'active' and c.status <> 'churned';
  get diagnostics v_count = row_count;
  insert into owner_audit (action, detail) values ('announce', p_title || ' → ' || v_count);
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- Function execution lock-down
-- ---------------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function
  public.get_club_public (text),
  public.get_invite_public (uuid)
to anon, authenticated;

grant execute on function
  public.clubs_search (text),
  public.join_by_code (text),
  public.request_join (text),
  public.approve_member (uuid, uuid, boolean),
  public.remove_member (uuid, uuid),
  public.set_member_role (uuid, uuid, public.club_role),
  public.create_club_invite (uuid, public.club_role, text),
  public.accept_club_invite (uuid),
  public.revoke_club_invite (uuid),
  public.provision_club (text, text, text, text[], text),
  public.update_club_branding (uuid, text, text, text, text, boolean),
  public.rotate_join_code (uuid),
  public.update_club_settings (uuid, text, text[], int, text, int, boolean),
  public.enrol_athlete (uuid, uuid),
  public.unenrol_athlete (uuid, uuid),
  public.admin_create_slots (uuid, date, time, int, int, time, int, uuid, text),
  public.admin_extend_series (uuid, int),
  public.admin_delete_slot (uuid),
  public.coach_join_slot (uuid, boolean),
  public.coach_leave_slot (uuid, boolean),
  public.get_slot_board (uuid, date, date),
  public.book_slot (uuid, uuid, uuid, boolean, text),
  public.cancel_booking (uuid),
  public.cancel_booking_series (uuid),
  public.join_waitlist (uuid, uuid, uuid),
  public.leave_waitlist (uuid),
  public.accept_waitlist_offer (uuid, uuid),
  public.take_register (uuid, public.attendance_status),
  public.update_athlete_skill (uuid, int, public.skill_status, text),
  public.add_progress_note (uuid, uuid, text, uuid),
  public.add_skill_media (uuid, uuid, text, int, text),
  public.admin_adjust_credits (uuid, uuid, int, text),
  public.admin_broadcast (uuid, text, text, text),
  public.broadcast_read_counts (uuid),
  public.owner_club_health (),
  public.owner_set_club_status (uuid, text),
  public.owner_set_plan (uuid, text),
  public.owner_grant_support (uuid, int),
  public.owner_announce (text, text),
  public.is_owner (),
  public.my_club_ids (),
  public.member_role (uuid),
  public.is_admin_of (uuid),
  public.is_coach_of (uuid),
  public.is_owner_with_grant (uuid),
  public.owns_athlete (uuid),
  public.athlete_in_club (uuid, uuid),
  public.staff_of_athlete (uuid)
to authenticated, service_role;

alter default privileges in schema public revoke execute on functions from public;

-- ---------------------------------------------------------------------------
-- pg_cron (guarded for plain Postgres)
-- ---------------------------------------------------------------------------
do $cron$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('ignyte-register-reminders', '30 * * * *', 'select public.remind_missing_registers()');
  perform cron.schedule('ignyte-rebook-nudges', '0 10 * * *', 'select public.send_rebook_nudges()');
exception when others then
  raise notice 'pg_cron unavailable (%).', sqlerrm;
end;
$cron$;

-- ---------------------------------------------------------------------------
-- Seed: the platform skill template (club_id null). Clubs get a copy at
-- provisioning. No club data is seeded here.
-- ---------------------------------------------------------------------------
insert into public.skills (club_id, discipline, category, name, level, sort) values
  (null, 'tumble', 'Foundations', 'Forward roll', 1, 1),
  (null, 'tumble', 'Foundations', 'Backward roll', 1, 2),
  (null, 'tumble', 'Foundations', 'Handstand', 1, 3),
  (null, 'tumble', 'Foundations', 'Bridge', 1, 4),
  (null, 'tumble', 'Foundations', 'Cartwheel', 1, 5),
  (null, 'tumble', 'Foundations', 'Round off', 1, 6),
  (null, 'tumble', 'Walkovers', 'Backbend kick over', 2, 10),
  (null, 'tumble', 'Walkovers', 'Back walkover', 2, 11),
  (null, 'tumble', 'Walkovers', 'Front walkover', 2, 12),
  (null, 'tumble', 'Walkovers', 'Valdez', 2, 13),
  (null, 'tumble', 'Handsprings', 'Standing back handspring', 3, 20),
  (null, 'tumble', 'Handsprings', 'Back handspring step out', 3, 21),
  (null, 'tumble', 'Handsprings', 'Round off back handspring', 3, 22),
  (null, 'tumble', 'Handsprings', 'Round off series back handsprings', 3, 23),
  (null, 'tumble', 'Handsprings', 'Front handspring', 3, 24),
  (null, 'tumble', 'Somersaults', 'Standing back tuck', 4, 30),
  (null, 'tumble', 'Somersaults', 'Round off back tuck', 4, 31),
  (null, 'tumble', 'Somersaults', 'Round off back handspring back tuck', 4, 32),
  (null, 'tumble', 'Somersaults', 'Punch front', 4, 33),
  (null, 'tumble', 'Somersaults', 'Side aerial', 4, 34),
  (null, 'tumble', 'Layouts', 'Round off back handspring layout', 5, 40),
  (null, 'tumble', 'Layouts', 'Whip', 5, 41),
  (null, 'tumble', 'Layouts', 'Standing tuck series', 5, 42),
  (null, 'tumble', 'Twisting', 'Round off back handspring full', 6, 50),
  (null, 'tumble', 'Twisting', 'Standing full', 6, 51),
  (null, 'tumble', 'Twisting', 'Double full', 6, 52),
  (null, 'dance', 'Turns', 'Single pirouette', 1, 1),
  (null, 'dance', 'Turns', 'Double pirouette', 2, 2),
  (null, 'dance', 'Turns', 'Triple pirouette', 3, 3),
  (null, 'dance', 'Turns', 'À la seconde turns', 3, 4),
  (null, 'dance', 'Turns', 'Fouetté turns', 4, 5),
  (null, 'dance', 'Turns', 'Leg hold turn', 3, 6),
  (null, 'dance', 'Turns', 'Illusion', 4, 7),
  (null, 'dance', 'Leaps & Jumps', 'Grand jeté', 1, 10),
  (null, 'dance', 'Leaps & Jumps', 'Toe touch', 1, 11),
  (null, 'dance', 'Leaps & Jumps', 'Switch leap', 2, 12),
  (null, 'dance', 'Leaps & Jumps', 'Firebird', 3, 13),
  (null, 'dance', 'Leaps & Jumps', 'Calypso', 3, 14),
  (null, 'dance', 'Leaps & Jumps', 'Switch second', 4, 15),
  (null, 'dance', 'Leaps & Jumps', 'Turning disc', 4, 16),
  (null, 'dance', 'Kicks', 'Grand battement', 1, 20),
  (null, 'dance', 'Kicks', 'Front kick sequence', 1, 21),
  (null, 'dance', 'Kicks', 'Side kick sequence', 2, 22),
  (null, 'dance', 'Flexibility', 'Right splits', 1, 30),
  (null, 'dance', 'Flexibility', 'Left splits', 1, 31),
  (null, 'dance', 'Flexibility', 'Middle splits', 2, 32),
  (null, 'dance', 'Flexibility', 'Heel stretch', 2, 33),
  (null, 'dance', 'Flexibility', 'Scorpion', 3, 34),
  (null, 'dance', 'Flexibility', 'Needle', 4, 35),
  (null, 'dance', 'Flexibility', 'Bow and arrow', 3, 36);

-- ============================================================
-- SEED — rebuild profiles for existing logins, create clubs
-- ============================================================
-- Profiles for every existing auth user (passwords survive).
insert into public.profiles (id, full_name, email, phone, role)
select u.id,
  coalesce(nullif(u.raw_user_meta_data ->> 'full_name', ''), split_part(u.email, '@', 1)),
  u.email, nullif(u.raw_user_meta_data ->> 'phone', ''), 'parent'
from auth.users u
on conflict (id) do nothing;

update public.profiles set role = 'owner' where email = 'smithy.ns83@gmail.com';

do $seed$
declare
  v_ignyte uuid;
  v_storm uuid;
  v_owner uuid := (select id from profiles where email = 'smithy.ns83@gmail.com');
  v_nathan uuid := (select id from profiles where email = 'nathansmith00@hotmail.co.uk');
  v_sarah uuid := (select id from profiles where email = 'sarah.parent@test.ignyte');
  v_emma uuid := (select id from profiles where email = 'emma.parent@test.ignyte');
  v_chloe uuid := (select id from profiles where email = 'chloe.athlete@test.ignyte');
  v_jake uuid := (select id from profiles where email = 'jake.coach@test.ignyte');
  v_lily uuid; v_max uuid; v_ava uuid;
  v_main uuid; v_studio uuid; v_unit5 uuid;
  v_next_sat date := current_date + (((6 - extract(dow from current_date))::int + 7) % 7);
  v_t time; v_sid uuid; v_slot uuid; w int;
begin
  if v_next_sat <= current_date then v_next_sat := v_next_sat + 7; end if;

  -- ---- Ignyte Cheer & Dance (your club, paid plan) ----
  insert into clubs (name, slug, status, plan, blurb, contact_name, contact_email)
  values ('Ignyte Cheer & Dance', 'ignyte', 'active', 'club',
          'Cheer tumble & all-star dance privates in Bristol.', 'Nathan Smith', 'smithy.ns83@gmail.com')
  returning id into v_ignyte;
  insert into club_settings (club_id) values (v_ignyte);
  insert into skills (club_id, discipline, category, name, level, sort)
    select v_ignyte, discipline, category, name, level, sort from skills where club_id is null;
  insert into locations (club_id, name) values (v_ignyte, 'Main Gym') returning id into v_main;
  insert into locations (club_id, name) values (v_ignyte, 'Dance Studio') returning id into v_studio;

  -- memberships (owner runs it as admin too so the club has a human admin)
  insert into club_members (club_id, profile_id, role) values
    (v_ignyte, v_owner, 'admin'),
    (v_ignyte, v_nathan, 'coach');
  if v_sarah is not null then insert into club_members (club_id, profile_id, role) values (v_ignyte, v_sarah, 'parent'); end if;
  if v_emma is not null then insert into club_members (club_id, profile_id, role) values (v_ignyte, v_emma, 'parent'); end if;
  if v_jake is not null then insert into club_members (club_id, profile_id, role) values (v_ignyte, v_jake, 'coach'); end if;
  if v_chloe is not null then insert into club_members (club_id, profile_id, role) values (v_ignyte, v_chloe, 'athlete'); end if;

  update coach_profiles set disciplines = array['tumble'], levels = 'Tumble L1-6', rate_per_lesson = 22
    where club_id = v_ignyte and coach_id = v_nathan;
  if v_jake is not null then
    update coach_profiles set disciplines = array['tumble','dance'], levels = 'Tumble L1-4 · Dance', rate_per_lesson = 20
      where club_id = v_ignyte and coach_id = v_jake;
  end if;

  -- athletes (shared records) + enrolments at Ignyte
  if v_sarah is not null then
    insert into athletes (parent_id, name, dob, notes) values (v_sarah, 'Lily Johnson', '2017-06-20', 'Working towards back handspring') returning id into v_lily;
    insert into athletes (parent_id, name, dob) values (v_sarah, 'Max Johnson', '2014-02-11') returning id into v_max;
    insert into athlete_enrolments (athlete_id, club_id) values (v_lily, v_ignyte), (v_max, v_ignyte);
  end if;
  if v_emma is not null then
    insert into athletes (parent_id, name, dob, notes) values (v_emma, 'Ava Williams', '2012-09-03', 'All-star dance focus') returning id into v_ava;
    insert into athlete_enrolments (athlete_id, club_id) values (v_ava, v_ignyte);
  end if;
  if v_chloe is not null then
    insert into athlete_enrolments (athlete_id, club_id)
      select a.id, v_ignyte from athletes a where a.profile_id = v_chloe;
  end if;

  -- Saturday slots at Main Gym, 09:00-11:00 x30min, cap 2, 4 weeks
  v_t := '09:00';
  while v_t < '11:00'::time loop
    v_sid := gen_random_uuid();
    for w in 0..3 loop
      insert into slots (club_id, slot_date, start_time, end_time, capacity, series_id, location_id)
      values (v_ignyte, v_next_sat + w * 7, v_t, v_t + interval '30 minutes', 2, v_sid, v_main)
      returning id into v_slot;
      insert into slot_coaches (slot_id, coach_id)
        select v_slot, cid from unnest(array[v_nathan, v_jake]) as cid where cid is not null;
    end loop;
    v_t := v_t + interval '30 minutes';
  end loop;

  -- Lily's progression at Ignyte
  if v_lily is not null and v_jake is not null then
    insert into athlete_skills (athlete_id, skill_id, status, updated_by)
      select v_lily, id, 'mastered', v_jake from skills where club_id = v_ignyte and name in ('Forward roll','Backward roll','Cartwheel');
    insert into athlete_skills (athlete_id, skill_id, status, updated_by)
      select v_lily, id, 'achieved', v_jake from skills where club_id = v_ignyte and name in ('Round off','Handstand','Bridge');
    insert into progress_notes (club_id, athlete_id, coach_id, note)
      values (v_ignyte, v_lily, v_jake, 'Cartwheels solid both sides — started back handspring drills on the barrel.');
  end if;

  -- ---- Storm Allstars (demo second club, free plan) ----
  insert into clubs (name, slug, status, plan, blurb)
  values ('Storm Allstars', 'storm', 'active', 'free', 'Demo club — proves the walls between clubs hold.')
  returning id into v_storm;
  insert into club_settings (club_id) values (v_storm);
  insert into skills (club_id, discipline, category, name, level, sort)
    select v_storm, discipline, category, name, level, sort from skills where club_id is null;
  insert into locations (club_id, name) values (v_storm, 'Unit 5') returning id into v_unit5;
  if v_jake is not null then
    insert into club_members (club_id, profile_id, role) values (v_storm, v_jake, 'coach');
    update coach_profiles set disciplines = array['dance'], rate_per_lesson = 25 where club_id = v_storm and coach_id = v_jake;
  end if;
  if v_emma is not null then
    insert into club_members (club_id, profile_id, role) values (v_storm, v_emma, 'parent');
    if v_ava is not null then insert into athlete_enrolments (athlete_id, club_id) values (v_ava, v_storm); end if;
  end if;
  -- Wednesday slots at Storm
  v_sid := gen_random_uuid();
  for w in 0..3 loop
    insert into slots (club_id, slot_date, start_time, end_time, capacity, series_id, location_id)
    values (v_storm, current_date + (((3 - extract(dow from current_date))::int + 7) % 7) + 7 * w + case when (((3 - extract(dow from current_date))::int + 7) % 7) = 0 then 7 else 0 end,
            '17:00', '18:00', 1, v_sid, v_unit5)
    returning id into v_slot;
    if v_jake is not null then insert into slot_coaches (slot_id, coach_id) values (v_slot, v_jake); end if;
  end loop;

  raise notice 'Seed complete: Ignyte=% Storm=%', v_ignyte, v_storm;
end;
$seed$;

select c.name, c.slug, c.join_code, c.plan, c.status,
  (select count(*) from public.club_members m where m.club_id = c.id) as members
from public.clubs c;
