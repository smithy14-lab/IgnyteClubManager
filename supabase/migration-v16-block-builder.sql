-- ============================================================================
-- IGNYTE CLUB MANAGER — v16 "SECTION BUILDER" (ADDITIVE — run after v15)
-- ----------------------------------------------------------------------------
-- Wix-style block pages: a page is a stack of sections (hero, text, image,
-- gallery, buttons — plus LIVE sections: timetable, coaches, events, shop,
-- contact form). Clubs can now also build their own HOME page. Legacy
-- markdown pages keep working (blocks null = old body).
-- ============================================================================

alter table public.club_pages add column if not exists blocks jsonb;

drop function if exists public.save_club_page (uuid, text, text, text, int, boolean);
create or replace function public.save_club_page (
  p_club uuid, p_slug text, p_title text, p_body text default '',
  p_sort int default 0, p_published boolean default true, p_blocks jsonb default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  b jsonb;
begin
  if not is_admin_of(p_club) then raise exception 'Admins only.'; end if;
  if not has_website(p_club) then
    raise exception 'The club website is part of the Club plan — or add the Website add-on. Ask Ignyte to switch it on.';
  end if;
  -- 'home' is now buildable; these stay built-in sections
  if lower(trim(p_slug)) in ('classes', 'coaches', 'contact', 'join', 'shop', 'login', 'signup') then
    raise exception '"%" is a built-in section — pick another address for this page.', p_slug;
  end if;
  if p_blocks is not null then
    if jsonb_typeof(p_blocks) <> 'array' then raise exception 'Bad page content.'; end if;
    if jsonb_array_length(p_blocks) > 24 then raise exception 'A page can have up to 24 sections.'; end if;
    if pg_column_size(p_blocks) > 200000 then raise exception 'This page is too heavy — trim some content.'; end if;
    for b in select * from jsonb_array_elements(p_blocks) loop
      if b ->> 'type' not in ('hero', 'text', 'image', 'image_text', 'gallery', 'cta',
                              'timetable', 'coaches', 'events', 'shop', 'contact') then
        raise exception 'Unknown section type "%".', b ->> 'type';
      end if;
    end loop;
  end if;
  if (select count(*) from club_pages where club_id = p_club) >= 12
     and not exists (select 1 from club_pages where club_id = p_club and slug = lower(trim(p_slug))) then
    raise exception 'A club site can have up to 12 pages.';
  end if;
  insert into club_pages (club_id, slug, title, body, sort, published, blocks)
  values (p_club, lower(trim(p_slug)), trim(p_title), coalesce(p_body, ''), coalesce(p_sort, 0), coalesce(p_published, true), p_blocks)
  on conflict (club_id, slug) do update set
    title = excluded.title, body = excluded.body, sort = excluded.sort,
    published = excluded.published, blocks = excluded.blocks, updated_at = now()
  returning id into v_id;
  perform owner_log(p_club, 'save_page', lower(trim(p_slug)));
  return v_id;
end;
$$;

-- public payload: pages carry their blocks
create or replace function public.get_club_public (p_slug text) returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(t) from (
    select c.name, c.slug, c.blurb, c.logo_path, c.accent_color, c.status,
      has_website(c.id) as website,
      coalesce((select open_join from club_settings where club_id = c.id), true) as open_join,
      (select coalesce(jsonb_agg(jsonb_build_object('slug', pg.slug, 'title', pg.title, 'body', pg.body, 'blocks', pg.blocks) order by pg.sort, pg.title), '[]'::jsonb)
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

revoke execute on function public.save_club_page (uuid, text, text, text, int, boolean, jsonb) from public, anon, authenticated;
grant execute on function public.save_club_page (uuid, text, text, text, int, boolean, jsonb) to authenticated, service_role;
