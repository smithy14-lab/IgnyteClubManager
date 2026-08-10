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
-- ============================================================================
-- IGNYTE CLUB MANAGER — v17 "ONE-PAGE FREE SITES" (ADDITIVE — run after v16)
-- ----------------------------------------------------------------------------
-- Free tier: a one-page website (typically the buildable home page — live
-- timetable/shop/contact sections included, so it's still a real site).
-- Website Pro (£10/mo) or the Club plan unlocks up to 12 pages.
-- ============================================================================

create or replace function public.save_club_page (
  p_club uuid, p_slug text, p_title text, p_body text default '',
  p_sort int default 0, p_published boolean default true, p_blocks jsonb default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_cap int;
  b jsonb;
begin
  if not is_admin_of(p_club) then raise exception 'Admins only.'; end if;
  if not has_website(p_club) then
    raise exception 'The club website is part of the Club plan — or add the Website add-on. Ask Ignyte to switch it on.';
  end if;
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
  v_cap := case when club_has(p_club, 'websitepro') then 12 else 1 end;
  if (select count(*) from club_pages where club_id = p_club) >= v_cap
     and not exists (select 1 from club_pages where club_id = p_club and slug = lower(trim(p_slug))) then
    raise exception 'The free website is one page — Website Pro (£10/mo) or the Club plan (£35/mo) unlocks up to 12.';
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

revoke execute on function public.save_club_page (uuid, text, text, text, int, boolean, jsonb) from public, anon, authenticated;
grant execute on function public.save_club_page (uuid, text, text, text, int, boolean, jsonb) to authenticated, service_role;
-- ============================================================================
-- IGNYTE CLUB MANAGER — v18 "BUILD YOUR OWN PACKAGE" (ADDITIVE — run after v17)
-- ----------------------------------------------------------------------------
-- Pricing goes modular. Free is the base; clubs tick the modules they want at
-- £8/mo each — Privates, Memberships & billing, Website Pro — instead of a
-- fixed "Small" bundle. Any module lifts the athlete cap from 30 to 100;
-- Club (£35/mo) stays the everything plan with unlimited athletes.
-- No schema changes: club_has() has been module-shaped since v10. This
-- updates the athlete cap to count modules, and rewords every gate message
-- to point at the module picker instead of the old Small tier / £10 add-ons.
-- (The 'small' plan value stays valid for existing clubs — it behaves like
-- Free + the Privates module with the 100-athlete cap.)
-- ============================================================================

-- Athlete caps: free 30 → 100 with any module; small stays 100; club/comped unlimited.
create or replace function public.gate_free_athlete_cap () returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_plan text := club_plan(new.club_id);
  v_modules int := (select coalesce(array_length(addons, 1), 0) from clubs where id = new.club_id);
  v_cap int;
begin
  v_cap := case
    when v_plan in ('club', 'comped') then null
    when v_plan = 'small' or v_modules > 0 then 100
    else 30
  end;
  if v_cap is not null
     and (select count(*) from athlete_enrolments where club_id = new.club_id) >= v_cap then
    if v_cap = 30 then
      raise exception 'The free plan covers up to 30 athletes — add any module (£8/mo) to grow to 100, or the Club plan (£35/mo) for unlimited.';
    else
      raise exception 'Your package covers up to 100 athletes — the Club plan (£35/mo) removes the cap.';
    end if;
  end if;
  return new;
end;
$$;

-- Gate wording: Small tier & £10 add-ons → the £8 module picker.
create or replace function public.gate_privates () returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.club_id is not null and not club_has(new.club_id, 'privates') then
    raise exception 'That''s part of the Privates module (£8/mo) or the Club plan (£35/mo) — add it to your package to switch it on.';
  end if;
  return new;
end;
$$;

create or replace function public.gate_privates_skill () returns trigger
language plpgsql security definer set search_path = public as $$
declare v_club uuid := (select club_id from skills where id = new.skill_id);
begin
  if v_club is not null and not club_has(v_club, 'privates') then
    raise exception 'That''s part of the Privates module (£8/mo) or the Club plan (£35/mo) — add it to your package to switch it on.';
  end if;
  return new;
end;
$$;

create or replace function public.gate_small_slots () returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not club_has(new.club_id, 'privates') then
    raise exception '1-2-1 private lessons are the Privates module (£8/mo) or come with the Club plan (£35/mo) — group classes are free.';
  end if;
  return new;
end;
$$;

create or replace function public.gate_club_tier () returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not club_has(new.club_id, 'memberships') then
    raise exception 'Monthly memberships are the Memberships & billing module (£8/mo) or come with the Club plan (£35/mo) — add it to your package.';
  end if;
  return new;
end;
$$;

-- Branding message.
create or replace function public.update_club_branding (
  p_club uuid, p_name text default null, p_blurb text default null,
  p_accent text default null, p_logo_path text default null, p_searchable boolean default null
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin_of(p_club) then raise exception 'Admins only.'; end if;
  if (p_accent is not null or p_logo_path is not null)
     and not club_has(p_club, 'websitepro') then
    raise exception 'Custom colours and logos are part of the Website Pro module (£8/mo) or the Club plan (£35/mo).';
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

-- Domain request message.
create or replace function public.admin_request_domain (p_club uuid, p_domain text, p_mailbox text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_domain text := lower(trim(p_domain));
  r record;
begin
  if not is_admin_of(p_club) then raise exception 'Admins only.'; end if;
  if not club_has(p_club, 'websitepro') then
    raise exception 'Custom domains & mailboxes are part of the Website Pro module (£8/mo) or the Club plan (£35/mo).';
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

-- Starter Package message.
create or replace function public.request_starter_package (p_club uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if not is_admin_of(p_club) then raise exception 'Admins only.'; end if;
  if not club_has(p_club, 'websitepro') then
    raise exception 'The Starter Package comes with the Club plan (£35/mo), or with the Website Pro module (£8/mo) on any package.';
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

-- Page-cap message (v17 function, message only).
create or replace function public.save_club_page (
  p_club uuid, p_slug text, p_title text, p_body text default '',
  p_sort int default 0, p_published boolean default true, p_blocks jsonb default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_cap int;
  b jsonb;
begin
  if not is_admin_of(p_club) then raise exception 'Admins only.'; end if;
  if not has_website(p_club) then
    raise exception 'The club website is part of the Club plan — or add the Website add-on. Ask Ignyte to switch it on.';
  end if;
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
  v_cap := case when club_has(p_club, 'websitepro') then 12 else 1 end;
  if (select count(*) from club_pages where club_id = p_club) >= v_cap
     and not exists (select 1 from club_pages where club_id = p_club and slug = lower(trim(p_slug))) then
    raise exception 'The free website is one page — the Website Pro module (£8/mo) or the Club plan (£35/mo) unlocks up to 12.';
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
-- ============================================================================
-- IGNYTE CLUB MANAGER — v19 "TIGHTER FREE + MODULES AT SIGNUP" (run after v18)
-- ----------------------------------------------------------------------------
-- The free plan becomes a genuine taster instead of a complete club system:
--   free & no modules: 20 athletes, 2 class groups, 5 shop products, 1 page.
--   any module (£10/mo): 100 athletes, unlimited classes & shop.
--   club/comped: unlimited everything.
-- Modules are £10/mo (up from £8) — every gate message updated.
-- Founders can now pick modules on the signup form: provision_club stores
-- them on clubs.requested_modules and pings the platform owner to enable
-- them once payment is sorted (there's no self-serve platform billing yet).
-- ============================================================================

-- One place to answer "does this club pay for anything?"
create or replace function public.club_has_any_module (p_club uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select plan in ('small', 'club', 'comped') or coalesce(array_length(addons, 1), 0) > 0
  from clubs where id = p_club
$$;
revoke execute on function public.club_has_any_module (uuid) from public, anon, authenticated;
grant execute on function public.club_has_any_module (uuid) to authenticated, service_role;

-- Athlete caps: free 20, any module (or legacy small) 100, club/comped unlimited.
create or replace function public.gate_free_athlete_cap () returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_plan text := club_plan(new.club_id);
  v_cap int;
begin
  v_cap := case
    when v_plan in ('club', 'comped') then null
    when club_has_any_module(new.club_id) then 100
    else 20
  end;
  if v_cap is not null
     and (select count(*) from athlete_enrolments where club_id = new.club_id) >= v_cap then
    if v_cap = 20 then
      raise exception 'The free plan covers up to 20 athletes — add any module (£10/mo) to grow to 100, or the Club plan (£35/mo) for unlimited.';
    else
      raise exception 'Your package covers up to 100 athletes — the Club plan (£35/mo) removes the cap.';
    end if;
  end if;
  return new;
end;
$$;

-- Free tier: up to 2 class groups; any module makes them unlimited.
create or replace function public.gate_free_class_groups () returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not club_has_any_module(new.club_id)
     and (select count(*) from class_groups where club_id = new.club_id) >= 2 then
    raise exception 'The free plan includes 2 class groups — any module (£10/mo) makes them unlimited.';
  end if;
  return new;
end;
$$;
drop trigger if exists free_gate_class_groups on public.class_groups;
create trigger free_gate_class_groups before insert on public.class_groups
  for each row execute function public.gate_free_class_groups ();

-- Free tier: shop lists up to 5 products; any module removes the cap.
create or replace function public.gate_free_shop_cap () returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not club_has_any_module(new.club_id)
     and (select count(*) from shop_products where club_id = new.club_id) >= 5 then
    raise exception 'The free shop lists up to 5 products — any module (£10/mo) removes the cap.';
  end if;
  return new;
end;
$$;
drop trigger if exists free_gate_shop_products on public.shop_products;
create trigger free_gate_shop_products before insert on public.shop_products
  for each row execute function public.gate_free_shop_cap ();

-- Module price £8 → £10 in every gate message.
create or replace function public.gate_privates () returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.club_id is not null and not club_has(new.club_id, 'privates') then
    raise exception 'That''s part of the Privates module (£10/mo) or the Club plan (£35/mo) — add it to your package to switch it on.';
  end if;
  return new;
end;
$$;

create or replace function public.gate_privates_skill () returns trigger
language plpgsql security definer set search_path = public as $$
declare v_club uuid := (select club_id from skills where id = new.skill_id);
begin
  if v_club is not null and not club_has(v_club, 'privates') then
    raise exception 'That''s part of the Privates module (£10/mo) or the Club plan (£35/mo) — add it to your package to switch it on.';
  end if;
  return new;
end;
$$;

create or replace function public.gate_small_slots () returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not club_has(new.club_id, 'privates') then
    raise exception '1-2-1 private lessons are the Privates module (£10/mo) or come with the Club plan (£35/mo) — group classes are free.';
  end if;
  return new;
end;
$$;

create or replace function public.gate_club_tier () returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not club_has(new.club_id, 'memberships') then
    raise exception 'Monthly memberships are the Memberships & billing module (£10/mo) or come with the Club plan (£35/mo) — add it to your package.';
  end if;
  return new;
end;
$$;

create or replace function public.update_club_branding (
  p_club uuid, p_name text default null, p_blurb text default null,
  p_accent text default null, p_logo_path text default null, p_searchable boolean default null
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin_of(p_club) then raise exception 'Admins only.'; end if;
  if (p_accent is not null or p_logo_path is not null)
     and not club_has(p_club, 'websitepro') then
    raise exception 'Custom colours and logos are part of the Website Pro module (£10/mo) or the Club plan (£35/mo).';
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

create or replace function public.admin_request_domain (p_club uuid, p_domain text, p_mailbox text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_domain text := lower(trim(p_domain));
  r record;
begin
  if not is_admin_of(p_club) then raise exception 'Admins only.'; end if;
  if not club_has(p_club, 'websitepro') then
    raise exception 'Custom domains & mailboxes are part of the Website Pro module (£10/mo) or the Club plan (£35/mo).';
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

create or replace function public.request_starter_package (p_club uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if not is_admin_of(p_club) then raise exception 'Admins only.'; end if;
  if not club_has(p_club, 'websitepro') then
    raise exception 'The Starter Package comes with the Club plan (£35/mo), or with the Website Pro module (£10/mo) on any package.';
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

create or replace function public.save_club_page (
  p_club uuid, p_slug text, p_title text, p_body text default '',
  p_sort int default 0, p_published boolean default true, p_blocks jsonb default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_cap int;
  b jsonb;
begin
  if not is_admin_of(p_club) then raise exception 'Admins only.'; end if;
  if not has_website(p_club) then
    raise exception 'The club website is part of the Club plan — or add the Website add-on. Ask Ignyte to switch it on.';
  end if;
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
  v_cap := case when club_has(p_club, 'websitepro') then 12 else 1 end;
  if (select count(*) from club_pages where club_id = p_club) >= v_cap
     and not exists (select 1 from club_pages where club_id = p_club and slug = lower(trim(p_slug))) then
    raise exception 'The free website is one page — the Website Pro module (£10/mo) or the Club plan (£35/mo) unlocks up to 12.';
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

-- ---------------------------------------------------------------------------
-- Modules on the signup form
-- ---------------------------------------------------------------------------
alter table public.clubs add column if not exists requested_modules text[] not null default '{}';

drop function if exists public.provision_club (text, text, text, text[], text, text);
create or replace function public.provision_club (
  p_name text, p_slug text, p_timezone text default 'Europe/London',
  p_disciplines text[] default array['tumble', 'dance'], p_location text default 'Main venue',
  p_promo text default null, p_modules text[] default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_club uuid;
  v_promo platform_promos%rowtype;
  v_modules text[] := coalesce(p_modules, '{}');
  m text;
  r record;
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;

  foreach m in array v_modules loop
    if m not in ('privates', 'memberships', 'websitepro') then
      raise exception 'Unknown module "%".', m;
    end if;
  end loop;

  if nullif(trim(coalesce(p_promo, '')), '') is not null then
    select * into v_promo from platform_promos
      where code = upper(trim(p_promo)) and active
        and (max_uses is null or uses < max_uses);
    if v_promo.code is null then raise exception 'That discount code isn''t valid.'; end if;
  end if;

  -- a 100%-off code means fully comped: every module unlocked from signup
  insert into clubs (name, slug, contact_name, contact_email, promo_code, plan, requested_modules)
  values (trim(p_name), lower(trim(p_slug)),
    (select full_name from profiles where id = auth.uid()),
    (select email from profiles where id = auth.uid()),
    v_promo.code,
    case when v_promo.percent_off = 100 then 'comped' else 'free' end,
    v_modules)
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

  if array_length(v_modules, 1) > 0 then
    for r in select id from profiles where role = 'owner' loop
      perform notify(r.id, null, 'modules_requested', '🧩 New club wants modules',
        trim(p_name) || ' picked ' || array_to_string(v_modules, ' + ')
        || ' (£' || (array_length(v_modules, 1) * 10) || '/mo) at sign-up — sort payment, then flip them on in Owner HQ.', '{}'::jsonb);
    end loop;
  end if;

  insert into owner_audit (club_id, action, detail)
  values (v_club, 'club_provisioned', trim(p_name) || coalesce(' [' || v_promo.code || ']', '')
    || case when array_length(v_modules, 1) > 0 then ' wants ' || array_to_string(v_modules, '+') else '' end);
  return jsonb_build_object('club_id', v_club, 'slug', lower(trim(p_slug)),
    'join_code', (select join_code from clubs where id = v_club));
end;
$$;

revoke execute on function public.provision_club (text, text, text, text[], text, text, text[]) from public, anon, authenticated;
grant execute on function public.provision_club (text, text, text, text[], text, text, text[]) to authenticated, service_role;
