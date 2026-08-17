-- ============================================================================
-- SEED: a 1-2-1-ONLY demo customer — "Storm 1-2-1 Academy"
-- ----------------------------------------------------------------------------
-- A free-plan club whose package is exactly {privates}, so every user in it
-- sees only the 1-2-1 experience. Reuses existing confirmed test accounts as
-- admin / coach / parent (no auth-user creation needed). Idempotent by slug.
--   admin  : smithy.ns83+club@gmail.com
--   coach  : smithy.ns83+coach@gmail.com
--   parent : smithy.ns83+probe1@gmail.com
-- ============================================================================
do $$
declare
  v_admin  uuid := (select id from auth.users where email = 'smithy.ns83+club@gmail.com');
  v_coach  uuid := (select id from auth.users where email = 'smithy.ns83+coach@gmail.com');
  v_parent uuid := (select id from auth.users where email = 'smithy.ns83+probe1@gmail.com');
  v_club uuid;
  v_loc uuid;
  v_ath uuid;
  v_series uuid := gen_random_uuid();
  i int;
  v_date date;
begin
  if v_admin is null or v_coach is null or v_parent is null then
    raise exception 'Base test accounts missing (need +club, +coach, +probe1).';
  end if;

  select id into v_club from clubs where slug = 'storm-121';
  if v_club is null then
    insert into clubs (name, slug, plan, addons, contact_name, contact_email)
    values ('Storm 1-2-1 Academy', 'storm-121', 'free', '{privates}',
            (select full_name from profiles where id = v_admin), 'smithy.ns83+club@gmail.com')
    returning id into v_club;
    insert into club_settings (club_id, timezone, disciplines) values (v_club, 'Europe/London', '{tumble,dance}');
    insert into locations (club_id, name) values (v_club, 'Storm Gym') returning id into v_loc;
    insert into skills (club_id, discipline, category, name, level, sort)
      select v_club, discipline, category, name, level, sort from skills where club_id is null;
  else
    select id into v_loc from locations where club_id = v_club order by created_at limit 1;
  end if;

  insert into club_members (club_id, profile_id, role, status) values
    (v_club, v_admin,  'admin',  'active'),
    (v_club, v_coach,  'coach',  'active'),
    (v_club, v_parent, 'parent', 'active')
  on conflict (club_id, profile_id) do update set role = excluded.role, status = 'active';

  insert into coach_profiles (club_id, coach_id, disciplines, rate_per_lesson)
    values (v_club, v_coach, '{tumble,dance}', 20)
    on conflict (club_id, coach_id) do nothing;

  select id into v_ath from athletes where parent_id = v_parent and name = 'Storm Junior';
  if v_ath is null then
    insert into athletes (parent_id, name, dob, medical_notes)
    values (v_parent, 'Storm Junior', '2014-06-01', 'Mild asthma — inhaler in kit bag.')
    returning id into v_ath;
  end if;
  insert into athlete_enrolments (athlete_id, club_id) values (v_ath, v_club) on conflict do nothing;

  -- six weekly Tuesday slots, coach attached
  if not exists (select 1 from slots where club_id = v_club) then
    for i in 0..5 loop
      v_date := current_date + ((2 - extract(dow from current_date)::int + 7) % 7) + i * 7;
      insert into slots (club_id, slot_date, start_time, end_time, capacity, series_id, location_id, created_by)
      values (v_club, v_date, '17:00', '17:30', 2, v_series, v_loc, v_admin);
    end loop;
    insert into slot_coaches (slot_id, coach_id) select s.id, v_coach from slots s where s.club_id = v_club;
  end if;

  update profiles set last_club_id = v_club where id in (v_admin, v_coach, v_parent);
  raise notice 'Storm 1-2-1 seeded: %', v_club;
end $$;

-- Tidy up the stray test club from earlier pricing testing.
update clubs set status = 'churned' where slug = 'pricing-test-club';
