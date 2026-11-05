-- =====================================================================
-- TIENDA DE ASEO · Esquema para Supabase (ejecutar en SQL Editor)
-- =====================================================================

-- ---------- 1. TABLAS ------------------------------------------------
create table profiles (
  id        uuid primary key references auth.users(id) on delete cascade,
  full_name text check (char_length(full_name) <= 100),
  role      text not null default 'customer' check (role in ('customer','admin'))
);

create table suppliers (
  id      bigint generated always as identity primary key,
  name    text not null check (char_length(name) between 2 and 100),
  contact text check (char_length(contact) <= 200)
);

create table products (
  id          bigint generated always as identity primary key,
  sku         text unique not null check (sku ~ '^[A-Z0-9-]{3,20}$'),
  name        text not null check (char_length(name) between 2 and 120),
  description text check (char_length(description) <= 500),
  price       numeric(12,2) not null check (price >= 0),
  stock       int not null default 0 check (stock >= 0),
  min_stock   int not null default 5 check (min_stock >= 0),
  active      boolean not null default true
);

create table customer_orders (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users(id),
  status     text not null default 'pendiente'
             check (status in ('pendiente','pagado','enviado','cancelado')),
  address    text not null check (char_length(address) between 5 and 200),
  total      numeric(12,2) not null check (total >= 0),
  created_at timestamptz not null default now()
);

create table customer_order_items (
  id         bigint generated always as identity primary key,
  order_id   bigint not null references customer_orders(id) on delete cascade,
  product_id bigint not null references products(id),
  qty        int not null check (qty > 0),
  unit_price numeric(12,2) not null check (unit_price >= 0)
);

create table purchase_orders (
  id          bigint generated always as identity primary key,
  supplier_id bigint not null references suppliers(id),
  status      text not null default 'emitida' check (status in ('emitida','recibida','cancelada')),
  created_at  timestamptz not null default now()
);

create table purchase_order_items (
  id         bigint generated always as identity primary key,
  po_id      bigint not null references purchase_orders(id) on delete cascade,
  product_id bigint not null references products(id),
  qty        int not null check (qty > 0),
  unit_cost  numeric(12,2) not null check (unit_cost >= 0)
);

create table inventory_movements (
  id         bigint generated always as identity primary key,
  product_id bigint not null references products(id),
  type       text not null check (type in ('entrada','salida','ajuste')),
  qty        int not null,
  ref_type   text,          -- pedido | cancelacion | orden_compra | ajuste
  ref_id     bigint,
  note       text check (char_length(note) <= 100),
  created_at timestamptz not null default now()
);

create index on customer_orders (user_id, created_at desc);
create index on customer_order_items (order_id);
create index on inventory_movements (product_id, created_at desc);

-- Perfil automático al registrarse
create function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles(id) values (new.id);
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function handle_new_user();

-- ---------- 2. FUNCIONES (transacciones) -----------------------------
create function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'admin')
$$;

-- T1 · Registrar pedido de cliente (valida, descuenta stock, deja kardex)
create function create_order(p_address text, p_items jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_order bigint; v_total numeric := 0;
  it jsonb; p products%rowtype; v_qty int;
begin
  if v_uid is null then raise exception 'No autenticado'; end if;
  p_address := btrim(regexp_replace(coalesce(p_address,''), '[<>]', '', 'g'));  -- sanitiza
  if char_length(p_address) < 5 then raise exception 'Dirección inválida'; end if;
  if jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) not between 1 and 50 then
    raise exception 'Carrito inválido';
  end if;
  -- rate limit: máx. 10 pedidos por hora por usuario
  if (select count(*) from customer_orders
       where user_id = v_uid and created_at > now() - interval '1 hour') >= 10 then
    raise exception 'Límite de pedidos por hora alcanzado';
  end if;

  insert into customer_orders(user_id, address, total) values (v_uid, p_address, 0)
    returning id into v_order;

  for it in select * from jsonb_array_elements(p_items) loop
    v_qty := (it->>'qty')::int;
    if v_qty is null or v_qty < 1 or v_qty > 100 then raise exception 'Cantidad inválida'; end if;
    select * into p from products
      where id = (it->>'product_id')::bigint and active for update;   -- bloquea la fila
    if not found then raise exception 'Producto no disponible'; end if;
    if p.stock < v_qty then raise exception 'Stock insuficiente: %', p.name; end if;

    update products set stock = stock - v_qty where id = p.id;
    insert into customer_order_items(order_id, product_id, qty, unit_price)
      values (v_order, p.id, v_qty, p.price);
    insert into inventory_movements(product_id, type, qty, ref_type, ref_id)
      values (p.id, 'salida', v_qty, 'pedido', v_order);
    v_total := v_total + p.price * v_qty;
  end loop;

  update customer_orders set total = v_total where id = v_order;
  return v_order;
end $$;

