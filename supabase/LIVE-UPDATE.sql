-- ============================================================================
-- IGNYTE CLUB MANAGER — v5 "FULL CLUB MANAGER" (ADDITIVE — safe on live v4)
-- ----------------------------------------------------------------------------
-- Four pillars, competing head-on with Class4Kids / LoveAdmin / ClassManager:
--   1. PAYMENTS   — invoices, payment recording, credit-pack sales, pay links,
--                   per-club currency & instructions. The club stays merchant
--                   of record; we never take a cut.
--   2. CLASSES    — recurring weekly group classes with capacity, age bands,
--                   rosters, self-serve waiting lists and free/paid trials.
--   3. MEMBERSHIPS— monthly plans (classes + private credits), auto-invoiced
--                   by cron on the 1st, overdue chasing daily.
--   4. OPERATIONS — one-tap class registers with medical flags, money
--                   dashboard, everything feeding the Excel exports.
-- Same rules as v4: every write goes through a SECURITY DEFINER RPC, every
-- row carries club_id, RLS walls clubs off, suspended club = full lock.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Club settings: payments configuration
-- ---------------------------------------------------------------------------
alter table public.club_settings
  add column if not exists currency text not null default '£',
  add column if not exists payment_instructions text,
  add column if not exists payment_link_url text,
  add column if not exists invoice_due_days int not null default 7 check (invoice_due_days between 0 and 60);

-- ---------------------------------------------------------------------------
-- Group classes
-- ---------------------------------------------------------------------------
create table public.class_groups (
  id uuid primary key default gen_random_uuid (),
  club_id uuid not null references public.clubs (id) on delete cascade,
  name text not null,
  discipline text not null default 'tumble',
  description text,
  day_of_week int not null check (day_of_week between 0 and 6), -- 0 = Sunday
  start_time time not null,
  end_time time not null,
  location_id uuid references public.locations (id),
  lead_coach_id uuid references public.profiles (id),
  capacity int not null check (capacity > 0),
  age_min int check (age_min between 0 and 99),
  age_max int check (age_max between 0 and 99),
  price_per_session numeric(8, 2) check (price_per_session >= 0),
  monthly_fee numeric(8, 2) check (monthly_fee >= 0),
  trial_allowed boolean not null default true,
  trial_price numeric(8, 2) check (trial_price >= 0), -- null/0 = free trial
  active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint class_times check (end_time > start_time)
);
create index class_groups_club_idx on public.class_groups (club_id, active);

create table public.class_enrolments (
  class_id uuid not null references public.class_groups (id) on delete cascade,
  club_id uuid not null references public.clubs (id) on delete cascade,
  athlete_id uuid not null references public.athletes (id) on delete cascade,
  status text not null default 'enrolled' check (status in ('enrolled', 'waiting', 'left')),
  added_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  left_at timestamptz,
  primary key (class_id, athlete_id)
);
create index class_enrolments_athlete_idx on public.class_enrolments (athlete_id);
create index class_enrolments_class_idx on public.class_enrolments (class_id, status);

create table public.class_sessions (
  id uuid primary key default gen_random_uuid (),
  class_id uuid not null references public.class_groups (id) on delete cascade,
  club_id uuid not null references public.clubs (id) on delete cascade,
  session_date date not null,
  start_time time not null,
  end_time time not null,
  cancelled boolean not null default false,
  notes text,
  unique (class_id, session_date)
);
create index class_sessions_club_date_idx on public.class_sessions (club_id, session_date);

create table public.class_attendance (
  session_id uuid not null references public.class_sessions (id) on delete cascade,
  club_id uuid not null references public.clubs (id) on delete cascade,
  athlete_id uuid not null references public.athletes (id) on delete cascade,
  status public.attendance_status not null,
  trial boolean not null default false,
  marked_by uuid references public.profiles (id),
  marked_at timestamptz not null default now(),
  primary key (session_id, athlete_id)
);
create index class_attendance_athlete_idx on public.class_attendance (athlete_id);

create table public.class_trials (
  id uuid primary key default gen_random_uuid (),
  club_id uuid not null references public.clubs (id) on delete cascade,
  class_id uuid not null references public.class_groups (id) on delete cascade,
  session_id uuid not null references public.class_sessions (id) on delete cascade,
  athlete_id uuid not null references public.athletes (id) on delete cascade,
  booked_by uuid not null references public.profiles (id),
  status text not null default 'booked' check (status in ('booked', 'attended', 'cancelled')),
  created_at timestamptz not null default now(),
  unique (session_id, athlete_id)
);
create index class_trials_club_idx on public.class_trials (club_id, status);

-- ---------------------------------------------------------------------------
-- Payments: invoices + payments ledger
-- ---------------------------------------------------------------------------
create table public.invoices (
  id uuid primary key default gen_random_uuid (),
  invoice_no bigint generated always as identity,
  club_id uuid not null references public.clubs (id) on delete cascade,
  profile_id uuid not null references public.profiles (id) on delete cascade, -- the payer
  description text not null,
  amount numeric(10, 2) not null check (amount >= 0),
  status text not null default 'due' check (status in ('due', 'overdue', 'paid', 'void')),
  due_date date not null,
  source text not null default 'manual' check (source in ('manual', 'membership', 'credit_pack', 'trial', 'lessons', 'class')),
  meta jsonb not null default '{}'::jsonb, -- e.g. {"grant_credits": 10, "membership_id": "..."}
  period_start date,
  period_end date,
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  paid_at timestamptz,
  paid_method text,
  paid_reference text
);
create index invoices_club_status_idx on public.invoices (club_id, status, due_date);
create index invoices_profile_idx on public.invoices (profile_id, club_id, created_at desc);

create table public.payments (
  id uuid primary key default gen_random_uuid (),
  club_id uuid not null references public.clubs (id) on delete cascade,
  invoice_id uuid references public.invoices (id) on delete set null,
  profile_id uuid not null references public.profiles (id) on delete cascade,
  amount numeric(10, 2) not null,
  method text not null check (method in ('cash', 'bank_transfer', 'card', 'online', 'other')),
  reference text,
  received_by uuid references public.profiles (id),
  received_at timestamptz not null default now()
);
create index payments_club_idx on public.payments (club_id, received_at desc);
create index payments_invoice_idx on public.payments (invoice_id);

