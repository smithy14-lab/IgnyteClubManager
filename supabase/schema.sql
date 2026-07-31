-- ============================================================================
-- IGNYTE CLUB MANAGER — Supabase schema
-- ----------------------------------------------------------------------------
-- Run this whole file once in the Supabase SQL editor (Dashboard -> SQL).
-- It creates every table, row-level-security policy, booking function and the
-- starter skill library for tumble + all-star dance.
--
-- Booking rules encoded here:
--   * A slot is a 30-minute window on a date with N gym spaces (capacity).
--   * Coaches attach themselves to slots they can work.
--   * A booking = one athlete + one coach in one slot (strict 1-2-1: a coach
--     can only take one athlete per slot; an athlete books once per slot).
--   * Weekly bookings repeat over a slot series until cancelled.
--   * Anyone can cancel at any time; inside the club's notice window the
--     booking is marked "late cancelled" (still payable) — either way the
--     freed space is offered to the waiting list.
-- ============================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
create type public.user_role as enum ('parent', 'athlete', 'coach', 'admin');
create type public.booking_status as enum ('booked', 'cancelled', 'late_cancelled');
create type public.attendance_status as enum ('present', 'absent');
create type public.waitlist_status as enum ('waiting', 'offered', 'booked', 'expired', 'cancelled');
create type public.skill_status as enum ('not_started', 'working_on', 'achieved', 'mastered');
create type public.discipline as enum ('tumble', 'dance');

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

-- One row per login. Role 'admin' is only ever granted manually / by admins.
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null,
  email text not null,
  phone text,
  role public.user_role not null default 'parent',
  created_at timestamptz not null default now()
);

-- Athletes. Under-18s have no login: parent_id points at the parent account.
-- 18+ athletes own their record through profile_id.
create table public.athletes (
  id uuid primary key default gen_random_uuid (),
  parent_id uuid references public.profiles (id) on delete cascade,
  profile_id uuid unique references public.profiles (id) on delete cascade,
  name text not null,
  dob date not null,
  notes text,
  created_at timestamptz not null default now(),
  constraint athlete_has_owner check (parent_id is not null or profile_id is not null)
);

-- Single-row club configuration.
create table public.club_settings (
  id int primary key default 1 check (id = 1),
  club_name text not null default 'Ignyte Club',
  timezone text not null default 'Europe/London',
  cancellation_notice_hours int not null default 24,
  cancellation_policy text not null
    default 'You can cancel at any time. Cancellations with less than 24 hours'' notice are still payable; the space is then offered to the waiting list.',
  waitlist_offer_hours int not null default 24
);

-- A bookable 30-minute window. capacity = simultaneous 1-2-1 spaces in the
-- gym. Weekly slots share a series_id (one row per concrete date).
create table public.slots (
  id uuid primary key default gen_random_uuid (),
  slot_date date not null,
  start_time time not null,
  end_time time not null,
  capacity int not null check (capacity > 0),
  series_id uuid,
  notes text,
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  constraint slot_times check (end_time > start_time)
);
create index slots_date_idx on public.slots (slot_date, start_time);
create index slots_series_idx on public.slots (series_id) where series_id is not null;

-- Which coaches have put themselves forward for a slot.
create table public.slot_coaches (
  slot_id uuid not null references public.slots (id) on delete cascade,
  coach_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (slot_id, coach_id)
);

