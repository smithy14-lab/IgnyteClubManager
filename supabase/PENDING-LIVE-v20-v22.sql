-- ============================================================================
-- IGNYTE CLUB MANAGER — v20 "PARENT ATHLETE MANAGEMENT" (run after v19_2)
-- ----------------------------------------------------------------------------
-- Parents/athletes create & edit athletes (their children, or themselves) via
-- a SECURITY DEFINER RPC instead of a raw client insert. Direct client inserts
-- into athletes were being refused by RLS on the live project, so every athlete
-- had only ever been created through the admin import RPC. This gives families
-- a first-class, reliable path — add a child, add yourself ("I train here too"),
-- edit details — with ownership enforced and enrolment (cap-gated) handled.
-- ============================================================================

create or replace function public.save_athlete (
  p_club uuid,
  p_id uuid,
  p_name text,
  p_dob date,
  p_notes text default null,
  p_medical text default null,
  p_consent boolean default false,
  p_self boolean default false
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
begin
  if v_uid is null then raise exception 'Sign in first.'; end if;
  if nullif(trim(coalesce(p_name, '')), '') is null then raise exception 'A name is required.'; end if;
  if p_dob is null then raise exception 'A date of birth is required.'; end if;

  if p_id is not null then
    -- edit an athlete you own (your child or yourself)
    if not owns_athlete(p_id) then raise exception 'That is not your athlete.'; end if;
    update athletes set
      name = trim(p_name), dob = p_dob,
      notes = nullif(trim(coalesce(p_notes, '')), ''),
      medical_notes = nullif(trim(coalesce(p_medical, '')), ''),
      media_consent = coalesce(p_consent, false)
    where id = p_id
    returning id into v_id;
  elsif p_self then
    -- "I train here too" — one self-athlete per person
    select id into v_id from athletes where profile_id = v_uid;
    if v_id is null then
      insert into athletes (parent_id, profile_id, name, dob, notes, medical_notes, media_consent)
      values (v_uid, v_uid, trim(p_name), p_dob,
        nullif(trim(coalesce(p_notes, '')), ''), nullif(trim(coalesce(p_medical, '')), ''), coalesce(p_consent, false))
      returning id into v_id;
    end if;
  else
    -- add a child
    insert into athletes (parent_id, name, dob, notes, medical_notes, media_consent)
    values (v_uid, trim(p_name), p_dob,
      nullif(trim(coalesce(p_notes, '')), ''), nullif(trim(coalesce(p_medical, '')), ''), coalesce(p_consent, false))
    returning id into v_id;
  end if;

  -- enrol at the club (idempotent; the free/small athlete cap trigger still applies)
  if p_club is not null then
    insert into athlete_enrolments (athlete_id, club_id) values (v_id, p_club) on conflict do nothing;
  end if;

  return v_id;
end;
$$;

revoke execute on function public.save_athlete (uuid, uuid, text, date, text, text, boolean, boolean) from public, anon;
grant execute on function public.save_athlete (uuid, uuid, text, date, text, text, boolean, boolean) to authenticated, service_role;

-- Defensive: re-assert the athletes insert policy (in case the live copy drifted).
drop policy if exists athletes_insert on public.athletes;
create policy athletes_insert on public.athletes for insert to authenticated
  with check (parent_id = auth.uid() or profile_id = auth.uid() or is_owner());
-- ============================================================================
-- IGNYTE CLUB MANAGER — v21 "COACH MANUAL ASSIGN" (run after v20)
-- ----------------------------------------------------------------------------
-- A coach can manually book an athlete into a slot they're on (e.g. a walk-in
-- or a lesson arranged offline). Booking normally requires owning the athlete
-- or being an admin; this gives assigned coaches a first-class path, with the
-- coach set as the lesson's coach and notice cut-offs skipped (staff action).
-- ============================================================================

create or replace function public.coach_book_athlete (p_slot uuid, p_athlete uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_slot slots%rowtype;
  v_uid uuid := auth.uid();
  v_bid uuid;
  v_athlete text;
begin
  if v_uid is null then raise exception 'Sign in first.'; end if;
  select * into v_slot from slots where id = p_slot;
  if v_slot.id is null then raise exception 'Slot not found.'; end if;
  if not is_coach_of(v_slot.club_id) then raise exception 'Coaches only.'; end if;
  if not exists (select 1 from slot_coaches where slot_id = p_slot and coach_id = v_uid) then
    raise exception 'You are not on this slot — join it first.';
  end if;
  if not athlete_in_club(p_athlete, v_slot.club_id) then
    raise exception 'That athlete is not enrolled at this club.';
  end if;

  v_bid := _create_booking(p_slot, p_athlete, v_uid, v_uid, null, true);
  select name into v_athlete from athletes where id = p_athlete;
  perform notify(v_uid, v_slot.club_id, 'booking_confirmed', 'Lesson assigned',
    'You booked ' || coalesce(v_athlete, 'an athlete') || ' into your '
    || to_char(v_slot.slot_date, 'FMDay DD Mon') || ' ' || to_char(v_slot.start_time, 'HH24:MI') || ' slot.',
    jsonb_build_object('slot_id', p_slot));
  return v_bid;
end;
$$;

revoke execute on function public.coach_book_athlete (uuid, uuid) from public, anon;
grant execute on function public.coach_book_athlete (uuid, uuid) to authenticated, service_role;
-- ============================================================================
-- IGNYTE CLUB MANAGER — v22 "ADMIN EDIT PERSON" (run after v21)
-- ----------------------------------------------------------------------------
-- Club admins can update a member's contact details (name & phone) — e.g. fix
-- a typo in a parent's or coach's info. Profiles are otherwise self-edit only;
-- this gives admins a scoped path for members of their own club.
-- ============================================================================

create or replace function public.admin_update_person (p_club uuid, p_profile uuid, p_name text, p_phone text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin_of(p_club) then raise exception 'Admins only.'; end if;
  if not exists (select 1 from club_members where club_id = p_club and profile_id = p_profile and status = 'active') then
    raise exception 'That person is not a member of this club.';
  end if;
  update profiles set
    full_name = coalesce(nullif(trim(p_name), ''), full_name),
    phone = nullif(trim(coalesce(p_phone, '')), '')
  where id = p_profile;
  perform owner_log(p_club, 'update_person', p_profile::text);
end;
$$;

revoke execute on function public.admin_update_person (uuid, uuid, text, text) from public, anon;
grant execute on function public.admin_update_person (uuid, uuid, text, text) to authenticated, service_role;
