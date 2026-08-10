-- ============================================================================
-- IGNYTE CLUB MANAGER — v19_1 HOTFIX (run after v19)
-- ----------------------------------------------------------------------------
-- book_slot: the discipline check used `= any ((select disciplines ...))`.
-- With a subquery, ANY compares against each returned ROW (a text[]), not the
-- array's elements, so every booking with a discipline died with
-- "operator does not exist: text = text[]". Found by the automated family
-- booking drive — first ever real family booking. Resolve the array into a
-- variable first.
-- ============================================================================

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
    select disciplines into v_ds from club_settings where club_id = v_slot.club_id;
    if not (p_discipline = 'both' or p_discipline = any (coalesce(v_ds, '{}'))) then
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
