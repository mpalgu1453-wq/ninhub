-- Supabase schema for Nintendo Stock Manager
-- รันไฟล์นี้ใน Supabase SQL Editor (Dashboard > SQL Editor > New query > วางเนื้อหา > Run)

-- 1) ตารางผู้ใช้/สิทธิ์ (เชื่อมกับ auth.users ของ Supabase)
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  full_name text,
  role text not null default 'staff' check (role in ('admin','staff')),
  created_at timestamptz not null default now()
);

-- 2) ตารางสินค้า
create table if not exists public.products (
  code text primary key,
  name text not null,
  category text not null default 'เครื่องเกม',
  barcode text,
  qty integer not null default 0 check (qty >= 0),
  cost numeric not null default 0 check (cost >= 0),
  image text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 3) ตารางการเคลื่อนไหว (รับเข้า/ขายออก/โอนออก/ตรวจนับ)
create table if not exists public.moves (
  id bigint generated always as identity primary key,
  date timestamptz not null default now(),
  kind text not null check (kind in ('รับเข้า','ขายออก','โอนออก','ตรวจนับ')),
  code text not null,
  name text not null,
  qty integer not null check (qty >= 0),
  price numeric not null default 0,
  store text,
  note text,
  before_qty integer,
  after_qty integer,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create index if not exists moves_date_idx on public.moves (date desc);
create index if not exists moves_code_idx on public.moves (code);
create index if not exists products_category_idx on public.products (category);

-- 4) trigger: เพิ่ม profiles อัตโนมัติเมื่อสมัครสมาชิก
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, email, role)
  values (new.id, new.email, 'staff')
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 5) RLS: เปิดใช้ Row Level Security
alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.moves enable row level security;

-- helper: เช็คว่าคนที่ login อยู่เป็น admin ไหม
create or replace function public.is_admin()
returns boolean
language sql
security definer set search_path = public
stable
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin'
  );
$$;

-- policies: profiles
drop policy if exists "profiles_select_own_or_admin" on public.profiles;
create policy "profiles_select_own_or_admin"
  on public.profiles for select
  using (auth.uid() = id or public.is_admin());

drop policy if exists "profiles_update_admin" on public.profiles;
create policy "profiles_update_admin"
  on public.profiles for update
  using (public.is_admin())
  with check (public.is_admin());

-- policies: products (ทุกคนที่ login อ่านได้, admin เท่านั้นแก้ไขเพิ่ม/ลบ)
drop policy if exists "products_select_authenticated" on public.products;
create policy "products_select_authenticated"
  on public.products for select
  to authenticated
  using (true);

drop policy if exists "products_insert_admin" on public.products;
create policy "products_insert_admin"
  on public.products for insert
  to authenticated
  with check (public.is_admin());

drop policy if exists "products_update_admin" on public.products;
create policy "products_update_admin"
  on public.products for update
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

drop policy if exists "products_delete_admin" on public.products;
create policy "products_delete_admin"
  on public.products for delete
  to authenticated
  using (public.is_admin());

-- policies: moves (ทุกคนที่ login ดูได้, บันทึกผ่าน RPC record_move เท่านั้น, แก้ไข/ลบได้เฉพาะ admin)
drop policy if exists "moves_select_authenticated" on public.moves;
create policy "moves_select_authenticated"
  on public.moves for select
  to authenticated
  using (true);

-- ไม่มี insert policy: บันทึกการเคลื่อนไหวต้องผ่าน RPC record_move (security definer) เท่านั้น
-- เพื่อกัน insert ข้อมูลปลอม/ bypass การตรวจสอบ stock

drop policy if exists "moves_update_admin" on public.moves;
create policy "moves_update_admin"
  on public.moves for update
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

drop policy if exists "moves_delete_admin" on public.moves;
create policy "moves_delete_admin"
  on public.moves for delete
  to authenticated
  using (public.is_admin());

-- 6) RPC: บันทึกการเคลื่อนไหวสินค้า (รับเข้า/ขายออก/โอนออก/ตรวจนับ) + อัปเดต qty ใน transaction เดียว
create or replace function public.record_move(
  p_code text,
  p_kind text,
  p_qty integer,
  p_price numeric default 0,
  p_store text default null,
  p_note text default null
)
returns public.moves
language plpgsql
security definer set search_path = public
as $$
declare
  v_product public.products;
  v_before integer;
  v_after integer;
  v_move public.moves;
begin
  if auth.uid() is null then
    raise exception 'ต้องล็อกอินก่อนบันทึกรายการ';
  end if;

  select * into v_product from public.products where code = p_code for update;
  if not found then
    raise exception 'ไม่พบรหัสสินค้า: %', p_code;
  end if;

  if p_qty is null or p_qty <= 0 then
    raise exception 'จำนวนต้องมากกว่า 0';
  end if;

  v_before := v_product.qty;
  if p_kind = 'รับเข้า' then
    v_after := v_before + p_qty;
  elsif p_kind in ('ขายออก', 'โอนออก') then
    v_after := v_before - p_qty;
    if v_after < 0 then
      raise exception 'จำนวนไม่พอ: มี % ชิ้น', v_before;
    end if;
  elsif p_kind = 'ตรวจนับ' then
    if not public.is_admin() then
      raise exception 'เฉพาะแอดมินเท่านั้นที่ปรับยอดตรวจนับได้';
    end if;
    v_after := p_qty;
  else
    raise exception 'ประเภทรายการไม่ถูกต้อง: %', p_kind;
  end if;

  update public.products set qty = v_after, updated_at = now() where code = p_code;

  insert into public.moves (kind, code, name, qty, price, store, note, before_qty, after_qty, created_by)
  values (p_kind, p_code, v_product.name, p_qty, coalesce(p_price,0), p_store, p_note, v_before, v_after, auth.uid())
  returning * into v_move;

  return v_move;