-- T2 · Cancelar pedido (devuelve stock)
create function cancel_order(p_order_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare o customer_orders%rowtype; r record;
begin
  select * into o from customer_orders where id = p_order_id for update;
  if not found then raise exception 'Pedido no existe'; end if;
  if not (is_admin() or (o.user_id = auth.uid() and o.status = 'pendiente')) then
    raise exception 'No autorizado';
  end if;
  if o.status = 'cancelado' then raise exception 'El pedido ya está cancelado'; end if;
  if o.status = 'enviado' then raise exception 'No se puede cancelar un pedido enviado'; end if;

  for r in select product_id, qty from customer_order_items where order_id = o.id loop
    update products set stock = stock + r.qty where id = r.product_id;
    insert into inventory_movements(product_id, type, qty, ref_type, ref_id)
      values (r.product_id, 'entrada', r.qty, 'cancelacion', o.id);
  end loop;
  update customer_orders set status = 'cancelado' where id = o.id;
end $$;

-- T3 · Cambiar estado del pedido (solo admin)
create function set_order_status(p_order_id bigint, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'No autorizado'; end if;
  if p_status not in ('pagado','enviado') then raise exception 'Estado inválido'; end if;
  update customer_orders set status = p_status
    where id = p_order_id and status <> 'cancelado';
  if not found then raise exception 'Pedido no existe o está cancelado'; end if;
end $$;

-- T4 · Ajuste manual de inventario (solo admin)
create function adjust_stock(p_product bigint, p_delta int, p_reason text) returns int
language plpgsql security definer set search_path = public as $$
declare v_new int;
begin
  if not is_admin() then raise exception 'No autorizado'; end if;
  if p_delta = 0 or abs(p_delta) > 10000 then raise exception 'Ajuste inválido'; end if;
  update products set stock = stock + p_delta where id = p_product returning stock into v_new;
  if not found then raise exception 'Producto no existe'; end if;   -- stock<0 lo bloquea el CHECK
  insert into inventory_movements(product_id, type, qty, ref_type, note)
    values (p_product, 'ajuste', p_delta, 'ajuste',
            left(regexp_replace(coalesce(p_reason,''), '[<>]', '', 'g'), 100));
  return v_new;
end $$;

-- T5 · Crear orden de compra a proveedor (solo admin)
create function create_purchase_order(p_supplier bigint, p_items jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_po bigint; it jsonb;
begin
  if not is_admin() then raise exception 'No autorizado'; end if;
  if jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) not between 1 and 50 then
    raise exception 'Líneas inválidas';
  end if;
  insert into purchase_orders(supplier_id) values (p_supplier) returning id into v_po;
  for it in select * from jsonb_array_elements(p_items) loop
    insert into purchase_order_items(po_id, product_id, qty, unit_cost)
      values (v_po, (it->>'product_id')::bigint, (it->>'qty')::int, (it->>'unit_cost')::numeric);
  end loop;
  return v_po;
end $$;

-- T6 · Recibir orden de compra (suma stock)
create function receive_purchase_order(p_po bigint) returns void
language plpgsql security definer set search_path = public as $$
declare r record; v_status text;
begin
  if not is_admin() then raise exception 'No autorizado'; end if;
  select status into v_status from purchase_orders where id = p_po for update;
  if v_status is null then raise exception 'Orden no existe'; end if;
  if v_status <> 'emitida' then raise exception 'La orden ya fue procesada'; end if;
  for r in select product_id, qty from purchase_order_items where po_id = p_po loop
    update products set stock = stock + r.qty where id = r.product_id;
    insert into inventory_movements(product_id, type, qty, ref_type, ref_id)
      values (r.product_id, 'entrada', r.qty, 'orden_compra', p_po);
  end loop;
  update purchase_orders set status = 'recibida' where id = p_po;
end $$;

-- Solo usuarios autenticados pueden ejecutar las funciones
revoke execute on function create_order(text,jsonb), cancel_order(bigint),
  set_order_status(bigint,text), adjust_stock(bigint,int,text),
  create_purchase_order(bigint,jsonb), receive_purchase_order(bigint) from public, anon;
grant execute on function create_order(text,jsonb), cancel_order(bigint),
  set_order_status(bigint,text), adjust_stock(bigint,int,text),
  create_purchase_order(bigint,jsonb), receive_purchase_order(bigint) to authenticated;

-- ---------- 3. ROW LEVEL SECURITY ------------------------------------
alter table profiles             enable row level security;
alter table suppliers            enable row level security;
alter table products             enable row level security;
alter table customer_orders      enable row level security;
alter table customer_order_items enable row level security;
alter table purchase_orders      enable row level security;
alter table purchase_order_items enable row level security;
alter table inventory_movements  enable row level security;

create policy profiles_own   on profiles for select using (id = auth.uid());

create policy products_read  on products for select using (active or is_admin());
create policy products_ins   on products for insert with check (is_admin());
create policy products_upd   on products for update using (is_admin()) with check (is_admin());

create policy orders_read    on customer_orders for select
  using (user_id = auth.uid() or is_admin());
create policy items_read     on customer_order_items for select
  using (exists (select 1 from customer_orders o
                  where o.id = order_id and (o.user_id = auth.uid() or is_admin())));

create policy suppliers_adm  on suppliers for all using (is_admin()) with check (is_admin());
create policy po_adm         on purchase_orders for select using (is_admin());
create policy poi_adm        on purchase_order_items for select using (is_admin());
create policy mov_adm        on inventory_movements for select using (is_admin());
-- Pedidos, compras y movimientos NO tienen políticas de escritura:
-- solo se modifican mediante las funciones de arriba.

-- ---------- 4. DATOS DE EJEMPLO --------------------------------------
insert into products (sku, name, description, price, stock, min_stock) values
 ('DET-001','Detergente líquido 3L','Ropa de color y blanca',24900,40,10),
 ('DES-001','Desinfectante lavanda 1L','Pisos y superficies',9800,60,15),
 ('BLA-001','Blanqueador 1L','Cloro al 5%',6500,50,10),
 ('JAB-001','Jabón de manos 500ml','Antibacterial',7200,35,10),
 ('ESC-001','Escoba multiusos','Cerda suave',12500,20,5),
 ('TRA-001','Trapeador de microfibra','Con cabo metálico',15900,18,5),
 ('ESP-001','Esponja doble uso x3','Cocina',4500,80,20);
insert into suppliers (name, contact) values ('Distribuidora Aseo Total','ventas@aseototal.example');

-- Para volver admin a tu usuario (tras registrarte en la tienda):
-- update profiles set role = 'admin' where id = '<TU-UUID-DE-auth.users>';
