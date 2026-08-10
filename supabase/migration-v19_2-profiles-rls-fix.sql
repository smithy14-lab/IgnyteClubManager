-- ============================================================================
-- IGNYTE CLUB MANAGER — v19_2 HOTFIX (run after v19_1)
-- ----------------------------------------------------------------------------
-- Parents saw blank coach names ("Ava with · tumble") everywhere profiles are
-- embedded (bookings, dashboard, waitlist). Cause: profiles_select's subquery
-- reads club_members, whose own RLS only shows a parent their own row — so
-- the coach's membership row is invisible INSIDE the policy check and the
-- coach's profile never resolves. Move the shared-club staff check into a
-- security-definer helper (same pattern as my_club_ids/staff_of_athlete).
-- Visibility rules are unchanged: self; platform owner; staff of a shared
-- club see members; members see their clubs' staff. Parents still cannot
-- see other parents.
-- ============================================================================

create or replace function public.shares_club_staff_link (p_profile uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from club_members m1
    join club_members m2 on m2.club_id = m1.club_id
    where m1.profile_id = auth.uid() and m1.status = 'active'
      and m2.profile_id = p_profile and m2.status = 'active'
      and (m1.role in ('coach', 'admin') or m2.role in ('coach', 'admin')))
$$;
revoke execute on function public.shares_club_staff_link (uuid) from public, anon, authenticated;
grant execute on function public.shares_club_staff_link (uuid) to authenticated, service_role;

drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or is_owner() or shares_club_staff_link(id));