end;
$$;

grant execute on function public.record_move(text, text, integer, numeric, text, text) to authenticated;
revoke execute on function public.record_move(text, text, integer, numeric, text, text) from anon, public;

-- 7) RPC: ปรับยอดสต๊อกจาก Excel (reconcile/add/report) + สร้างสินค้าใหม่อัตโนมัติ
create or replace function public.apply_stock_count(
  p_rows jsonb,
  p_mode text default 'reconcile'
)
returns jsonb
language plpgsql
security definer set search_path = public
as $$
declare
  r jsonb;
  v_code text;
  v_qty integer;
  v_name text;
  v_category text;
  v_product public.products;
  v_diff integer;
  v_results jsonb := '[]'::jsonb;
begin
  if auth.uid() is null then
    raise exception 'ต้องล็อกอินก่อนนำเข้าข้อมูล';
  end if;
  if not public.is_admin() then
    raise exception 'เฉพาะแอดมินเท่านั้นที่สามารถนำเข้า/ปรับสต๊อกจาก Excel ได้';
  end if;
  if p_mode not in ('reconcile','add','report') then
    raise exception 'โหมดการนำเข้าไม่ถูกต้อง';
  end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    v_code := trim(coalesce(r->>'code',''));
    v_qty := (r->>'qty')::integer;
    v_name := nullif(trim(coalesce(r->>'name','')),'');
    v_category := nullif(trim(coalesce(r->>'category','')),'');

    if v_code is null or v_code = '' then
      continue;
    end if;
    if v_qty is null or v_qty < 0 then
      raise exception 'จำนวนต้องเป็นตัวเลข >= 0 (รหัส: %)', v_code;
    end if;

    select * into v_product from public.products where code = v_code for update;

    if not found then
      -- รหัสใหม่: สร้างสินค้าใหม่อัตโนมัติ (ยกเว้นโหมด report ที่ไม่เปลี่ยนสต๊อก)
      if p_mode = 'report' then
        v_results := v_results || jsonb_build_object('code', v_code, 'status', 'not_found', 'qty', v_qty);
        continue;
      end if;

      insert into public.products (code, name, category, qty, cost, image)
      values (
        v_code,
        coalesce(v_name, v_code),
        coalesce(v_category, 'ไม่มีหมวดหมู่'),
        v_qty,
        0,
        null
      )
      returning * into v_product;

      insert into public.moves (kind, code, name, qty, price, note, before_qty, after_qty, created_by)
      values ('รับเข้า', v_code, v_product.name, v_qty, 0, 'สร้างสินค้าใหม่จาก Excel', 0, v_qty, auth.uid());

      v_results := v_results || jsonb_build_object('code', v_code, 'status', 'created', 'qty', v_qty);
      continue;
    end if;

    if p_mode = 'reconcile' then
      v_diff := v_qty - v_product.qty;
      if v_diff <> 0 then
        update public.products set qty = v_qty, updated_at = now() where code = v_code;
        insert into public.moves (kind, code, name, qty, price, note, before_qty, after_qty, created_by)
        values ('ตรวจนับ', v_code, v_product.name, abs(v_diff), v_product.cost,
                'ปรับยอดจาก Excel ' || case when v_diff > 0 then '+' else '' end || v_diff, v_product.qty, v_qty, auth.uid());
      end if;
      v_results := v_results || jsonb_build_object('code', v_code, 'status', 'reconciled', 'diff', v_diff, 'qty', v_qty);
    elsif p_mode = 'add' then
      update public.products set qty = qty + v_qty, updated_at = now() where code = v_code;
      insert into public.moves (kind, code, name, qty, price, note, before_qty, after_qty, created_by)
      values ('รับเข้า', v_code, v_product.name, v_qty, v_product.cost, 'นำเข้าจาก Excel (บวกจำนวน)', v_product.qty, v_product.qty + v_qty, auth.uid());
      v_results := v_results || jsonb_build_object('code', v_code, 'status', 'added', 'qty', v_qty);
    else -- report
      v_results := v_results || jsonb_build_object('code', v_code, 'status', 'reported', 'qty', v_qty, 'system_qty', v_product.qty, 'diff', v_qty - v_product.qty);
    end if;
  end loop;

  return v_results;
end;
$$;

grant execute on function public.apply_stock_count(jsonb, text) to authenticated;
revoke execute on function public.apply_stock_count(jsonb, text) from anon, public;

-- 8) Realtime สำหรับอัปเดตอัตโนมัติหลายอุปกรณ์ (เปิดใน Supabase Dashboard > Database > Replication)
-- alter publication supabase_realtime add table public.products, public.moves;

-- 9) Storage bucket สำหรับรูปสินค้า (ถ้าต้องการอัปโหลดรูปจริงจัง ค่อยเปิดใช้ทีหลัง)
-- insert into storage.buckets (id, name, public) values ('product-images', 'product-images', true) on conflict do nothing;

-- 10) ผู้ใช้คนแรก: หลัง signup ให้ปรับ role เป็น admin ด้วย SQL นี้ (แทนที่ YOUR_EMAIL)
-- update public.profiles set role = 'admin' where email = 'YOUR_EMAIL';
