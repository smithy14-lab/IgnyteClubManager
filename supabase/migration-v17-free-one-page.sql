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
