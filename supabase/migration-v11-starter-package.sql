-- ============================================================================
-- IGNYTE CLUB MANAGER — v11 "STARTER PACKAGE" (ADDITIVE — run after v10)
-- ----------------------------------------------------------------------------
-- £299 one-off, done-for-you onboarding: Ignyte builds the club's website,
-- wires the custom domain + mailbox, connects Stripe and migrates coaches,
-- families and existing sessions. Available with the Club plan, or with the
-- Website Pro add-on on Free & Small (i.e. club_has 'websitepro').
-- ============================================================================

alter table public.clubs
  add column if not exists starter_status text
    check (starter_status in ('requested', 'in_progress', 'done'));

create or replace function public.request_starter_package (p_club uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if not is_admin_of(p_club) then raise exception 'Admins only.'; end if;
  if not club_has(p_club, 'websitepro') then
    raise exception 'The Starter Package comes with the Club plan (£35/mo), or with the Website Pro add-on (£10/mo) on Free & Small.';
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

create or replace function public.owner_set_starter_status (p_club uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if not is_owner() then raise exception 'Owner only.'; end if;
  if p_status not in ('requested', 'in_progress', 'done') then raise exception 'Bad status.'; end if;
  update clubs set starter_status = p_status where id = p_club;
  insert into owner_audit (club_id, action, detail) values (p_club, 'starter_status', p_status);
  if p_status = 'done' then
    for r in select profile_id from club_members
             where club_id = p_club and role = 'admin' and status = 'active' loop
      perform notify(r.profile_id, p_club, 'starter_done', '🚀 Your club is fully set up!',
        'Your Starter Package is complete — website live, payments connected, everyone imported. Over to you!', '{}'::jsonb);
    end loop;
  end if;
end;
$$;

revoke execute on function
  public.request_starter_package (uuid),
  public.owner_set_starter_status (uuid, text)
from public, anon, authenticated;

grant execute on function
  public.request_starter_package (uuid),
  public.owner_set_starter_status (uuid, text)
to authenticated, service_role;
