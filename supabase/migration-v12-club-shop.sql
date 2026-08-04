-- ============================================================================
-- IGNYTE CLUB MANAGER — v12 "CLUB SHOP" (ADDITIVE — run after v11)
-- ----------------------------------------------------------------------------
-- Kit, uniforms and merch — part of the FREE tier. Products with options
-- (sizes) and optional stock tracking; members order in-app. Clubs with the
-- money module get an invoice per order automatically (pay online, 0% fees);
-- Free clubs take payment at the desk and mark orders paid. The public club
-- website gets a Shop section.
-- ============================================================================

create table public.shop_products (
  id uuid primary key default gen_random_uuid (),
  club_id uuid not null references public.clubs (id) on delete cascade,
  name text not null check (char_length(name) between 2 and 80),
  description text,
  price numeric(8, 2) not null check (price >= 0),
  options text[] not null default '{}', -- e.g. sizes: {Age 5-6, Age 7-8, Adult S}
  image_url text check (image_url is null or image_url ~ '^https://'),
  stock int check (stock is null or stock >= 0), -- null = not tracked
  active boolean not null default true,
  sort int not null default 0,
  created_at timestamptz not null default now()
);
create index shop_products_club_idx on public.shop_products (club_id, active, sort);

create table public.shop_orders (
  id uuid primary key default gen_random_uuid (),
  club_id uuid not null references public.clubs (id) on delete cascade,
  product_id uuid references public.shop_products (id) on delete set null,
  product_name text not null,
  option_choice text,
  qty int not null check (qty between 1 and 20),
  unit_price numeric(8, 2) not null,
  amount numeric(10, 2) not null,
  buyer_id uuid not null references public.profiles (id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'paid', 'collected', 'cancelled')),
  invoice_id uuid references public.invoices (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index shop_orders_club_idx on public.shop_orders (club_id, status, created_at desc);
create index shop_orders_buyer_idx on public.shop_orders (buyer_id);

alter table public.shop_products enable row level security;
alter table public.shop_orders enable row level security;

create policy shop_products_select on public.shop_products for select to authenticated
  using (club_id in (select my_club_ids()));
create policy shop_orders_select on public.shop_orders for select to authenticated
  using ((club_id in (select my_club_ids())) and (buyer_id = auth.uid() or is_admin_of(club_id)));

-- invoices grow a 'shop' source
alter table public.invoices drop constraint invoices_source_check;
alter table public.invoices add constraint invoices_source_check
  check (source in ('manual', 'membership', 'credit_pack', 'trial', 'lessons', 'class', 'shop'));

-- 'shop' becomes a built-in site section
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
  if lower(trim(p_slug)) in ('classes', 'coaches', 'contact', 'join', 'home', 'shop') then
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

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------
create or replace function public.admin_save_product (
  p_club uuid, p_id uuid, p_name text, p_price numeric,
  p_description text default null, p_options text[] default '{}',
  p_image_url text default null, p_stock int default null,
  p_active boolean default true, p_sort int default 0
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid := p_id;
begin
  if not is_admin_of(p_club) then raise exception 'Only club admins can manage the shop.'; end if;
  if v_id is null then
    insert into shop_products (club_id, name, description, price, options, image_url, stock, active, sort)
    values (p_club, trim(p_name), p_description, round(p_price, 2), coalesce(p_options, '{}'),
            nullif(trim(coalesce(p_image_url, '')), ''), p_stock, p_active, coalesce(p_sort, 0))
    returning id into v_id;
  else
    update shop_products set name = trim(p_name), description = p_description,
      price = round(p_price, 2), options = coalesce(p_options, '{}'),
      image_url = nullif(trim(coalesce(p_image_url, '')), ''), stock = p_stock,
      active = p_active, sort = coalesce(p_sort, 0)
    where id = v_id and club_id = p_club;
    if not found then raise exception 'Product not found.'; end if;
  end if;
  perform owner_log(p_club, 'save_product', trim(p_name));
  return v_id;
end;
$$;

create or replace function public.place_shop_order (p_product uuid, p_option text default null, p_qty int default 1)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_p shop_products%rowtype;
  v_id uuid;
  v_inv uuid;
  v_due int;
  v_symbol text;
  r record;
begin
  select * into v_p from shop_products where id = p_product for update;
  if v_p.id is null or not v_p.active then raise exception 'That item isn''t available.'; end if;
  perform assert_club_active(v_p.club_id);
  if not exists (select 1 from club_members
      where club_id = v_p.club_id and profile_id = auth.uid() and status = 'active') then
    raise exception 'Join this club to order from its shop.';
  end if;
  if p_qty < 1 or p_qty > 20 then raise exception 'Quantity must be between 1 and 20.'; end if;
  if cardinality(v_p.options) > 0 and (p_option is null or not (p_option = any (v_p.options))) then
    raise exception 'Pick a size/option first.';
  end if;
  if v_p.stock is not null then
    if v_p.stock < p_qty then raise exception 'Only % left in stock.', v_p.stock; end if;
    update shop_products set stock = stock - p_qty where id = p_product;
  end if;

  insert into shop_orders (club_id, product_id, product_name, option_choice, qty, unit_price, amount, buyer_id)
  values (v_p.club_id, p_product, v_p.name, p_option, p_qty, v_p.price, round(v_p.price * p_qty, 2), auth.uid())
  returning id into v_id;

  select currency, invoice_due_days into v_symbol, v_due from club_settings where club_id = v_p.club_id;
  if club_has(v_p.club_id, 'privates') and v_p.price > 0 then
    insert into invoices (club_id, profile_id, description, amount, due_date, source, meta, created_by)
    values (v_p.club_id, auth.uid(),
            'Shop — ' || v_p.name || coalesce(' (' || p_option || ')', '') || ' × ' || p_qty,
            round(v_p.price * p_qty, 2), current_date + coalesce(v_due, 7),
            'shop', jsonb_build_object('order_id', v_id), auth.uid())
    returning id into v_inv;
    update shop_orders set invoice_id = v_inv where id = v_id;
  end if;

  perform notify(auth.uid(), v_p.club_id, 'shop_order', 'Order placed 🛍️',
    v_p.name || coalesce(' (' || p_option || ')', '') || ' × ' || p_qty || ' — '
    || coalesce(v_symbol, '£') || round(v_p.price * p_qty, 2)
    || case when v_inv is not null then '. Pay from your Money page; collect at the club.'
            else '. Pay at the club when you collect.' end,
    jsonb_build_object('order_id', v_id));
  for r in select profile_id from club_members
           where club_id = v_p.club_id and role = 'admin' and status = 'active' loop
    perform notify(r.profile_id, v_p.club_id, 'shop_order', 'New shop order',
      (select full_name from profiles where id = auth.uid()) || ' ordered ' || v_p.name
      || coalesce(' (' || p_option || ')', '') || ' × ' || p_qty || '.',
      jsonb_build_object('order_id', v_id));
  end loop;
  return jsonb_build_object('order_id', v_id, 'invoiced', v_inv is not null);
end;
$$;

create or replace function public.cancel_shop_order (p_order uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_o shop_orders%rowtype;
begin
  select * into v_o from shop_orders where id = p_order for update;
  if v_o.id is null then raise exception 'Order not found.'; end if;
  if not (v_o.buyer_id = auth.uid() or is_admin_of(v_o.club_id)) then
    raise exception 'Not your order.';
  end if;
  if v_o.status <> 'pending' then raise exception 'Only pending orders can be cancelled — ask the club.'; end if;
  update shop_orders set status = 'cancelled', updated_at = now() where id = p_order;
  if v_o.product_id is not null then
    update shop_products set stock = stock + v_o.qty where id = v_o.product_id and stock is not null;
  end if;
  if v_o.invoice_id is not null then
    update invoices set status = 'void' where id = v_o.invoice_id and status in ('due', 'overdue');
  end if;
end;
$$;

create or replace function public.admin_set_order_status (p_order uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare v_o shop_orders%rowtype;
begin
  select * into v_o from shop_orders where id = p_order for update;
  if v_o.id is null then raise exception 'Order not found.'; end if;
  if not is_admin_of(v_o.club_id) then raise exception 'Only club admins can manage orders.'; end if;
  if p_status not in ('paid', 'collected', 'cancelled') then raise exception 'Bad status.'; end if;
  if p_status = 'cancelled' then perform cancel_shop_order(p_order); return; end if;
  update shop_orders set status = p_status, updated_at = now() where id = p_order;
  if p_status = 'paid' and v_o.invoice_id is not null then
    perform _settle_invoice(v_o.invoice_id, 'cash', 'shop order');
  end if;
  perform notify(v_o.buyer_id, v_o.club_id, 'shop_order',
    case p_status when 'paid' then 'Order paid ✅' else 'Ready — collected! 🛍️' end,
    v_o.product_name || coalesce(' (' || v_o.option_choice || ')', '') || ' × ' || v_o.qty
    || case p_status when 'paid' then ' is marked paid.' else ' is marked collected. Enjoy!' end,
    jsonb_build_object('order_id', p_order));
end;
$$;

-- Paying the linked invoice (online or recorded) marks the order paid.
create or replace function public.sync_shop_order_paid () returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'paid' and old.status <> 'paid' then
    update shop_orders set status = 'paid', updated_at = now()
      where invoice_id = new.id and status = 'pending';
  end if;
  return new;
end;
$$;
drop trigger if exists invoices_shop_sync on public.invoices;
create trigger invoices_shop_sync after update of status on public.invoices
  for each row execute function public.sync_shop_order_paid ();

-- Public site: the shop window.
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
       from class_groups g where g.club_id = c.id and g.active) as classes,
      (select coalesce(jsonb_agg(jsonb_build_object(
          'name', sp.name, 'description', sp.description, 'price', sp.price,
          'options', sp.options, 'image_url', sp.image_url,
          'in_stock', (sp.stock is null or sp.stock > 0)
        ) order by sp.sort, sp.name), '[]'::jsonb)
       from shop_products sp where sp.club_id = c.id and sp.active) as shop
    from clubs c where c.slug = lower(p_slug) and c.status = 'active' and c.searchable
  ) t
$$;

revoke execute on function
  public.admin_save_product (uuid, uuid, text, numeric, text, text[], text, int, boolean, int),
  public.place_shop_order (uuid, text, int),
  public.cancel_shop_order (uuid),
  public.admin_set_order_status (uuid, text)
from public, anon, authenticated;

grant execute on function
  public.admin_save_product (uuid, uuid, text, numeric, text, text[], text, int, boolean, int),
  public.place_shop_order (uuid, text, int),
  public.cancel_shop_order (uuid),
  public.admin_set_order_status (uuid, text)
to authenticated, service_role;
