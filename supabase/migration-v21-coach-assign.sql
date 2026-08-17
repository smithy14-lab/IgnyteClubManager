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
