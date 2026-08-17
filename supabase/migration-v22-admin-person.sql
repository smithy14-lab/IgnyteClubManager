-- ============================================================================
-- IGNYTE CLUB MANAGER — v22 "ADMIN EDIT PERSON" (run after v21)
-- ----------------------------------------------------------------------------
-- Club admins can update a member's contact details (name & phone) — e.g. fix
-- a typo in a parent's or coach's info. Profiles are otherwise self-edit only;
-- this gives admins a scoped path for members of their own club.
-- ============================================================================

create or replace function public.admin_update_person (p_club uuid, p_profile uuid, p_name text, p_phone text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin_of(p_club) then raise exception 'Admins only.'; end if;
  if not exists (select 1 from club_members where club_id = p_club and profile_id = p_profile and status = 'active') then
    raise exception 'That person is not a member of this club.';
  end if;
  update profiles set
    full_name = coalesce(nullif(trim(p_name), ''), full_name),
    phone = nullif(trim(coalesce(p_phone, '')), '')
  where id = p_profile;
  perform owner_log(p_club, 'update_person', p_profile::text);
end;
$$;

revoke execute on function public.admin_update_person (uuid, uuid, text, text) from public, anon;
grant execute on function public.admin_update_person (uuid, uuid, text, text) to authenticated, service_role;