-- ---------------------------------------------------------------------------
-- Memberships
-- ---------------------------------------------------------------------------
create table public.membership_plans (
  id uuid primary key default gen_random_uuid (),
  club_id uuid not null references public.clubs (id) on delete cascade,
  name text not null,
  description text,
  monthly_fee numeric(8, 2) not null check (monthly_fee >= 0),
  classes_per_week int check (classes_per_week > 0), -- null = unlimited classes
  private_credits_per_month int not null default 0 check (private_credits_per_month between 0 and 100),
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create index membership_plans_club_idx on public.membership_plans (club_id, active);

create table public.memberships (
  id uuid primary key default gen_random_uuid (),
  club_id uuid not null references public.clubs (id) on delete cascade,
  plan_id uuid not null references public.membership_plans (id) on delete cascade,
  athlete_id uuid not null references public.athletes (id) on delete cascade,
  payer_id uuid not null references public.profiles (id) on delete cascade,
  status text not null default 'active' check (status in ('active', 'paused', 'cancelled')),
  started_on date not null default current_date,
  cancelled_on date,
  created_at timestamptz not null default now()
);
create unique index memberships_active_uniq on public.memberships (club_id, athlete_id) where (status = 'active');
create index memberships_club_idx on public.memberships (club_id, status);
create index memberships_payer_idx on public.memberships (payer_id);

-- ---------------------------------------------------------------------------
-- Row-level security (reads; all writes flow through RPCs)
-- ---------------------------------------------------------------------------
alter table public.class_groups enable row level security;
alter table public.class_enrolments enable row level security;
alter table public.class_sessions enable row level security;
alter table public.class_attendance enable row level security;
alter table public.class_trials enable row level security;
alter table public.invoices enable row level security;
alter table public.payments enable row level security;
alter table public.membership_plans enable row level security;
alter table public.memberships enable row level security;

create policy class_groups_select on public.class_groups for select to authenticated
  using (club_id in (select my_club_ids()));
create policy class_sessions_select on public.class_sessions for select to authenticated
  using (club_id in (select my_club_ids()));
create policy class_enrolments_select on public.class_enrolments for select to authenticated
  using ((club_id in (select my_club_ids())) and (owns_athlete(athlete_id) or is_coach_of(club_id)));
create policy class_attendance_select on public.class_attendance for select to authenticated
  using ((club_id in (select my_club_ids())) and (owns_athlete(athlete_id) or is_coach_of(club_id)));
create policy class_trials_select on public.class_trials for select to authenticated
  using ((club_id in (select my_club_ids())) and
         (booked_by = auth.uid() or owns_athlete(athlete_id) or is_coach_of(club_id)));

create policy invoices_select on public.invoices for select to authenticated
  using ((club_id in (select my_club_ids())) and (profile_id = auth.uid() or is_admin_of(club_id)));
create policy payments_select on public.payments for select to authenticated
  using ((club_id in (select my_club_ids())) and (profile_id = auth.uid() or is_admin_of(club_id)));

create policy membership_plans_select on public.membership_plans for select to authenticated
  using ((club_id in (select my_club_ids())) and (active or is_admin_of(club_id)));
create policy memberships_select on public.memberships for select to authenticated
  using ((club_id in (select my_club_ids())) and
         (payer_id = auth.uid() or owns_athlete(athlete_id) or is_admin_of(club_id)));

-- ===========================================================================
-- RPCs — classes
-- ===========================================================================
create or replace function public.ensure_class_sessions (p_class uuid default null, p_weeks int default 8)
returns int language plpgsql security definer set search_path = public as $$
declare
  g record;
  v_first date;
  v_created int := 0;
  w int;
begin
  for g in
    select cg.* from class_groups cg join clubs c on c.id = cg.club_id
    where cg.active and c.status = 'active' and (p_class is null or cg.id = p_class)
  loop
    v_first := current_date + ((g.day_of_week - extract(dow from current_date)::int + 7) % 7);
    for w in 0 .. p_weeks - 1 loop
      insert into class_sessions (class_id, club_id, session_date, start_time, end_time)
      values (g.id, g.club_id, v_first + w * 7, g.start_time, g.end_time)
      on conflict (class_id, session_date) do nothing;
      if found then v_created := v_created + 1; end if;
    end loop;
  end loop;
  return v_created;
end;
$$;

create or replace function public.admin_save_class (
  p_club uuid, p_id uuid, p_name text, p_discipline text, p_day int,
  p_start time, p_end time, p_capacity int,
  p_location uuid default null, p_coach uuid default null,
  p_age_min int default null, p_age_max int default null,
  p_price numeric default null, p_monthly numeric default null,
  p_trial_allowed boolean default true, p_trial_price numeric default null,
  p_description text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid := p_id;
begin
  if not is_admin_of(p_club) then raise exception 'Only club admins can manage classes.'; end if;
  perform assert_club_active(p_club);
  if p_location is not null and (select club_id from locations where id = p_location) <> p_club then
    raise exception 'Pick one of this club''s locations.';
  end if;
  if p_coach is not null and not exists (
    select 1 from club_members where club_id = p_club and profile_id = p_coach
      and role in ('coach', 'admin') and status = 'active') then
    raise exception 'The lead coach must be one of this club''s coaches.';
  end if;

  if v_id is null then
    insert into class_groups (club_id, name, discipline, description, day_of_week, start_time, end_time,
                              location_id, lead_coach_id, capacity, age_min, age_max,
                              price_per_session, monthly_fee, trial_allowed, trial_price)
    values (p_club, trim(p_name), p_discipline, p_description, p_day, p_start, p_end,
            p_location, p_coach, p_capacity, p_age_min, p_age_max,
            p_price, p_monthly, p_trial_allowed, p_trial_price)
    returning id into v_id;
  else
    update class_groups set
      name = trim(p_name), discipline = p_discipline, description = p_description,
      day_of_week = p_day, start_time = p_start, end_time = p_end,
      location_id = p_location, lead_coach_id = p_coach, capacity = p_capacity,
      age_min = p_age_min, age_max = p_age_max, price_per_session = p_price,
      monthly_fee = p_monthly, trial_allowed = p_trial_allowed, trial_price = p_trial_price
    where id = v_id and club_id = p_club;
    if not found then raise exception 'Class not found.'; end if;
    -- future sessions follow the new day/time; drop day-mismatched ones nobody attended
    delete from class_sessions s
      where s.class_id = v_id and s.session_date >= current_date
        and extract(dow from s.session_date)::int <> p_day
        and not exists (select 1 from class_attendance a where a.session_id = s.id)
        and not exists (select 1 from class_trials t where t.session_id = s.id and t.status = 'booked');
    update class_sessions s set start_time = p_start, end_time = p_end
      where s.class_id = v_id and s.session_date >= current_date and not s.cancelled;
  end if;
  perform ensure_class_sessions(v_id, 8);
  perform owner_log(p_club, 'save_class', trim(p_name));
  return v_id;
end;
$$;

create or replace function public.admin_set_class_active (p_class uuid, p_active boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_club uuid := (select club_id from class_groups where id = p_class);
begin
  if v_club is null then raise exception 'Class not found.'; end if;
  if not is_admin_of(v_club) then raise exception 'Only club admins can manage classes.'; end if;
  update class_groups set active = p_active where id = p_class;
  if not p_active then
    delete from class_sessions where class_id = p_class and session_date > current_date
      and not exists (select 1 from class_attendance a where a.session_id = class_sessions.id);
  else
    perform ensure_class_sessions(p_class, 8);
  end if;
end;
$$;

create or replace function public.admin_cancel_class_session (p_session uuid, p_cancelled boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_s class_sessions%rowtype;
  r record;
begin
  select * into v_s from class_sessions where id = p_session;
  if v_s.id is null then raise exception 'Session not found.'; end if;
  if not is_admin_of(v_s.club_id) then raise exception 'Only club admins can cancel sessions.'; end if;
  update class_sessions set cancelled = p_cancelled where id = p_session;
  if p_cancelled then
    for r in
      select distinct coalesce(a.parent_id, a.profile_id) as owner_id
      from class_enrolments e join athletes a on a.id = e.athlete_id
      where e.class_id = v_s.class_id and e.status = 'enrolled'
        and coalesce(a.parent_id, a.profile_id) is not null
    loop
      perform notify(r.owner_id, v_s.club_id, 'class_cancelled', 'Class cancelled',
        (select name from class_groups where id = v_s.class_id) || ' on '
        || to_char(v_s.session_date, 'FMDay DD Mon') || ' has been cancelled.',
        jsonb_build_object('session_id', p_session));
    end loop;
  end if;
end;
$$;

create or replace function public.get_classes (p_club uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case
    when p_club not in (select my_club_ids()) then '[]'::jsonb
    else coalesce((
      select jsonb_agg(to_jsonb(t) order by t.day_of_week, t.start_time) from (
        select g.id, g.name, g.discipline, g.description, g.day_of_week, g.start_time, g.end_time,
          g.capacity, g.age_min, g.age_max, g.price_per_session, g.monthly_fee,
          g.trial_allowed, g.trial_price, g.active, g.lead_coach_id,
          l.name as location, p.full_name as coach,
          (select count(*) from class_enrolments e where e.class_id = g.id and e.status = 'enrolled') as enrolled,
          (select count(*) from class_enrolments e where e.class_id = g.id and e.status = 'waiting') as waiting,
          (select min(s.session_date) from class_sessions s
            where s.class_id = g.id and s.session_date >= current_date and not s.cancelled) as next_date
        from class_groups g
        left join locations l on l.id = g.location_id
        left join profiles p on p.id = g.lead_coach_id
        where g.club_id = p_club and (g.active or is_admin_of(p_club))
      ) t), '[]'::jsonb)
  end
$$;

create or replace function public.enrol_class (p_class uuid, p_athlete uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_g class_groups%rowtype;
  v_enrolled int;
  v_status text;
  v_admin boolean;
  v_age int;
begin
  select * into v_g from class_groups where id = p_class for update;
  if v_g.id is null or not v_g.active then raise exception 'Class not found.'; end if;
  v_admin := is_admin_of(v_g.club_id);
  if not (owns_athlete(p_athlete) or v_admin) then
    raise exception 'You can only enrol your own athletes.';
  end if;
  perform assert_club_active(v_g.club_id);
  if not athlete_in_club(p_athlete, v_g.club_id) then
    raise exception 'This athlete isn''t enrolled at this club yet — add them under Athletes first.';
  end if;
  if not v_admin and not exists (select 1 from club_members
      where club_id = v_g.club_id and profile_id = auth.uid() and status = 'active') then
    raise exception 'Join this club before enrolling in classes.';
  end if;
  v_age := date_part('year', age((select dob from athletes where id = p_athlete)))::int;
  if not v_admin and ((v_g.age_min is not null and v_age < v_g.age_min)
                   or (v_g.age_max is not null and v_age > v_g.age_max)) then
    raise exception 'This class is for ages % to % — contact the club if you think they should still join.',
      coalesce(v_g.age_min, 0), coalesce(v_g.age_max, 99);
  end if;

  select count(*) into v_enrolled from class_enrolments where class_id = p_class and status = 'enrolled';
  v_status := case when v_enrolled < v_g.capacity or v_admin then 'enrolled' else 'waiting' end;

  insert into class_enrolments (class_id, club_id, athlete_id, status, added_by)
  values (p_class, v_g.club_id, p_athlete, v_status, auth.uid())
  on conflict (class_id, athlete_id) do update set status = excluded.status, left_at = null
    where class_enrolments.status = 'left';
  if not found then raise exception 'This athlete is already on this class''s list.'; end if;

  if v_status = 'enrolled' then
    perform notify(auth.uid(), v_g.club_id, 'class_enrolled', 'Class place confirmed 🎉',
      (select name from athletes where id = p_athlete) || ' has a place in ' || v_g.name || '.',
      jsonb_build_object('class_id', p_class));
    if v_g.lead_coach_id is not null and v_g.lead_coach_id <> auth.uid() then
      perform notify(v_g.lead_coach_id, v_g.club_id, 'class_enrolled', 'New class member',
        (select name from athletes where id = p_athlete) || ' joined ' || v_g.name || '.',
        jsonb_build_object('class_id', p_class));
    end if;
  else
    perform notify(auth.uid(), v_g.club_id, 'class_waiting', 'Added to the waiting list',
      v_g.name || ' is currently full — ' || (select name from athletes where id = p_athlete)
      || ' is on the waiting list and you''ll be notified the moment a space opens.',
      jsonb_build_object('class_id', p_class));
  end if;
  return jsonb_build_object('status', v_status);
end;
$$;

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

  -- a real space opened: promote the first waiting athlete
  if v_was = 'enrolled' then
    select e.athlete_id, coalesce(a.parent_id, a.profile_id) as owner_id, a.name
      into v_next
      from class_enrolments e join athletes a on a.id = e.athlete_id
      where e.class_id = p_class and e.status = 'waiting'
      order by e.created_at limit 1;
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

  if coalesce(v_g.trial_price, 0) > 0 then
    select invoice_due_days into v_due_days from club_settings where club_id = v_g.club_id;
    insert into invoices (club_id, profile_id, description, amount, due_date, source, meta, created_by)
    values (v_g.club_id, auth.uid(),
            'Trial — ' || v_g.name || ' (' || v_athlete || ', ' || to_char(v_s.session_date, 'DD Mon') || ')',
            v_g.trial_price, least(v_s.session_date, current_date + coalesce(v_due_days, 7)),
            'trial', jsonb_build_object('trial_id', v_id), auth.uid());
  end if;

  perform notify(auth.uid(), v_g.club_id, 'trial_booked', 'Trial booked! ⭐',
    v_athlete || ' is trying ' || v_g.name || ' on ' || to_char(v_s.session_date, 'FMDay DD Mon')
    || case when coalesce(v_g.trial_price, 0) > 0 then ' — the trial invoice is in your Money page.' else ' — first taste is free!' end,
    jsonb_build_object('trial_id', v_id));
  if v_g.lead_coach_id is not null and v_g.lead_coach_id <> auth.uid() then
    perform notify(v_g.lead_coach_id, v_g.club_id, 'trial_booked', 'Trial booked',
      v_athlete || ' is trialling ' || v_g.name || ' on ' || to_char(v_s.session_date, 'FMDay DD Mon') || '.',
      jsonb_build_object('trial_id', v_id));
  end if;
  return v_id;
end;
$$;

create or replace function public.cancel_class_trial (p_trial uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_t class_trials%rowtype;
begin
  select * into v_t from class_trials where id = p_trial for update;
  if v_t.id is null then raise exception 'Trial not found.'; end if;
  if not (v_t.booked_by = auth.uid() or owns_athlete(v_t.athlete_id) or is_admin_of(v_t.club_id)) then
    raise exception 'Not your trial booking.';
  end if;
  if v_t.status <> 'booked' then raise exception 'This trial is already finished.'; end if;
  update class_trials set status = 'cancelled' where id = p_trial;
  update invoices set status = 'void'
    where club_id = v_t.club_id and status in ('due', 'overdue') and (meta ->> 'trial_id')::uuid = p_trial;
end;
$$;

create or replace function public.get_class_register (p_session uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case
    when not is_coach_of((select club_id from class_sessions where id = p_session)) then null
    else (
      select jsonb_build_object(
        'session', to_jsonb(s) || jsonb_build_object('class_name', g.name, 'capacity', g.capacity,
          'location', (select name from locations where id = g.location_id)),
        'roster', coalesce((
          select jsonb_agg(to_jsonb(r) order by r.trial, r.name) from (
            select a.id as athlete_id, a.name, a.dob, a.medical_notes is not null as medical,
              false as trial, att.status as attendance
            from class_enrolments e
            join athletes a on a.id = e.athlete_id
            left join class_attendance att on att.session_id = s.id and att.athlete_id = a.id
            where e.class_id = s.class_id and e.status = 'enrolled'
            union all
            select a.id, a.name, a.dob, a.medical_notes is not null, true, att.status
            from class_trials t
            join athletes a on a.id = t.athlete_id
            left join class_attendance att on att.session_id = s.id and att.athlete_id = a.id
            where t.session_id = s.id and t.status in ('booked', 'attended')
          ) r), '[]'::jsonb))
      from class_sessions s join class_groups g on g.id = s.class_id
      where s.id = p_session)
  end
$$;

create or replace function public.take_class_register (p_session uuid, p_athlete uuid, p_status public.attendance_status)
returns void language plpgsql security definer set search_path = public as $$
declare v_s class_sessions%rowtype;
begin
  select * into v_s from class_sessions where id = p_session;
  if v_s.id is null then raise exception 'Session not found.'; end if;
  if not is_coach_of(v_s.club_id) then raise exception 'Only the club''s coaches can take the register.'; end if;
  insert into class_attendance (session_id, club_id, athlete_id, status, trial, marked_by)
  values (p_session, v_s.club_id, p_athlete, p_status,
          exists (select 1 from class_trials t where t.session_id = p_session and t.athlete_id = p_athlete and t.status in ('booked', 'attended')),
          auth.uid())
  on conflict (session_id, athlete_id)
  do update set status = excluded.status, marked_by = excluded.marked_by, marked_at = now();
  update class_trials set status = case when p_status = 'present' then 'attended' else status end
    where session_id = p_session and athlete_id = p_athlete and status = 'booked';
end;
$$;

-- ===========================================================================
-- RPCs — money
-- ===========================================================================
create or replace function public.admin_create_invoice (
  p_club uuid, p_profile uuid, p_description text, p_amount numeric,
  p_due date default null, p_meta jsonb default '{}'::jsonb, p_source text default 'manual'
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_due_days int;
  v_symbol text;
begin
  if not is_admin_of(p_club) then raise exception 'Only club admins can raise invoices.'; end if;
  if p_amount <= 0 then raise exception 'Invoice amount must be more than zero.'; end if;
  if not exists (select 1 from club_members where club_id = p_club and profile_id = p_profile and status = 'active') then
    raise exception 'That person is not an active member of this club.';
  end if;
  select invoice_due_days, currency into v_due_days, v_symbol from club_settings where club_id = p_club;
  insert into invoices (club_id, profile_id, description, amount, due_date, source, meta, created_by)
  values (p_club, p_profile, trim(p_description), round(p_amount, 2),
          coalesce(p_due, current_date + coalesce(v_due_days, 7)), p_source, p_meta, auth.uid())
  returning id into v_id;
  perform notify(p_profile, p_club, 'invoice_new', 'New invoice',
    trim(p_description) || ' — ' || coalesce(v_symbol, '£') || round(p_amount, 2)
    || ', due ' || to_char(coalesce(p_due, current_date + coalesce(v_due_days, 7)), 'DD Mon')
    || '. See your Money page for how to pay.', jsonb_build_object('invoice_id', v_id));
  perform owner_log(p_club, 'create_invoice', round(p_amount, 2)::text);
  return v_id;
end;
$$;

create or replace function public.admin_sell_credit_pack (
  p_club uuid, p_profile uuid, p_credits int, p_amount numeric
) returns uuid language plpgsql security definer set search_path = public as $$
begin
  if p_credits < 1 or p_credits > 100 then raise exception 'Packs are between 1 and 100 credits.'; end if;
  return admin_create_invoice(p_club, p_profile,
    p_credits || ' lesson credit pack', p_amount, null,
    jsonb_build_object('grant_credits', p_credits), 'credit_pack');
end;
$$;

create or replace function public.record_payment (p_invoice uuid, p_method text, p_reference text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_i invoices%rowtype;
  v_credits int;
  v_symbol text;
begin
  select * into v_i from invoices where id = p_invoice for update;
  if v_i.id is null then raise exception 'Invoice not found.'; end if;
  if not is_admin_of(v_i.club_id) then raise exception 'Only club admins can record payments.'; end if;
  if v_i.status not in ('due', 'overdue') then raise exception 'This invoice is already settled.'; end if;
  if p_method not in ('cash', 'bank_transfer', 'card', 'online', 'other') then raise exception 'Bad payment method.'; end if;

  update invoices set status = 'paid', paid_at = now(), paid_method = p_method, paid_reference = p_reference
    where id = p_invoice;
  insert into payments (club_id, invoice_id, profile_id, amount, method, reference, received_by)
  values (v_i.club_id, p_invoice, v_i.profile_id, v_i.amount, p_method, p_reference, auth.uid());

  -- credit packs & membership perks: grant private-lesson credits on payment
  v_credits := coalesce((v_i.meta ->> 'grant_credits')::int, 0);
  if v_credits > 0 then
    insert into credit_ledger (club_id, profile_id, delta, reason, created_by)
    values (v_i.club_id, v_i.profile_id, v_credits, 'Included with: ' || v_i.description, auth.uid());
  end if;

  select currency into v_symbol from club_settings where club_id = v_i.club_id;
  perform notify(v_i.profile_id, v_i.club_id, 'payment_received', 'Payment received — thank you! ✅',
    v_i.description || ' (' || coalesce(v_symbol, '£') || v_i.amount || ') is marked paid.'
    || case when v_credits > 0 then ' ' || v_credits || ' lesson credit(s) added.' else '' end,
    jsonb_build_object('invoice_id', p_invoice));
  perform owner_log(v_i.club_id, 'record_payment', v_i.amount::text);
end;
$$;

create or replace function public.void_invoice (p_invoice uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_i invoices%rowtype;
begin
  select * into v_i from invoices where id = p_invoice for update;
  if v_i.id is null then raise exception 'Invoice not found.'; end if;
  if not is_admin_of(v_i.club_id) then raise exception 'Only club admins can void invoices.'; end if;
  if v_i.status = 'paid' then raise exception 'This invoice is paid — refunds are recorded outside the app.'; end if;
  update invoices set status = 'void' where id = p_invoice;
end;
$$;

create or replace function public.chase_invoice (p_invoice uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_i invoices%rowtype;
  v_symbol text;
begin
  select * into v_i from invoices where id = p_invoice;
  if v_i.id is null then raise exception 'Invoice not found.'; end if;
  if not is_admin_of(v_i.club_id) then raise exception 'Only club admins can send reminders.'; end if;
  if v_i.status not in ('due', 'overdue') then raise exception 'This invoice is already settled.'; end if;
  select currency into v_symbol from club_settings where club_id = v_i.club_id;
  perform notify(v_i.profile_id, v_i.club_id, 'invoice_reminder', 'Payment reminder',
    v_i.description || ' — ' || coalesce(v_symbol, '£') || v_i.amount || ' was due '
    || to_char(v_i.due_date, 'DD Mon') || '. See your Money page for how to pay.',
    jsonb_build_object('invoice_id', p_invoice));
end;
$$;

create or replace function public.update_payment_settings (
  p_club uuid, p_currency text, p_instructions text, p_link text, p_due_days int
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
    invoice_due_days = coalesce(p_due_days, 7)
  where club_id = p_club;
  perform owner_log(p_club, 'update_payment_settings', null);
end;
$$;

create or replace function public.admin_money_summary (p_club uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not is_admin_of(p_club) then '{}'::jsonb else jsonb_build_object(
    'due', coalesce((select sum(amount) from invoices where club_id = p_club and status = 'due'), 0),
    'overdue', coalesce((select sum(amount) from invoices where club_id = p_club and status = 'overdue'), 0),
    'paid_30d', coalesce((select sum(amount) from invoices where club_id = p_club and status = 'paid'
                          and paid_at > now() - interval '30 days'), 0),
    'by_month', coalesce((select jsonb_agg(to_jsonb(m) order by m.month) from (
        select to_char(date_trunc('month', paid_at), 'YYYY-MM') as month, sum(amount) as total
        from invoices where club_id = p_club and status = 'paid'
          and paid_at > date_trunc('month', now()) - interval '5 months'
        group by 1
      ) m), '[]'::jsonb),
    'debtors', coalesce((select jsonb_agg(to_jsonb(d) order by d.owed desc) from (
        select p.full_name as name, i.profile_id, sum(i.amount) as owed,
          min(i.due_date) as oldest_due,
          bool_or(i.status = 'overdue') as has_overdue
        from invoices i join profiles p on p.id = i.profile_id
        where i.club_id = p_club and i.status in ('due', 'overdue')
        group by p.full_name, i.profile_id
        order by sum(i.amount) desc limit 12
      ) d), '[]'::jsonb)
  ) end
$$;

-- ===========================================================================
-- RPCs — memberships
-- ===========================================================================
create or replace function public.admin_save_plan (
  p_club uuid, p_id uuid, p_name text, p_fee numeric,
  p_classes_per_week int default null, p_credits int default 0,
  p_description text default null, p_active boolean default true
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid := p_id;
begin
  if not is_admin_of(p_club) then raise exception 'Only club admins can manage plans.'; end if;
  if v_id is null then
    insert into membership_plans (club_id, name, description, monthly_fee, classes_per_week, private_credits_per_month, active)
    values (p_club, trim(p_name), p_description, round(p_fee, 2), p_classes_per_week, coalesce(p_credits, 0), p_active)
    returning id into v_id;
  else
    update membership_plans set name = trim(p_name), description = p_description,
      monthly_fee = round(p_fee, 2), classes_per_week = p_classes_per_week,
      private_credits_per_month = coalesce(p_credits, 0), active = p_active
    where id = v_id and club_id = p_club;
    if not found then raise exception 'Plan not found.'; end if;
  end if;
  perform owner_log(p_club, 'save_plan', trim(p_name));
  return v_id;
end;
$$;

-- Internal: raise one membership invoice for a given month (idempotent).
create or replace function public._membership_invoice (p_membership uuid, p_month date)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_m memberships%rowtype;
  v_p membership_plans%rowtype;
  v_id uuid;
  v_due_days int;
  v_symbol text;
  v_athlete text;
begin
  select * into v_m from memberships where id = p_membership;
  if v_m.id is null or v_m.status <> 'active' then return null; end if;
  select * into v_p from membership_plans where id = v_m.plan_id;
  if exists (select 1 from invoices where (meta ->> 'membership_id')::uuid = p_membership
             and period_start = date_trunc('month', p_month)::date and status <> 'void') then
    return null;
  end if;
  select invoice_due_days, currency into v_due_days, v_symbol from club_settings where club_id = v_m.club_id;
  select name into v_athlete from athletes where id = v_m.athlete_id;
  insert into invoices (club_id, profile_id, description, amount, due_date, source, meta, period_start, period_end)
  values (v_m.club_id, v_m.payer_id,
          v_p.name || ' — ' || v_athlete || ' (' || to_char(p_month, 'FMMonth YYYY') || ')',
          v_p.monthly_fee,
          greatest(date_trunc('month', p_month)::date, current_date) + coalesce(v_due_days, 7),
          'membership',
          jsonb_build_object('membership_id', p_membership)
            || case when v_p.private_credits_per_month > 0
                    then jsonb_build_object('grant_credits', v_p.private_credits_per_month)
                    else '{}'::jsonb end,
          date_trunc('month', p_month)::date,
          (date_trunc('month', p_month) + interval '1 month - 1 day')::date)
  returning id into v_id;
  perform notify(v_m.payer_id, v_m.club_id, 'invoice_new', 'Membership invoice',
    v_p.name || ' for ' || v_athlete || ' — ' || coalesce(v_symbol, '£') || v_p.monthly_fee
    || ' (' || to_char(p_month, 'FMMonth') || '). See your Money page for how to pay.',
    jsonb_build_object('invoice_id', v_id));
  return v_id;
end;
$$;

create or replace function public.start_membership (p_plan uuid, p_athlete uuid, p_payer uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_p membership_plans%rowtype;
  v_admin boolean;
  v_payer uuid;
  v_id uuid;
begin
  select * into v_p from membership_plans where id = p_plan;
  if v_p.id is null or not v_p.active then raise exception 'Plan not found.'; end if;
  v_admin := is_admin_of(v_p.club_id);
  if not (owns_athlete(p_athlete) or v_admin) then
    raise exception 'You can only start memberships for your own athletes.';
  end if;
  perform assert_club_active(v_p.club_id);
  if not athlete_in_club(p_athlete, v_p.club_id) then
    raise exception 'This athlete isn''t enrolled at this club yet.';
  end if;
  v_payer := case when v_admin and p_payer is not null then p_payer
                  when owns_athlete(p_athlete) then auth.uid()
                  else coalesce((select coalesce(parent_id, profile_id) from athletes where id = p_athlete), auth.uid()) end;
  if not exists (select 1 from club_members where club_id = v_p.club_id and profile_id = v_payer and status = 'active') then
    raise exception 'The payer must be an active member of this club.';
  end if;

  insert into memberships (club_id, plan_id, athlete_id, payer_id)
  values (v_p.club_id, p_plan, p_athlete, v_payer)
  returning id into v_id;

  perform _membership_invoice(v_id, current_date);
  perform notify(v_payer, v_p.club_id, 'membership_started', 'Membership started 🎉',
    (select name from athletes where id = p_athlete) || ' is now on ' || v_p.name
    || ' — the first month''s invoice is on your Money page.',
    jsonb_build_object('membership_id', v_id));
  perform owner_log(v_p.club_id, 'start_membership', v_p.name);
  return v_id;
exception when unique_violation then
  raise exception 'This athlete already has an active membership at this club.';
end;
$$;

create or replace function public.cancel_membership (p_membership uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_m memberships%rowtype;
begin
  select * into v_m from memberships where id = p_membership for update;
  if v_m.id is null then raise exception 'Membership not found.'; end if;
  if not (v_m.payer_id = auth.uid() or owns_athlete(v_m.athlete_id) or is_admin_of(v_m.club_id)) then
    raise exception 'You can''t cancel this membership.';
  end if;
  if v_m.status = 'cancelled' then raise exception 'Already cancelled.'; end if;
  update memberships set status = 'cancelled', cancelled_on = current_date where id = p_membership;
  perform notify(v_m.payer_id, v_m.club_id, 'membership_cancelled', 'Membership cancelled',
    (select name from athletes where id = v_m.athlete_id) || '''s membership ends with the current paid month.',
    jsonb_build_object('membership_id', p_membership));
end;
$$;

-- Cron: 1st of the month — raise every active membership's invoice.
create or replace function public.generate_membership_invoices () returns int
language plpgsql security definer set search_path = public as $$
declare
  r record;
  v_count int := 0;
begin
  for r in
    select m.id from memberships m
    join clubs c on c.id = m.club_id and c.status = 'active'
    where m.status = 'active'
  loop
    if _membership_invoice(r.id, current_date) is not null then v_count := v_count + 1; end if;
  end loop;
  return v_count;
end;
$$;

-- Cron: daily — flip past-due invoices to overdue and nudge the payer once.
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
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- Public portal now advertises the class timetable too.
-- ---------------------------------------------------------------------------
create or replace function public.get_club_public (p_slug text) returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(t) from (
    select c.name, c.slug, c.blurb, c.logo_path, c.accent_color, c.status,
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
       from class_groups g where g.club_id = c.id and g.active) as classes
    from clubs c where c.slug = lower(p_slug) and c.status = 'active' and c.searchable
  ) t
$$;

-- ---------------------------------------------------------------------------
-- Execution lock-down for the new RPCs
-- ---------------------------------------------------------------------------
revoke execute on function
  public.ensure_class_sessions (uuid, int),
  public.admin_save_class (uuid, uuid, text, text, int, time, time, int, uuid, uuid, int, int, numeric, numeric, boolean, numeric, text),
  public.admin_set_class_active (uuid, boolean),
  public.admin_cancel_class_session (uuid, boolean),
  public.get_classes (uuid),
  public.enrol_class (uuid, uuid),
  public.leave_class (uuid, uuid),
  public.book_class_trial (uuid, uuid, uuid),
  public.cancel_class_trial (uuid),
  public.get_class_register (uuid),
  public.take_class_register (uuid, uuid, public.attendance_status),
  public.admin_create_invoice (uuid, uuid, text, numeric, date, jsonb, text),
  public.admin_sell_credit_pack (uuid, uuid, int, numeric),
  public.record_payment (uuid, text, text),
  public.void_invoice (uuid),
  public.chase_invoice (uuid),
  public.update_payment_settings (uuid, text, text, text, int),
  public.admin_money_summary (uuid),
  public.admin_save_plan (uuid, uuid, text, numeric, int, int, text, boolean),
  public._membership_invoice (uuid, date),
  public.start_membership (uuid, uuid, uuid),
  public.cancel_membership (uuid),
  public.generate_membership_invoices (),
  public.mark_overdue_invoices ()
from public, anon, authenticated;

grant execute on function
  public.admin_save_class (uuid, uuid, text, text, int, time, time, int, uuid, uuid, int, int, numeric, numeric, boolean, numeric, text),
  public.admin_set_class_active (uuid, boolean),
  public.admin_cancel_class_session (uuid, boolean),
  public.get_classes (uuid),
  public.enrol_class (uuid, uuid),
  public.leave_class (uuid, uuid),
  public.book_class_trial (uuid, uuid, uuid),
  public.cancel_class_trial (uuid),
  public.get_class_register (uuid),
  public.take_class_register (uuid, uuid, public.attendance_status),
  public.admin_create_invoice (uuid, uuid, text, numeric, date, jsonb, text),
  public.admin_sell_credit_pack (uuid, uuid, int, numeric),
  public.record_payment (uuid, text, text),
  public.void_invoice (uuid),
  public.chase_invoice (uuid),
  public.update_payment_settings (uuid, text, text, text, int),
  public.admin_money_summary (uuid),
  public.admin_save_plan (uuid, uuid, text, numeric, int, int, text, boolean),
  public.start_membership (uuid, uuid, uuid),
  public.cancel_membership (uuid)
to authenticated, service_role;

grant execute on function
  public.ensure_class_sessions (uuid, int),
  public.generate_membership_invoices (),
  public.mark_overdue_invoices ()
to service_role;

-- ---------------------------------------------------------------------------
-- Cron (guarded for plain Postgres)
-- ---------------------------------------------------------------------------
do $cron$
begin
  perform cron.schedule('ignyte-membership-invoices', '0 6 1 * *', 'select public.generate_membership_invoices()');
  perform cron.schedule('ignyte-overdue-invoices', '15 6 * * *', 'select public.mark_overdue_invoices()');
  perform cron.schedule('ignyte-class-sessions', '0 3 * * 1', 'select public.ensure_class_sessions(null, 8)');
exception when others then
  raise notice 'pg_cron unavailable (%).', sqlerrm;
end;
$cron$;
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
-- ============================================================================
-- IGNYTE CLUB MANAGER — v9 "CLUB WEBSITES" (ADDITIVE — run after v8)
-- ----------------------------------------------------------------------------
-- Every club can run a real public website at /c/{slug} — home page, custom
-- pages (About, Teams, News…), the live class timetable, coaches, and an
-- enquiry form that lands in the club's admin inbox. JAM-Spirit-style sites,
-- built into the same platform that runs the club.
-- Included in the Club plan; available to Free/Privates clubs as the
-- 'website' add-on (owner toggles add-ons).
-- ============================================================================

alter table public.clubs
  add column if not exists addons text[] not null default '{}';

create or replace function public.has_website (p_club uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select plan in ('club', 'comped') or 'website' = any (addons) from clubs where id = p_club
$$;

create table public.club_pages (
  id uuid primary key default gen_random_uuid (),
  club_id uuid not null references public.clubs (id) on delete cascade,
  slug text not null check (slug ~ '^[a-z0-9][a-z0-9-]{0,29}$'),
  title text not null check (char_length(title) between 1 and 60),
  body text not null default '',
  sort int not null default 0,
  published boolean not null default false,
  updated_at timestamptz not null default now(),
  unique (club_id, slug)
);
create index club_pages_club_idx on public.club_pages (club_id, published, sort);

create table public.club_enquiries (
  id uuid primary key default gen_random_uuid (),
  club_id uuid not null references public.clubs (id) on delete cascade,
  name text not null,
  email text not null,
  message text,
  status text not null default 'new' check (status in ('new', 'contacted', 'closed')),
  created_at timestamptz not null default now()
);
create index club_enquiries_club_idx on public.club_enquiries (club_id, status);

alter table public.club_pages enable row level security;
alter table public.club_enquiries enable row level security;

create policy club_pages_admin on public.club_pages for select to authenticated
  using (is_admin_of(club_id));
create policy club_enquiries_admin_select on public.club_enquiries for select to authenticated
  using (is_admin_of(club_id));
create policy club_enquiries_admin_update on public.club_enquiries for update to authenticated
  using (is_admin_of(club_id)) with check (is_admin_of(club_id));

-- 'classes', 'coaches', 'contact' and 'join' are built-in site sections.
create or replace function public.save_club_page (
  p_club uuid, p_slug text, p_title text, p_body text,
  p_sort int default 0, p_published boolean default true
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not is_admin_of(p_club) then raise exception 'Admins only.'; end if;
  if not has_website(p_club) then
    raise exception 'The club website is part of the Club plan — or add the Website add-on. Ask Ignyte to switch it on.';
  end if;
  if lower(trim(p_slug)) in ('classes', 'coaches', 'contact', 'join', 'home') then
    raise exception '"%" is a built-in section — pick another address for this page.', p_slug;
  end if;
  if (select count(*) from club_pages where club_id = p_club) >= 12
     and not exists (select 1 from club_pages where club_id = p_club and slug = lower(trim(p_slug))) then
    raise exception 'A club site can have up to 12 custom pages.';
  end if;
  insert into club_pages (club_id, slug, title, body, sort, published)
  values (p_club, lower(trim(p_slug)), trim(p_title), coalesce(p_body, ''), coalesce(p_sort, 0), coalesce(p_published, true))
  on conflict (club_id, slug) do update set
    title = excluded.title, body = excluded.body, sort = excluded.sort,
    published = excluded.published, updated_at = now()
  returning id into v_id;
  perform owner_log(p_club, 'save_page', lower(trim(p_slug)));
  return v_id;
end;
$$;

create or replace function public.delete_club_page (p_club uuid, p_slug text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin_of(p_club) then raise exception 'Admins only.'; end if;
  delete from club_pages where club_id = p_club and slug = lower(trim(p_slug));
end;
$$;

-- Public enquiry form → the club's admin inbox (+ notifications).
create or replace function public.submit_club_enquiry (
  p_slug text, p_name text, p_email text, p_message text
) returns void language plpgsql security definer set search_path = public as $$
declare
  v_club clubs%rowtype;
  r record;
begin
  select * into v_club from clubs where slug = lower(trim(p_slug)) and status = 'active';
  if v_club.id is null then raise exception 'Club not found.'; end if;
  if char_length(trim(p_name)) < 2 or p_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'A name and a valid email are needed so the club can reply.';
  end if;
  if char_length(coalesce(p_message, '')) > 2000 then raise exception 'Message too long.'; end if;
  if (select count(*) from club_enquiries
      where club_id = v_club.id and created_at > now() - interval '1 hour') >= 20 then
    raise exception 'Too many enquiries right now — please try again later.';
  end if;
  insert into club_enquiries (club_id, name, email, message)
  values (v_club.id, trim(p_name), lower(trim(p_email)), nullif(trim(p_message), ''));
  for r in select profile_id from club_members
           where club_id = v_club.id and role = 'admin' and status = 'active' loop
    perform notify(r.profile_id, v_club.id, 'enquiry', 'New website enquiry 📬',
      trim(p_name) || ' asked about ' || v_club.name || ' — reply to ' || lower(trim(p_email)) || '.',
      '{}'::jsonb);
  end loop;
end;
$$;

create or replace function public.owner_set_addons (p_club uuid, p_addons text[])
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_owner() then raise exception 'Owner only.'; end if;
  update clubs set addons = coalesce(p_addons, '{}') where id = p_club;
  insert into owner_audit (club_id, action, detail) values (p_club, 'set_addons', array_to_string(p_addons, ','));
end;
$$;

-- Public portal payload now carries the website: published pages + flag.
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
       from class_groups g where g.club_id = c.id and g.active) as classes
    from clubs c where c.slug = lower(p_slug) and c.status = 'active' and c.searchable
  ) t
$$;

revoke execute on function
  public.has_website (uuid),
  public.save_club_page (uuid, text, text, text, int, boolean),
  public.delete_club_page (uuid, text),
  public.submit_club_enquiry (text, text, text, text),
  public.owner_set_addons (uuid, text[])
from public, anon, authenticated;

grant execute on function
  public.has_website (uuid),
  public.save_club_page (uuid, text, text, text, int, boolean),
  public.delete_club_page (uuid, text),
  public.owner_set_addons (uuid, text[])
to authenticated, service_role;

grant execute on function
  public.submit_club_enquiry (text, text, text, text)
to anon, authenticated, service_role;
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
-- ============================================================================
-- IGNYTE CLUB MANAGER — v11 "STARTER PACKAGE" (ADDITIVE — run after v10)
-- ----------------------------------------------------------------------------
-- £299 one-off, done-for-you onboarding: Ignyte builds the club's website,
-- wires the custom domain + mailbox, connects Stripe and migrates coaches,
-- families and existing sessions. Available with the Club plan, or with the
-- Website Pro add-on on Free & Small (i.e. club_has 'websitepro').
-- ============================================================================

alter table public.clubs
  add column if not exists starter_status text
    check (starter_status in ('requested', 'in_progress', 'done'));

create or replace function public.request_starter_package (p_club uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if not is_admin_of(p_club) then raise exception 'Admins only.'; end if;
  if not club_has(p_club, 'websitepro') then
    raise exception 'The Starter Package comes with the Club plan (£35/mo), or with the Website Pro add-on (£10/mo) on Free & Small.';
  end if;
  if (select starter_status from clubs where id = p_club) is not null then
    raise exception 'Starter Package already requested — Ignyte is on it.';
  end if;
  update clubs set starter_status = 'requested' where id = p_club;
  for r in select id from profiles where role = 'owner' loop
    perform notify(r.id, null, 'starter_request', '🚀 Starter Package request (£299)',
      (select name from clubs where id = p_club) || ' bought the done-for-you setup — site build, domain, Stripe, migration. Contact '
      || coalesce((select contact_email from clubs where id = p_club), 'the club admin') || ' to kick off.', '{}'::jsonb);
  end loop;
  insert into owner_audit (club_id, action, detail) values (p_club, 'starter_requested', '£299');
end;
$$;

create or replace function public.owner_set_starter_status (p_club uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if not is_owner() then raise exception 'Owner only.'; end if;
  if p_status not in ('requested', 'in_progress', 'done') then raise exception 'Bad status.'; end if;
  update clubs set starter_status = p_status where id = p_club;
  insert into owner_audit (club_id, action, detail) values (p_club, 'starter_status', p_status);
  if p_status = 'done' then
    for r in select profile_id from club_members
             where club_id = p_club and role = 'admin' and status = 'active' loop
      perform notify(r.profile_id, p_club, 'starter_done', '🚀 Your club is fully set up!',
        'Your Starter Package is complete — website live, payments connected, everyone imported. Over to you!', '{}'::jsonb);
    end loop;
  end if;
end;
$$;

revoke execute on function
  public.request_starter_package (uuid),
  public.owner_set_starter_status (uuid, text)
from public, anon, authenticated;

grant execute on function
  public.request_starter_package (uuid),
  public.owner_set_starter_status (uuid, text)
to authenticated, service_role;
-- ============================================================================
-- IGNYTE CLUB MANAGER — v12 "CLUB SHOP" (ADDITIVE — run after v11)
-- ----------------------------------------------------------------------------
-- Kit, uniforms and merch — part of the FREE tier. Products with options
-- (sizes) and optional stock tracking; members order in-app. Clubs with the
-- money module get an invoice per order automatically (pay online, 0% fees);
-- Free clubs take payment at the desk and mark orders paid. The public club
-- website gets a Shop section.
-- ============================================================================

create table public.shop_products (
  id uuid primary key default gen_random_uuid (),
  club_id uuid not null references public.clubs (id) on delete cascade,
  name text not null check (char_length(name) between 2 and 80),
  description text,
  price numeric(8, 2) not null check (price >= 0),
  options text[] not null default '{}', -- e.g. sizes: {Age 5-6, Age 7-8, Adult S}
  image_url text check (image_url is null or image_url ~ '^https://'),
  stock int check (stock is null or stock >= 0), -- null = not tracked
  active boolean not null default true,
  sort int not null default 0,
  created_at timestamptz not null default now()
);
create index shop_products_club_idx on public.shop_products (club_id, active, sort);

create table public.shop_orders (
  id uuid primary key default gen_random_uuid (),
  club_id uuid not null references public.clubs (id) on delete cascade,
  product_id uuid references public.shop_products (id) on delete set null,
  product_name text not null,
  option_choice text,
  qty int not null check (qty between 1 and 20),
  unit_price numeric(8, 2) not null,
  amount numeric(10, 2) not null,
  buyer_id uuid not null references public.profiles (id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'paid', 'collected', 'cancelled')),
  invoice_id uuid references public.invoices (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index shop_orders_club_idx on public.shop_orders (club_id, status, created_at desc);
create index shop_orders_buyer_idx on public.shop_orders (buyer_id);

alter table public.shop_products enable row level security;
alter table public.shop_orders enable row level security;

create policy shop_products_select on public.shop_products for select to authenticated
  using (club_id in (select my_club_ids()));
create policy shop_orders_select on public.shop_orders for select to authenticated
  using ((club_id in (select my_club_ids())) and (buyer_id = auth.uid() or is_admin_of(club_id)));

-- invoices grow a 'shop' source
alter table public.invoices drop constraint invoices_source_check;
alter table public.invoices add constraint invoices_source_check
  check (source in ('manual', 'membership', 'credit_pack', 'trial', 'lessons', 'class', 'shop'));

-- 'shop' becomes a built-in site section
create or replace function public.save_club_page (
  p_club uuid, p_slug text, p_title text, p_body text,
  p_sort int default 0, p_published boolean default true
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not is_admin_of(p_club) then raise exception 'Admins only.'; end if;
  if not has_website(p_club) then
    raise exception 'The club website is part of the Club plan — or add the Website add-on. Ask Ignyte to switch it on.';
  end if;
  if lower(trim(p_slug)) in ('classes', 'coaches', 'contact', 'join', 'home', 'shop') then
    raise exception '"%" is a built-in section — pick another address for this page.', p_slug;
  end if;
  if (select count(*) from club_pages where club_id = p_club) >= 12
     and not exists (select 1 from club_pages where club_id = p_club and slug = lower(trim(p_slug))) then
    raise exception 'A club site can have up to 12 custom pages.';
  end if;
  insert into club_pages (club_id, slug, title, body, sort, published)
  values (p_club, lower(trim(p_slug)), trim(p_title), coalesce(p_body, ''), coalesce(p_sort, 0), coalesce(p_published, true))
  on conflict (club_id, slug) do update set
    title = excluded.title, body = excluded.body, sort = excluded.sort,
    published = excluded.published, updated_at = now()
  returning id into v_id;
  perform owner_log(p_club, 'save_page', lower(trim(p_slug)));
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------
create or replace function public.admin_save_product (
  p_club uuid, p_id uuid, p_name text, p_price numeric,
  p_description text default null, p_options text[] default '{}',
  p_image_url text default null, p_stock int default null,
  p_active boolean default true, p_sort int default 0
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid := p_id;
begin
  if not is_admin_of(p_club) then raise exception 'Only club admins can manage the shop.'; end if;
  if v_id is null then
    insert into shop_products (club_id, name, description, price, options, image_url, stock, active, sort)
    values (p_club, trim(p_name), p_description, round(p_price, 2), coalesce(p_options, '{}'),
            nullif(trim(coalesce(p_image_url, '')), ''), p_stock, p_active, coalesce(p_sort, 0))
    returning id into v_id;
  else
    update shop_products set name = trim(p_name), description = p_description,
      price = round(p_price, 2), options = coalesce(p_options, '{}'),
      image_url = nullif(trim(coalesce(p_image_url, '')), ''), stock = p_stock,
      active = p_active, sort = coalesce(p_sort, 0)
    where id = v_id and club_id = p_club;
    if not found then raise exception 'Product not found.'; end if;
  end if;
  perform owner_log(p_club, 'save_product', trim(p_name));
  return v_id;
end;
$$;

create or replace function public.place_shop_order (p_product uuid, p_option text default null, p_qty int default 1)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_p shop_products%rowtype;
  v_id uuid;
  v_inv uuid;
  v_due int;
  v_symbol text;
  r record;
begin
  select * into v_p from shop_products where id = p_product for update;
  if v_p.id is null or not v_p.active then raise exception 'That item isn''t available.'; end if;
  perform assert_club_active(v_p.club_id);
  if not exists (select 1 from club_members
      where club_id = v_p.club_id and profile_id = auth.uid() and status = 'active') then
    raise exception 'Join this club to order from its shop.';
  end if;
  if p_qty < 1 or p_qty > 20 then raise exception 'Quantity must be between 1 and 20.'; end if;
  if cardinality(v_p.options) > 0 and (p_option is null or not (p_option = any (v_p.options))) then
    raise exception 'Pick a size/option first.';
  end if;
  if v_p.stock is not null then
    if v_p.stock < p_qty then raise exception 'Only % left in stock.', v_p.stock; end if;
    update shop_products set stock = stock - p_qty where id = p_product;
  end if;

  insert into shop_orders (club_id, product_id, product_name, option_choice, qty, unit_price, amount, buyer_id)
  values (v_p.club_id, p_product, v_p.name, p_option, p_qty, v_p.price, round(v_p.price * p_qty, 2), auth.uid())
  returning id into v_id;

  select currency, invoice_due_days into v_symbol, v_due from club_settings where club_id = v_p.club_id;
  if club_has(v_p.club_id, 'privates') and v_p.price > 0 then
    insert into invoices (club_id, profile_id, description, amount, due_date, source, meta, created_by)
    values (v_p.club_id, auth.uid(),
            'Shop — ' || v_p.name || coalesce(' (' || p_option || ')', '') || ' × ' || p_qty,
            round(v_p.price * p_qty, 2), current_date + coalesce(v_due, 7),
            'shop', jsonb_build_object('order_id', v_id), auth.uid())
    returning id into v_inv;
    update shop_orders set invoice_id = v_inv where id = v_id;
  end if;

  perform notify(auth.uid(), v_p.club_id, 'shop_order', 'Order placed 🛍️',
    v_p.name || coalesce(' (' || p_option || ')', '') || ' × ' || p_qty || ' — '
    || coalesce(v_symbol, '£') || round(v_p.price * p_qty, 2)
    || case when v_inv is not null then '. Pay from your Money page; collect at the club.'
            else '. Pay at the club when you collect.' end,
    jsonb_build_object('order_id', v_id));
  for r in select profile_id from club_members
           where club_id = v_p.club_id and role = 'admin' and status = 'active' loop
    perform notify(r.profile_id, v_p.club_id, 'shop_order', 'New shop order',
      (select full_name from profiles where id = auth.uid()) || ' ordered ' || v_p.name
      || coalesce(' (' || p_option || ')', '') || ' × ' || p_qty || '.',
      jsonb_build_object('order_id', v_id));
  end loop;
  return jsonb_build_object('order_id', v_id, 'invoiced', v_inv is not null);
end;
$$;

create or replace function public.cancel_shop_order (p_order uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_o shop_orders%rowtype;
begin
  select * into v_o from shop_orders where id = p_order for update;
  if v_o.id is null then raise exception 'Order not found.'; end if;
  if not (v_o.buyer_id = auth.uid() or is_admin_of(v_o.club_id)) then
    raise exception 'Not your order.';
  end if;
  if v_o.status <> 'pending' then raise exception 'Only pending orders can be cancelled — ask the club.'; end if;
  update shop_orders set status = 'cancelled', updated_at = now() where id = p_order;
  if v_o.product_id is not null then
    update shop_products set stock = stock + v_o.qty where id = v_o.product_id and stock is not null;
  end if;
  if v_o.invoice_id is not null then
    update invoices set status = 'void' where id = v_o.invoice_id and status in ('due', 'overdue');
  end if;
end;
$$;

create or replace function public.admin_set_order_status (p_order uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare v_o shop_orders%rowtype;
begin
  select * into v_o from shop_orders where id = p_order for update;
  if v_o.id is null then raise exception 'Order not found.'; end if;
  if not is_admin_of(v_o.club_id) then raise exception 'Only club admins can manage orders.'; end if;
  if p_status not in ('paid', 'collected', 'cancelled') then raise exception 'Bad status.'; end if;
  if p_status = 'cancelled' then perform cancel_shop_order(p_order); return; end if;
  update shop_orders set status = p_status, updated_at = now() where id = p_order;
  if p_status = 'paid' and v_o.invoice_id is not null then
    perform _settle_invoice(v_o.invoice_id, 'cash', 'shop order');
  end if;
  perform notify(v_o.buyer_id, v_o.club_id, 'shop_order',
    case p_status when 'paid' then 'Order paid ✅' else 'Ready — collected! 🛍️' end,
    v_o.product_name || coalesce(' (' || v_o.option_choice || ')', '') || ' × ' || v_o.qty
    || case p_status when 'paid' then ' is marked paid.' else ' is marked collected. Enjoy!' end,
    jsonb_build_object('order_id', p_order));
end;
$$;

-- Paying the linked invoice (online or recorded) marks the order paid.
create or replace function public.sync_shop_order_paid () returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'paid' and old.status <> 'paid' then
    update shop_orders set status = 'paid', updated_at = now()
      where invoice_id = new.id and status = 'pending';
  end if;
  return new;
end;
$$;
drop trigger if exists invoices_shop_sync on public.invoices;
create trigger invoices_shop_sync after update of status on public.invoices
  for each row execute function public.sync_shop_order_paid ();

-- Public site: the shop window.
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
       from shop_products sp where sp.club_id = c.id and sp.active) as shop
    from clubs c where c.slug = lower(p_slug) and c.status = 'active' and c.searchable
  ) t
$$;

revoke execute on function
  public.admin_save_product (uuid, uuid, text, numeric, text, text[], text, int, boolean, int),
  public.place_shop_order (uuid, text, int),
  public.cancel_shop_order (uuid),
  public.admin_set_order_status (uuid, text)
from public, anon, authenticated;

grant execute on function
  public.admin_save_product (uuid, uuid, text, numeric, text, text[], text, int, boolean, int),
  public.place_shop_order (uuid, text, int),
  public.cancel_shop_order (uuid),
  public.admin_set_order_status (uuid, text)
to authenticated, service_role;
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
-- ============================================================================
-- IGNYTE CLUB MANAGER — v14 "THE CLUB'S FRONT DOOR" (ADDITIVE — run after v13)
-- ----------------------------------------------------------------------------
-- The club's URL becomes its front door: /c/{slug}/join and /c/{slug}/login
-- (or theirclub.co.uk/join) carry the club's branding, and signing up there
-- attaches the family to that club automatically — no code to type. Clubs
-- choose whether link sign-ups are instant (open_join, default) or need
-- approval. Join codes still work as a fallback for posters etc.
-- ============================================================================

alter table public.club_settings
  add column if not exists open_join boolean not null default true;

create or replace function public.set_open_join (p_club uuid, p_open boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin_of(p_club) then raise exception 'Admins only.'; end if;
  update club_settings set open_join = coalesce(p_open, true) where club_id = p_club;
  perform owner_log(p_club, 'set_open_join', p_open::text);
end;
$$;

-- Joining via the club link: instant when the club is open, pending otherwise.
create or replace function public.request_join (p_slug text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_club clubs%rowtype;
  v_role club_role;
  v_open boolean;
  r record;
begin
  select * into v_club from clubs where slug = lower(trim(p_slug)) and status = 'active';
  if v_club.id is null then raise exception 'Club not found.'; end if;
  if exists (select 1 from club_members where club_id = v_club.id and profile_id = auth.uid() and status = 'active') then
    return jsonb_build_object('status', 'active', 'club_id', v_club.id);
  end if;
  v_role := case when (select role from profiles where id = auth.uid()) = 'athlete' then 'athlete'::club_role else 'parent' end;
  select coalesce(open_join, true) into v_open from club_settings where club_id = v_club.id;

  if v_open then
    insert into club_members (club_id, profile_id, role, status)
    values (v_club.id, auth.uid(), v_role, 'active')
    on conflict (club_id, profile_id) do update set status = 'active'
      where club_members.status <> 'active';
    update profiles set last_club_id = v_club.id where id = auth.uid();
    return jsonb_build_object('status', 'active', 'club_id', v_club.id);
  end if;

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

-- Signup trigger: club-link signups honour open_join; admins are told about
-- pending ones. Code signups stay instant.
create or replace function public.handle_new_user () returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_role user_role := 'parent';
  v_dob date;
  v_club uuid;
  v_open boolean;
  r record;
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
      select c.id, coalesce(s.open_join, true) into v_club, v_open
        from clubs c left join club_settings s on s.club_id = c.id
        where c.slug = lower(new.raw_user_meta_data ->> 'join_slug') and c.status = 'active';
      if v_club is not null then
        insert into club_members (club_id, profile_id, role, status)
        values (v_club, new.id,
                case when v_role = 'athlete' then 'athlete'::club_role else 'parent' end,
                case when v_open then 'active'::member_status else 'pending' end)
        on conflict do nothing;
        if v_open then
          update profiles set last_club_id = v_club where id = new.id;
        else
          for r in select profile_id from club_members
                   where club_id = v_club and role = 'admin' and status = 'active' loop
            perform notify(r.profile_id, v_club, 'join_request', 'New join request',
              coalesce(nullif(new.raw_user_meta_data ->> 'full_name', ''), new.email)
              || ' signed up via your club link — approve them in Admin → People.',
              jsonb_build_object('profile_id', new.id));
          end loop;
        end if;
      end if;
    end if;
  exception when others then null;
  end;
  return new;
end;
$$;

-- The public payload says whether joining is instant (for honest button copy).
create or replace function public.get_club_public (p_slug text) returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(t) from (
    select c.name, c.slug, c.blurb, c.logo_path, c.accent_color, c.status,
      has_website(c.id) as website,
      coalesce((select open_join from club_settings where club_id = c.id), true) as open_join,
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

revoke execute on function public.set_open_join (uuid, boolean) from public, anon, authenticated;
grant execute on function public.set_open_join (uuid, boolean) to authenticated, service_role;
-- ============================================================================
-- IGNYTE CLUB MANAGER — v15 "FOUNDERS & PROMOS" (ADDITIVE — run after v14)
-- ----------------------------------------------------------------------------
--   1. PROMO CODES — owner-managed discount codes for club sign-ups
--      (e.g. CHEER50 = 50% off for 3 months). Clubs enter them in the
--      start-a-club wizard; the code is validated, counted, recorded on the
--      club and surfaced in Owner HQ so billing honours it.
--   2. FOUNDER SIGNUP — provision_club accepts the promo; the /start page
--      now creates the founder's account and the club in one flow.
-- ============================================================================

create table public.platform_promos (
  code text primary key check (code ~ '^[A-Z0-9-]{3,20}$'),
  description text,
  percent_off int not null check (percent_off between 1 and 100),
  duration_months int not null default 3 check (duration_months between 1 and 24),
  max_uses int check (max_uses > 0),
  uses int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.platform_promos enable row level security;
create policy promos_owner on public.platform_promos for select to authenticated using (is_owner());

alter table public.clubs add column if not exists promo_code text;

-- Anyone can check a code while signing up (returns nothing sensitive).
create or replace function public.check_promo (p_code text) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((
    select jsonb_build_object('valid', true, 'code', code, 'percent_off', percent_off,
      'duration_months', duration_months, 'description', description)
    from platform_promos
    where code = upper(trim(p_code)) and active
      and (max_uses is null or uses < max_uses)
  ), jsonb_build_object('valid', false))
$$;

create or replace function public.owner_save_promo (
  p_code text, p_percent int, p_months int default 3,
  p_description text default null, p_max_uses int default null, p_active boolean default true
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_owner() then raise exception 'Owner only.'; end if;
  insert into platform_promos (code, percent_off, duration_months, description, max_uses, active)
  values (upper(trim(p_code)), p_percent, p_months, p_description, p_max_uses, p_active)
  on conflict (code) do update set percent_off = excluded.percent_off,
    duration_months = excluded.duration_months, description = excluded.description,
    max_uses = excluded.max_uses, active = excluded.active;
  insert into owner_audit (action, detail) values ('save_promo', upper(trim(p_code)));
end;
$$;

-- provision_club learns the promo (replaces the 5-arg version).
drop function if exists public.provision_club (text, text, text, text[], text);
create or replace function public.provision_club (
  p_name text, p_slug text, p_timezone text default 'Europe/London',
  p_disciplines text[] default array['tumble', 'dance'], p_location text default 'Main venue',
  p_promo text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_club uuid;
  v_promo platform_promos%rowtype;
  r record;
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;

  if nullif(trim(coalesce(p_promo, '')), '') is not null then
    select * into v_promo from platform_promos
      where code = upper(trim(p_promo)) and active
        and (max_uses is null or uses < max_uses);
    if v_promo.code is null then raise exception 'That discount code isn''t valid.'; end if;
  end if;

  -- a 100%-off code means fully comped: every module unlocked from signup
  insert into clubs (name, slug, contact_name, contact_email, promo_code, plan)
  values (trim(p_name), lower(trim(p_slug)),
    (select full_name from profiles where id = auth.uid()),
    (select email from profiles where id = auth.uid()),
    v_promo.code,
    case when v_promo.percent_off = 100 then 'comped' else 'free' end)
  returning id into v_club;
  insert into club_settings (club_id, timezone, disciplines) values (v_club, p_timezone, p_disciplines);
  insert into club_members (club_id, profile_id, role, status) values (v_club, auth.uid(), 'admin', 'active');
  insert into locations (club_id, name) values (v_club, coalesce(nullif(trim(p_location), ''), 'Main venue'));
  insert into skills (club_id, discipline, category, name, level, sort)
    select v_club, discipline, category, name, level, sort from skills where club_id is null;
  update profiles set last_club_id = v_club where id = auth.uid();

  if v_promo.code is not null then
    update platform_promos set uses = uses + 1 where code = v_promo.code;
    for r in select id from profiles where role = 'owner' loop
      perform notify(r.id, null, 'promo_used', '🏷️ Promo used on sign-up',
        trim(p_name) || ' signed up with ' || v_promo.code || ' (' || v_promo.percent_off
        || '% off for ' || v_promo.duration_months || ' months).', '{}'::jsonb);
    end loop;
  end if;

  insert into owner_audit (club_id, action, detail)
  values (v_club, 'club_provisioned', trim(p_name) || coalesce(' [' || v_promo.code || ']', ''));
  return jsonb_build_object('club_id', v_club, 'slug', lower(trim(p_slug)),
    'join_code', (select join_code from clubs where id = v_club));
end;
$$;

revoke execute on function
  public.check_promo (text),
  public.owner_save_promo (text, int, int, text, int, boolean),
  public.provision_club (text, text, text, text[], text, text)
from public, anon, authenticated;

grant execute on function public.check_promo (text) to anon, authenticated, service_role;
grant execute on function public.owner_save_promo (text, int, int, text, int, boolean) to authenticated, service_role;
grant execute on function public.provision_club (text, text, text, text[], text, text) to authenticated, service_role;
