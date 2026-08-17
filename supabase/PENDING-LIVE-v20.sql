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
