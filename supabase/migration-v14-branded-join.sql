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