-- A weekly (until-cancelled) booking across a slot series.
create table public.booking_series (
  id uuid primary key default gen_random_uuid (),
  series_id uuid not null,
  athlete_id uuid not null references public.athletes (id) on delete cascade,
  coach_id uuid not null references public.profiles (id),
  booked_by uuid not null references public.profiles (id),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.bookings (
  id uuid primary key default gen_random_uuid (),
  slot_id uuid not null references public.slots (id) on delete cascade,
  athlete_id uuid not null references public.athletes (id) on delete cascade,
  coach_id uuid not null references public.profiles (id),
  booked_by uuid not null references public.profiles (id),
  series_booking_id uuid references public.booking_series (id) on delete set null,
  status public.booking_status not null default 'booked',
  attendance public.attendance_status,
  attendance_marked_by uuid references public.profiles (id),
  attendance_marked_at timestamptz,
  cancelled_at timestamptz,
  cancelled_by uuid references public.profiles (id),
  created_at timestamptz not null default now()
);
-- Strict 1-2-1: one athlete per coach per slot; an athlete books a slot once.
create unique index bookings_coach_slot_uniq on public.bookings (slot_id, coach_id) where (status = 'booked');
create unique index bookings_athlete_slot_uniq on public.bookings (slot_id, athlete_id) where (status = 'booked');
create index bookings_athlete_idx on public.bookings (athlete_id);
create index bookings_coach_idx on public.bookings (coach_id);

create table public.waitlist (
  id uuid primary key default gen_random_uuid (),
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

create table public.notifications (
  id uuid primary key default gen_random_uuid (),
  profile_id uuid not null references public.profiles (id) on delete cascade,
  type text not null,
  title text not null,
  body text not null,
  data jsonb not null default '{}'::jsonb,
  read boolean not null default false,
  created_at timestamptz not null default now()
);
create index notifications_profile_idx on public.notifications (profile_id, read, created_at desc);

-- The skill library (seeded below; admins can add more).
create table public.skills (
  id serial primary key,
  discipline public.discipline not null,
  category text not null,
  name text not null,
  level int not null default 1,
  sort int not null default 0
);

-- One status row per athlete per skill, kept up to date by coaches.
create table public.athlete_skills (
  athlete_id uuid not null references public.athletes (id) on delete cascade,
  skill_id int not null references public.skills (id) on delete cascade,
  status public.skill_status not null default 'working_on',
  notes text,
  updated_by uuid references public.profiles (id),
  updated_at timestamptz not null default now(),
  primary key (athlete_id, skill_id)
);

-- Dated coach notes from lessons.
create table public.progress_notes (
  id uuid primary key default gen_random_uuid (),
  athlete_id uuid not null references public.athletes (id) on delete cascade,
  coach_id uuid not null references public.profiles (id),
  booking_id uuid references public.bookings (id) on delete set null,
  note text not null,
  created_at timestamptz not null default now()
);
create index progress_notes_athlete_idx on public.progress_notes (athlete_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Helper functions (security definer so RLS policies never recurse)
-- ---------------------------------------------------------------------------
create or replace function public.my_role () returns public.user_role
language sql stable security definer set search_path = public as $$
  select role from profiles where id = auth.uid()
$$;

create or replace function public.is_admin () returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role from profiles where id = auth.uid()) = 'admin', false)
$$;

create or replace function public.is_coach () returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role from profiles where id = auth.uid()) in ('coach', 'admin'), false)
$$;

create or replace function public.owns_athlete (aid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from athletes a
    where a.id = aid and (a.parent_id = auth.uid() or a.profile_id = auth.uid())
  )
$$;

create or replace function public.coach_teaches_athlete (aid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from bookings b
    where b.athlete_id = aid and b.coach_id = auth.uid()
  )
$$;

-- Local start of a slot as an absolute point in time.
create or replace function public.slot_starts_at (p_slot public.slots) returns timestamptz
language sql stable security definer set search_path = public as $$
  select (p_slot.slot_date + p_slot.start_time)
           at time zone (select timezone from club_settings where id = 1)
$$;

create or replace function public.notify (
  p_profile uuid, p_type text, p_title text, p_body text, p_data jsonb default '{}'::jsonb
) returns void
language sql security definer set search_path = public as $$
  insert into notifications (profile_id, type, title, body, data)
  values (p_profile, p_type, p_title, p_body, p_data)
$$;

-- ---------------------------------------------------------------------------
-- New-user handling: build the profile (and, for 18+ athletes, their athlete
-- record) from the signup metadata. Under-18 athlete signups are rejected —
-- they are managed under a parent account instead.
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user () returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_role user_role;
  v_dob date;
begin
  v_role := coalesce(nullif(new.raw_user_meta_data ->> 'role', ''), 'parent')::user_role;
  if v_role = 'admin' then
    v_role := 'parent'; -- admin is never self-service
  end if;

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
  return new;
end;
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user ();

-- Nobody changes their own role; admins can change anyone's (not to demote the
-- last admin by accident is left to good sense).
create or replace function public.guard_role_change () returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- auth.uid() is null in the SQL editor / service-role context (needed to
  -- bootstrap the first admin); API users always have a uid and RLS already
  -- limits which rows they can touch.
  if new.role is distinct from old.role and auth.uid() is not null and not is_admin() then
    raise exception 'Only club admins can change account roles.';
  end if;
  return new;
end;
$$;

create trigger profiles_role_guard
before update on public.profiles
for each row execute function public.guard_role_change ();

-- ---------------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.athletes enable row level security;
alter table public.club_settings enable row level security;
alter table public.slots enable row level security;
alter table public.slot_coaches enable row level security;
alter table public.booking_series enable row level security;
alter table public.bookings enable row level security;
alter table public.waitlist enable row level security;
alter table public.notifications enable row level security;
alter table public.skills enable row level security;
alter table public.athlete_skills enable row level security;
alter table public.progress_notes enable row level security;

