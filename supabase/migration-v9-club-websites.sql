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
