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