-- profiles: you, every coach (needed to pick a coach when booking), admins all.
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or role = 'coach' or is_admin());
create policy profiles_update_self on public.profiles for update to authenticated
  using (id = auth.uid() or is_admin()) with check (id = auth.uid() or is_admin());

-- athletes: owners manage their own; coaches can see athletes they teach.
create policy athletes_select on public.athletes for select to authenticated
  using (parent_id = auth.uid() or profile_id = auth.uid() or is_admin()
         or (is_coach() and coach_teaches_athlete(id)));
create policy athletes_insert on public.athletes for insert to authenticated
  with check ((parent_id = auth.uid() and my_role() = 'parent') or is_admin());
create policy athletes_update on public.athletes for update to authenticated
  using (parent_id = auth.uid() or profile_id = auth.uid() or is_admin());
create policy athletes_delete on public.athletes for delete to authenticated
  using (parent_id = auth.uid() or is_admin());

-- club settings: everyone reads, admins write.
create policy settings_select on public.club_settings for select to authenticated using (true);
create policy settings_update on public.club_settings for update to authenticated
  using (is_admin()) with check (is_admin());

-- slots + coach attachments are public to logged-in users (that's the point).
create policy slots_select on public.slots for select to authenticated using (true);
create policy slots_admin_write on public.slots for all to authenticated
  using (is_admin()) with check (is_admin());
create policy slot_coaches_select on public.slot_coaches for select to authenticated using (true);

-- booking_series / bookings / waitlist: reads for the people involved.
-- All writes flow through the security-definer functions below.
create policy series_select on public.booking_series for select to authenticated
  using (booked_by = auth.uid() or coach_id = auth.uid() or owns_athlete(athlete_id) or is_admin());
create policy bookings_select on public.bookings for select to authenticated
  using (booked_by = auth.uid() or coach_id = auth.uid() or owns_athlete(athlete_id) or is_admin());
create policy waitlist_select on public.waitlist for select to authenticated
  using (created_by = auth.uid() or owns_athlete(athlete_id) or is_admin());

-- notifications: strictly your own; you can mark them read.
create policy notifications_select on public.notifications for select to authenticated
  using (profile_id = auth.uid());
create policy notifications_update on public.notifications for update to authenticated
  using (profile_id = auth.uid()) with check (profile_id = auth.uid());

-- skill library: read all; admins curate.
create policy skills_select on public.skills for select to authenticated using (true);
create policy skills_admin_write on public.skills for all to authenticated
  using (is_admin()) with check (is_admin());

-- progression: owners (parents see their under-18s) read; coaches of the
-- athlete read + write; admins everything.
create policy athlete_skills_select on public.athlete_skills for select to authenticated
  using (owns_athlete(athlete_id) or is_admin() or (is_coach() and coach_teaches_athlete(athlete_id)));
create policy progress_notes_select on public.progress_notes for select to authenticated
  using (owns_athlete(athlete_id) or is_admin() or (is_coach() and coach_teaches_athlete(athlete_id)));

-- ---------------------------------------------------------------------------
-- Booking machinery (SECURITY DEFINER — these bypass RLS and enforce every
-- rule themselves, with row locks so simultaneous bookings can't oversell).
-- ---------------------------------------------------------------------------

-- Admin: create a slot, optionally repeated weekly for N weeks (a "series").
create or replace function public.admin_create_slots (
  p_date date, p_start time, p_end time, p_capacity int,
  p_weeks int default 1, p_notes text default null
) returns uuid  -- series_id (or the single slot's id)
language plpgsql security definer set search_path = public as $$
declare
  v_series uuid;
  v_id uuid;
  i int;
begin
  if not is_admin() then raise exception 'Only club admins can create slots.'; end if;
  if p_weeks < 1 or p_weeks > 52 then raise exception 'Weeks must be between 1 and 52.'; end if;

  if p_weeks > 1 then
    v_series := gen_random_uuid();
    for i in 0 .. p_weeks - 1 loop
      insert into slots (slot_date, start_time, end_time, capacity, series_id, notes, created_by)
      values (p_date + (i * 7), p_start, p_end, p_capacity, v_series, p_notes, auth.uid());
    end loop;
    return v_series;
  else
    insert into slots (slot_date, start_time, end_time, capacity, notes, created_by)
    values (p_date, p_start, p_end, p_capacity, p_notes, auth.uid())
    returning id into v_id;
    return v_id;
  end if;
end;
$$;

-- Admin: extend a weekly series by N more weeks. Coach availability rolls
-- forward from the series' last slot, and active weekly bookings are carried
-- into the new weeks automatically.
create or replace function public.admin_extend_series (p_series_id uuid, p_weeks int)
returns int language plpgsql security definer set search_path = public as $$
declare
  v_last slots%rowtype;
  v_new_id uuid;
  v_created int := 0;
  i int;
  r record;
begin
  if not is_admin() then raise exception 'Only club admins can extend a series.'; end if;
  select * into v_last from slots where series_id = p_series_id order by slot_date desc limit 1;
  if v_last.id is null then raise exception 'Series not found.'; end if;

  for i in 1 .. p_weeks loop
    insert into slots (slot_date, start_time, end_time, capacity, series_id, notes, created_by)
    values (v_last.slot_date + (i * 7), v_last.start_time, v_last.end_time, v_last.capacity, p_series_id, v_last.notes, auth.uid())
    returning id into v_new_id;
    v_created := v_created + 1;

    insert into slot_coaches (slot_id, coach_id)
      select v_new_id, sc.coach_id from slot_coaches sc where sc.slot_id = v_last.id;

    for r in select * from booking_series bs where bs.series_id = p_series_id and bs.active loop
      begin
        perform _create_booking(v_new_id, r.athlete_id, r.coach_id, r.booked_by, r.id);
      exception when others then null; -- coach/space clash: that week is skipped
      end;
    end loop;
  end loop;
  return v_created;
end;
$$;

-- Admin: cancel/remove a slot; every booking is cancelled (no fault of the
-- parent, so never "late"), everyone is told, then the slot is deleted.
create or replace function public.admin_delete_slot (p_slot_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_slot slots%rowtype;
  r record;
begin
  if not is_admin() then raise exception 'Only club admins can remove slots.'; end if;
  select * into v_slot from slots where id = p_slot_id for update;
  if v_slot.id is null then raise exception 'Slot not found.'; end if;

  for r in select * from bookings where slot_id = p_slot_id and status = 'booked' loop
    update bookings set status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid()
      where id = r.id;
    perform notify(r.booked_by, 'booking_cancelled', 'Lesson cancelled by the club',
      'Your ' || to_char(v_slot.slot_date, 'FMDay DD Mon') || ' ' || to_char(v_slot.start_time, 'HH24:MI')
      || ' lesson was cancelled by the club.', jsonb_build_object('slot_id', p_slot_id));
  end loop;
  for r in select distinct created_by from waitlist where slot_id = p_slot_id and status in ('waiting', 'offered') loop
    perform notify(r.created_by, 'slot_removed', 'Slot removed',
      'A slot you were waiting on (' || to_char(v_slot.slot_date, 'FMDay DD Mon') || ' '
      || to_char(v_slot.start_time, 'HH24:MI') || ') was removed by the club.', jsonb_build_object('slot_id', p_slot_id));
  end loop;
  delete from slots where id = p_slot_id;
end;
$$;

-- Coach: put yourself forward for a slot (optionally the whole weekly series).
create or replace function public.coach_join_slot (p_slot_id uuid, p_whole_series boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_slot slots%rowtype;
begin
  if not is_coach() then raise exception 'Only coaches can join slots.'; end if;
  select * into v_slot from slots where id = p_slot_id;
  if v_slot.id is null then raise exception 'Slot not found.'; end if;

  if p_whole_series and v_slot.series_id is not null then
    insert into slot_coaches (slot_id, coach_id)
      select s.id, auth.uid() from slots s
      where s.series_id = v_slot.series_id and s.slot_date >= v_slot.slot_date
    on conflict do nothing;
  else
    insert into slot_coaches (slot_id, coach_id) values (p_slot_id, auth.uid())
    on conflict do nothing;
  end if;
end;
$$;

-- Coach: withdraw from a slot — blocked while you still have a booking in it.
create or replace function public.coach_leave_slot (p_slot_id uuid, p_whole_series boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_slot slots%rowtype;
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

-- Internal: the one true way a booking row is created. Locks the slot so two
-- parents tapping "book" at the same second can't overfill it.
create or replace function public._create_booking (
  p_slot_id uuid, p_athlete_id uuid, p_coach_id uuid, p_booked_by uuid, p_series_booking_id uuid default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_slot slots%rowtype;
  v_id uuid;
begin
  select * into v_slot from slots where id = p_slot_id for update;
  if v_slot.id is null then raise exception 'Slot not found.'; end if;
  if slot_starts_at(v_slot) < now() then raise exception 'That slot is in the past.'; end if;
  if not exists (select 1 from slot_coaches where slot_id = p_slot_id and coach_id = p_coach_id) then
    raise exception 'That coach is not available in this slot.';
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

  insert into bookings (slot_id, athlete_id, coach_id, booked_by, series_booking_id)
  values (p_slot_id, p_athlete_id, p_coach_id, p_booked_by, p_series_booking_id)
  returning id into v_id;
  return v_id;
end;
$$;

-- Parent/adult athlete: book a slot (one-off, or weekly across the series).
create or replace function public.book_slot (
  p_slot_id uuid, p_athlete_id uuid, p_coach_id uuid, p_weekly boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_slot slots%rowtype;
  v_series_booking uuid;
  v_booked int := 0;
  v_skipped int := 0;
  r record;
begin
  if not (owns_athlete(p_athlete_id) or is_admin()) then
    raise exception 'You can only book for your own athletes.';
  end if;

  select * into v_slot from slots where id = p_slot_id;
  if v_slot.id is null then raise exception 'Slot not found.'; end if;

  if p_weekly then
    if v_slot.series_id is null then
      raise exception 'This slot is a one-off and can''t be booked weekly.';
    end if;
    insert into booking_series (series_id, athlete_id, coach_id, booked_by)
    values (v_slot.series_id, p_athlete_id, p_coach_id, auth.uid())
    returning id into v_series_booking;

    for r in select * from slots s where s.series_id = v_slot.series_id
             and s.slot_date >= v_slot.slot_date order by s.slot_date loop
      begin
        perform _create_booking(r.id, p_athlete_id, p_coach_id, auth.uid(), v_series_booking);
        v_booked := v_booked + 1;
      exception when others then
        v_skipped := v_skipped + 1;
      end;
    end loop;
    if v_booked = 0 then
      raise exception 'No weeks in this series could be booked with that coach.';
    end if;
    perform notify(auth.uid(), 'booking_confirmed', 'Weekly lesson booked',
      v_booked || ' weekly lessons booked from ' || to_char(v_slot.slot_date, 'FMDay DD Mon')
      || ' at ' || to_char(v_slot.start_time, 'HH24:MI') || '.',
      jsonb_build_object('series_booking_id', v_series_booking));
    return jsonb_build_object('series_booking_id', v_series_booking, 'booked', v_booked, 'skipped', v_skipped);
  else
    perform _create_booking(p_slot_id, p_athlete_id, p_coach_id, auth.uid());
    perform notify(auth.uid(), 'booking_confirmed', 'Lesson booked',
      'Lesson booked for ' || to_char(v_slot.slot_date, 'FMDay DD Mon') || ' at '
      || to_char(v_slot.start_time, 'HH24:MI') || '.', jsonb_build_object('slot_id', p_slot_id));
    return jsonb_build_object('booked', 1, 'skipped', 0);
  end if;
end;
$$;

-- When a space frees up, offer it to the waiting list (oldest first). Expired
-- offers are rolled over to the next person automatically.
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

  -- Roll expired offers over.
  update waitlist set status = 'expired'
    where slot_id = p_slot_id and status = 'offered' and offer_expires_at < now();

  select waitlist_offer_hours into v_offer_hours from club_settings where id = 1;

  loop
    v_free := v_slot.capacity
      - (select count(*) from bookings where slot_id = p_slot_id and status = 'booked')
      - (select count(*) from waitlist where slot_id = p_slot_id and status = 'offered');
    exit when v_free <= 0;

    select * into r from waitlist w
      where w.slot_id = p_slot_id and w.status = 'waiting'
        and (
          w.requested_coach_id is null
          or (exists (select 1 from slot_coaches sc where sc.slot_id = p_slot_id and sc.coach_id = w.requested_coach_id)
              and not exists (select 1 from bookings b where b.slot_id = p_slot_id and b.coach_id = w.requested_coach_id and b.status = 'booked'))
        )
      order by w.created_at limit 1;
    exit when r.id is null;

    -- "Any coach" entries still need at least one free coach in the slot.
    if r.requested_coach_id is null then
      select exists (
        select 1 from slot_coaches sc where sc.slot_id = p_slot_id
        and not exists (select 1 from bookings b where b.slot_id = p_slot_id and b.coach_id = sc.coach_id and b.status = 'booked')
      ) into v_has_free_coach;
      exit when not v_has_free_coach;
    end if;

    update waitlist set status = 'offered', offered_at = now(),
      offer_expires_at = now() + make_interval(hours => v_offer_hours)
      where id = r.id;
    perform notify(r.created_by, 'waitlist_offer', 'A space has opened up!',
      'A space is free on ' || to_char(v_slot.slot_date, 'FMDay DD Mon') || ' at '
      || to_char(v_slot.start_time, 'HH24:MI') || '. Accept it from your bookings page within '
      || v_offer_hours || ' hours.', jsonb_build_object('waitlist_id', r.id, 'slot_id', p_slot_id));
  end loop;
end;
$$;

-- Cancel one booking. Anyone involved can cancel any time; inside the notice
-- window it's recorded as a late cancellation (still payable). The space then
-- goes to the waiting list.
create or replace function public.cancel_booking (p_booking_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_b bookings%rowtype;
  v_slot slots%rowtype;
  v_notice int;
  v_late boolean;
begin
  select * into v_b from bookings where id = p_booking_id for update;
  if v_b.id is null then raise exception 'Booking not found.'; end if;
  if v_b.status <> 'booked' then raise exception 'This booking is already cancelled.'; end if;
  if not (v_b.booked_by = auth.uid() or v_b.coach_id = auth.uid() or owns_athlete(v_b.athlete_id) or is_admin()) then
    raise exception 'You can''t cancel this booking.';
  end if;

  select * into v_slot from slots where id = v_b.slot_id;
  select cancellation_notice_hours into v_notice from club_settings where id = 1;

  -- Late only applies to the family cancelling their own lesson.
  v_late := (v_b.booked_by = auth.uid() or owns_athlete(v_b.athlete_id))
            and not is_admin()
            and slot_starts_at(v_slot) < now() + make_interval(hours => v_notice);

  update bookings
    set status = case when v_late then 'late_cancelled'::booking_status else 'cancelled'::booking_status end,
        cancelled_at = now(), cancelled_by = auth.uid()
    where id = p_booking_id;

  if v_b.coach_id = auth.uid() and v_b.booked_by <> auth.uid() then
    perform notify(v_b.booked_by, 'booking_cancelled', 'Lesson cancelled by coach',
      'Your ' || to_char(v_slot.slot_date, 'FMDay DD Mon') || ' ' || to_char(v_slot.start_time, 'HH24:MI')
      || ' lesson was cancelled by the coach.', jsonb_build_object('booking_id', p_booking_id));
  elsif is_admin() and v_b.booked_by <> auth.uid() then
    perform notify(v_b.booked_by, 'booking_cancelled', 'Lesson cancelled by the club',
      'Your ' || to_char(v_slot.slot_date, 'FMDay DD Mon') || ' ' || to_char(v_slot.start_time, 'HH24:MI')
      || ' lesson was cancelled by the club.', jsonb_build_object('booking_id', p_booking_id));
  end if;

  perform promote_waitlist(v_b.slot_id);
  return jsonb_build_object('late', v_late);
end;
$$;

-- Cancel a weekly series: stops the series and cancels every future booking
-- in it (the imminent one may count as late, same rule as above).
create or replace function public.cancel_booking_series (p_series_booking_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_s booking_series%rowtype;
  v_cancelled int := 0;
  r record;
begin
  select * into v_s from booking_series where id = p_series_booking_id for update;
  if v_s.id is null then raise exception 'Weekly booking not found.'; end if;
  if not (v_s.booked_by = auth.uid() or owns_athlete(v_s.athlete_id) or is_admin()) then
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

-- Join / leave the waiting list.
create or replace function public.join_waitlist (p_slot_id uuid, p_athlete_id uuid, p_coach_id uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_slot slots%rowtype;
  v_id uuid;
begin
  if not (owns_athlete(p_athlete_id) or is_admin()) then
    raise exception 'You can only join the waiting list for your own athletes.';
  end if;
  select * into v_slot from slots where id = p_slot_id;
  if v_slot.id is null then raise exception 'Slot not found.'; end if;
  if slot_starts_at(v_slot) < now() then raise exception 'That slot is in the past.'; end if;
  if exists (select 1 from bookings where slot_id = p_slot_id and athlete_id = p_athlete_id and status = 'booked') then
    raise exception 'This athlete already has a lesson in this slot.';
  end if;
  if p_coach_id is not null and not exists (select 1 from slot_coaches where slot_id = p_slot_id and coach_id = p_coach_id) then
    raise exception 'That coach is not available in this slot.';
  end if;

  insert into waitlist (slot_id, athlete_id, requested_coach_id, created_by)
  values (p_slot_id, p_athlete_id, p_coach_id, auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.leave_waitlist (p_waitlist_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_w waitlist%rowtype;
begin
  select * into v_w from waitlist where id = p_waitlist_id for update;
  if v_w.id is null then raise exception 'Waiting list entry not found.'; end if;
  if not (v_w.created_by = auth.uid() or owns_athlete(v_w.athlete_id) or is_admin()) then
    raise exception 'Not your waiting list entry.';
  end if;
  update waitlist set status = 'cancelled' where id = p_waitlist_id;
  if v_w.status = 'offered' then
    perform promote_waitlist(v_w.slot_id);
  end if;
end;
$$;

-- Accept an offered space. If the entry was "any coach", pass the coach now.
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

  v_coach := coalesce(v_w.requested_coach_id, p_coach_id);
  if v_coach is null then raise exception 'Choose a coach to accept the space.'; end if;

  v_booking := _create_booking(v_w.slot_id, v_w.athlete_id, v_coach, v_w.created_by);
  update waitlist set status = 'booked' where id = p_waitlist_id;
  return v_booking;
end;
$$;

-- Coach: register + progression updates.
create or replace function public.take_register (p_booking_id uuid, p_attendance public.attendance_status)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_b bookings%rowtype;
begin
  select * into v_b from bookings where id = p_booking_id;
  if v_b.id is null then raise exception 'Booking not found.'; end if;
  if not (v_b.coach_id = auth.uid() or is_admin()) then
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
begin
  if not (is_admin() or (is_coach() and coach_teaches_athlete(p_athlete_id))) then
    raise exception 'Only the athlete''s coaches can update their skills.';
  end if;
  insert into athlete_skills (athlete_id, skill_id, status, notes, updated_by, updated_at)
  values (p_athlete_id, p_skill_id, p_status, p_notes, auth.uid(), now())
  on conflict (athlete_id, skill_id)
  do update set status = excluded.status,
                notes = coalesce(excluded.notes, athlete_skills.notes),
                updated_by = excluded.updated_by, updated_at = now();
end;
$$;

create or replace function public.add_progress_note (
  p_athlete_id uuid, p_note text, p_booking_id uuid default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not (is_admin() or (is_coach() and coach_teaches_athlete(p_athlete_id))) then
    raise exception 'Only the athlete''s coaches can add progress notes.';
  end if;
  insert into progress_notes (athlete_id, coach_id, booking_id, note)
  values (p_athlete_id, auth.uid(), p_booking_id, p_note)
  returning id into v_id;
  return v_id;
end;
$$;

-- The public timetable. RLS hides other families' bookings, so this security
-- definer function exposes exactly what browsers may see: each slot with its
-- free-space count and which coaches are free/busy in it — never who booked.
create or replace function public.get_slot_board (p_from date, p_to date)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(t) order by t.slot_date, t.start_time), '[]'::jsonb)
  from (
    select
      s.id, s.slot_date, s.start_time, s.end_time, s.capacity, s.series_id, s.notes,
      (select count(*) from bookings b where b.slot_id = s.id and b.status = 'booked') as booked,
      (select count(*) from waitlist w where w.slot_id = s.id and w.status in ('waiting', 'offered')) as waiting,
      coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', p.id, 'name', p.full_name,
          'busy', exists (select 1 from bookings b2
                          where b2.slot_id = s.id and b2.coach_id = p.id and b2.status = 'booked')
        ) order by p.full_name)
        from slot_coaches sc join profiles p on p.id = sc.coach_id
        where sc.slot_id = s.id
      ), '[]'::jsonb) as coaches
    from slots s
    where s.slot_date between p_from and p_to
  ) t
$$;

-- ---------------------------------------------------------------------------
-- Seed data
-- ---------------------------------------------------------------------------
insert into public.club_settings (id) values (1);

-- Tumble skill library (levels follow common UK progression order).
insert into public.skills (discipline, category, name, level, sort) values
  ('tumble', 'Foundations', 'Forward roll', 1, 1),
  ('tumble', 'Foundations', 'Backward roll', 1, 2),
  ('tumble', 'Foundations', 'Handstand', 1, 3),
  ('tumble', 'Foundations', 'Bridge', 1, 4),
  ('tumble', 'Foundations', 'Cartwheel', 1, 5),
  ('tumble', 'Foundations', 'Round off', 1, 6),
  ('tumble', 'Walkovers', 'Backbend kick over', 2, 10),
  ('tumble', 'Walkovers', 'Back walkover', 2, 11),
  ('tumble', 'Walkovers', 'Front walkover', 2, 12),
  ('tumble', 'Walkovers', 'Valdez', 2, 13),
  ('tumble', 'Handsprings', 'Standing back handspring', 3, 20),
  ('tumble', 'Handsprings', 'Back handspring step out', 3, 21),
  ('tumble', 'Handsprings', 'Round off back handspring', 3, 22),
  ('tumble', 'Handsprings', 'Round off series back handsprings', 3, 23),
  ('tumble', 'Handsprings', 'Front handspring', 3, 24),
  ('tumble', 'Somersaults', 'Standing back tuck', 4, 30),
  ('tumble', 'Somersaults', 'Round off back tuck', 4, 31),
  ('tumble', 'Somersaults', 'Round off back handspring back tuck', 4, 32),
  ('tumble', 'Somersaults', 'Punch front', 4, 33),
  ('tumble', 'Somersaults', 'Side aerial', 4, 34),
  ('tumble', 'Layouts', 'Round off back handspring layout', 5, 40),
  ('tumble', 'Layouts', 'Whip', 5, 41),
  ('tumble', 'Layouts', 'Standing tuck series', 5, 42),
  ('tumble', 'Twisting', 'Round off back handspring full', 6, 50),
  ('tumble', 'Twisting', 'Standing full', 6, 51),
  ('tumble', 'Twisting', 'Double full', 6, 52);

-- All-star dance skill library.
insert into public.skills (discipline, category, name, level, sort) values
  ('dance', 'Turns', 'Single pirouette', 1, 1),
  ('dance', 'Turns', 'Double pirouette', 2, 2),
  ('dance', 'Turns', 'Triple pirouette', 3, 3),
  ('dance', 'Turns', 'À la seconde turns', 3, 4),
  ('dance', 'Turns', 'Fouetté turns', 4, 5),
  ('dance', 'Turns', 'Leg hold turn', 3, 6),
  ('dance', 'Turns', 'Illusion', 4, 7),
  ('dance', 'Leaps & Jumps', 'Grand jeté', 1, 10),
  ('dance', 'Leaps & Jumps', 'Toe touch', 1, 11),
  ('dance', 'Leaps & Jumps', 'Switch leap', 2, 12),
  ('dance', 'Leaps & Jumps', 'Firebird', 3, 13),
  ('dance', 'Leaps & Jumps', 'Calypso', 3, 14),
  ('dance', 'Leaps & Jumps', 'Switch second', 4, 15),
  ('dance', 'Leaps & Jumps', 'Turning disc', 4, 16),
  ('dance', 'Kicks', 'Grand battement', 1, 20),
  ('dance', 'Kicks', 'Front kick sequence', 1, 21),
  ('dance', 'Kicks', 'Side kick sequence', 2, 22),
  ('dance', 'Flexibility', 'Right splits', 1, 30),
  ('dance', 'Flexibility', 'Left splits', 1, 31),
  ('dance', 'Flexibility', 'Middle splits', 2, 32),
  ('dance', 'Flexibility', 'Heel stretch', 2, 33),
  ('dance', 'Flexibility', 'Scorpion', 3, 34),
  ('dance', 'Flexibility', 'Needle', 4, 35),
  ('dance', 'Flexibility', 'Bow and arrow', 3, 36);

-- ---------------------------------------------------------------------------
-- Function execution lock-down. Functions in public are EXECUTE-able by
-- PUBLIC by default, which would expose every security definer function
-- (including internal ones that trust their callers) to the anon role.
-- Revoke everything, then grant back only the user-facing RPCs.
-- ---------------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function
  public.book_slot (uuid, uuid, uuid, boolean),
  public.cancel_booking (uuid),
  public.cancel_booking_series (uuid),
  public.join_waitlist (uuid, uuid, uuid),
  public.leave_waitlist (uuid),
  public.accept_waitlist_offer (uuid, uuid),
  public.coach_join_slot (uuid, boolean),
  public.coach_leave_slot (uuid, boolean),
  public.take_register (uuid, public.attendance_status),
  public.update_athlete_skill (uuid, integer, public.skill_status, text),
  public.add_progress_note (uuid, text, uuid),
  public.admin_create_slots (date, time, time, integer, integer, text),
  public.admin_extend_series (uuid, integer),
  public.admin_delete_slot (uuid),
  public.get_slot_board (date, date),
  -- helper predicates referenced by RLS policies run with the caller's
  -- privileges, so authenticated needs EXECUTE on them
  public.is_admin (),
  public.is_coach (),
  public.my_role (),
  public.owns_athlete (uuid),
  public.coach_teaches_athlete (uuid)
to authenticated, service_role;

-- Internal-only machinery (_create_booking, notify, promote_waitlist,
-- slot_starts_at, trigger functions) stays owner-only: definer functions and
-- triggers run as the owner, so nothing user-facing breaks.

-- Future functions shouldn't auto-grant to everyone either.
alter default privileges in schema public revoke execute on functions from public;

-- ---------------------------------------------------------------------------
-- FIRST ADMIN — after you sign up in the app, run this with your email:
--   update public.profiles set role = 'admin' where email = 'you@example.com';
-- ---------------------------------------------------------------------------
