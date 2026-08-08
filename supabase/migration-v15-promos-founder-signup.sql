-- ============================================================================
-- IGNYTE CLUB MANAGER — v15 "FOUNDERS & PROMOS" (ADDITIVE — run after v14)
-- ----------------------------------------------------------------------------
--   1. PROMO CODES — owner-managed discount codes for club sign-ups
--      (e.g. CHEER50 = 50% off for 3 months). Clubs enter them in the
--      start-a-club wizard; the code is validated, counted, recorded on the
--      club and surfaced in Owner HQ so billing honours it.
--   2. FOUNDER SIGNUP — provision_club accepts the promo; the /start page
--      now creates the founder's account and the club in one flow.
-- ============================================================================

create table public.platform_promos (
  code text primary key check (code ~ '^[A-Z0-9-]{3,20}$'),
  description text,
  percent_off int not null check (percent_off between 1 and 100),
  duration_months int not null default 3 check (duration_months between 1 and 24),
  max_uses int check (max_uses > 0),
  uses int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.platform_promos enable row level security;
create policy promos_owner on public.platform_promos for select to authenticated using (is_owner());

alter table public.clubs add column if not exists promo_code text;

-- Anyone can check a code while signing up (returns nothing sensitive).
create or replace function public.check_promo (p_code text) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((
    select jsonb_build_object('valid', true, 'code', code, 'percent_off', percent_off,
      'duration_months', duration_months, 'description', description)
    from platform_promos
    where code = upper(trim(p_code)) and active
      and (max_uses is null or uses < max_uses)
  ), jsonb_build_object('valid', false))
$$;

create or replace function public.owner_save_promo (
  p_code text, p_percent int, p_months int default 3,
  p_description text default null, p_max_uses int default null, p_active boolean default true
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_owner() then raise exception 'Owner only.'; end if;
  insert into platform_promos (code, percent_off, duration_months, description, max_uses, active)
  values (upper(trim(p_code)), p_percent, p_months, p_description, p_max_uses, p_active)
  on conflict (code) do update set percent_off = excluded.percent_off,
    duration_months = excluded.duration_months, description = excluded.description,
    max_uses = excluded.max_uses, active = excluded.active;
  insert into owner_audit (action, detail) values ('save_promo', upper(trim(p_code)));
end;
$$;

-- provision_club learns the promo (replaces the 5-arg version).
drop function if exists public.provision_club (text, text, text, text[], text);
create or replace function public.provision_club (
  p_name text, p_slug text, p_timezone text default 'Europe/London',
  p_disciplines text[] default array['tumble', 'dance'], p_location text default 'Main venue',
  p_promo text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_club uuid;
  v_promo platform_promos%rowtype;
  r record;
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;

  if nullif(trim(coalesce(p_promo, '')), '') is not null then
    select * into v_promo from platform_promos
      where code = upper(trim(p_promo)) and active
        and (max_uses is null or uses < max_uses);
    if v_promo.code is null then raise exception 'That discount code isn''t valid.'; end if;
  end if;

  -- a 100%-off code means fully comped: every module unlocked from signup
  insert into clubs (name, slug, contact_name, contact_email, promo_code, plan)
  values (trim(p_name), lower(trim(p_slug)),
    (select full_name from profiles where id = auth.uid()),
    (select email from profiles where id = auth.uid()),
    v_promo.code,
    case when v_promo.percent_off = 100 then 'comped' else 'free' end)
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

  insert into owner_audit (club_id, action, detail)
  values (v_club, 'club_provisioned', trim(p_name) || coalesce(' [' || v_promo.code || ']', ''));
  return jsonb_build_object('club_id', v_club, 'slug', lower(trim(p_slug)),
    'join_code', (select join_code from clubs where id = v_club));
end;
$$;

revoke execute on function
  public.check_promo (text),
  public.owner_save_promo (text, int, int, text, int, boolean),
  public.provision_club (text, text, text, text[], text, text)
from public, anon, authenticated;

grant execute on function public.check_promo (text) to anon, authenticated, service_role;
grant execute on function public.owner_save_promo (text, int, int, text, int, boolean) to authenticated, service_role;
grant execute on function public.provision_club (text, text, text, text[], text, text) to authenticated, service_role;
