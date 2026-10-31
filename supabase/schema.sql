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
  bill_id text,
  created_at timestamptz not null default now()
);

create index if not exists moves_date_idx on public.moves (date desc);
create index if not exists moves_code_idx on public.moves (code);
create index if not exists moves_bill_idx on public.moves (bill_id);
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

  if not public.is_admin() then
    raise exception 'เฉพาะแอดมินเท่านั้นที่บันทึกการเคลื่อนไหวสินค้าได้';
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

-- 6.1) RPC: บันทึกหลายรายการในบิลเดียว (ขาย/รับเข้า/โอน) + อัปเดตสต๊อกใน transaction เดียว
create or replace function public.record_bill(
  p_kind text,
  p_items jsonb,
  p_store text default null,
  p_note text default null,
  p_bill text default null
)
returns jsonb
language plpgsql
security definer set search_path = public
as $$
declare
  v_product public.products;
  v_item jsonb;
  v_code text;
  v_qty integer;
  v_price numeric;
  v_before integer;
  v_after integer;
  v_bill text;
  v_items jsonb := '[]'::jsonb;
  v_total integer := 0;
begin
  if auth.uid() is null then
    raise exception 'ต้องล็อกอินก่อนบันทึกรายการ';
  end if;
  if p_kind is null or p_kind not in ('รับเข้า', 'ขายออก', 'โอนออก') then
    raise exception 'ประเภทรายการไม่ถูกต้อง: %', p_kind;
  end if;
  if not public.is_admin() then
    raise exception 'เฉพาะแอดมินเท่านั้นที่บันทึกการเคลื่อนไหวสินค้าได้';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'ไม่มีรายการสินค้าในบิล';
  end if;

  v_bill := coalesce(
    nullif(btrim(coalesce(p_bill, '')), ''),
    'B' || to_char(now() at time zone 'Asia/Bangkok', 'YYMMDDHH24MISS') || '-' || substr(md5(random()::text), 1, 4)
  );

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_code := nullif(btrim(coalesce(v_item->>'code', '')), '');
    v_qty := nullif(v_item->>'qty', '')::integer;
    v_price := coalesce(nullif(v_item->>'price', '')::numeric, 0);

    if v_code is null then
      raise exception 'รายการสินค้าไม่มีรหัส';
    end if;
    if v_qty is null or v_qty <= 0 then
      raise exception 'จำนวนต้องมากกว่า 0 (รหัส %)', v_code;
    end if;
    if v_price < 0 then
      raise exception 'ราคาต้องไม่ติดลบ (รหัส %)', v_code;
    end if;

    select * into v_product from public.products where code = v_code for update;
    if not found then
      raise exception 'ไม่พบรหัสสินค้า: %', v_code;
    end if;

    v_before := v_product.qty;
    if p_kind = 'รับเข้า' then
      v_after := v_before + v_qty;
    else
      v_after := v_before - v_qty;
      if v_after < 0 then
        raise exception 'สินค้าไม่พอ: % มี % ชิ้น', v_product.name, v_before;
      end if;
    end if;

    update public.products set qty = v_after, updated_at = now() where code = v_code;

    insert into public.moves (kind, code, name, qty, price, store, note, before_qty, after_qty, created_by, bill_id)
    values (p_kind, v_code, v_product.name, v_qty, v_price, p_store, p_note, v_before, v_after, auth.uid(), v_bill);

    v_items := v_items || jsonb_build_object('code', v_code, 'name', v_product.name, 'qty', v_qty, 'price', v_price, 'before_qty', v_before, 'after_qty', v_after);
    v_total := v_total + v_qty;
  end loop;

  return jsonb_build_object('bill', v_bill, 'kind', p_kind, 'total_qty', v_total, 'items', v_items);
end;
$$;

grant execute on function public.record_bill(text, jsonb, text, text, text) to authenticated;
revoke execute on function public.record_bill(text, jsonb, text, text, text) from anon, public;

-- 6.1) RPC: ยกเลิกบิลขายภายใน 24 ชั่วโมง (เฉพาะแอดมิน) — คืนสต๊อกและลบรายการขายของบิลนั้น
create or replace function public.cancel_sale(
  p_bill text default null,
  p_id bigint default null
)
returns jsonb
language plpgsql
security definer set search_path = public
as $$
declare
  v_bill text := nullif(btrim(coalesce(p_bill, '')), '');
  v_ids bigint[];
  v_latest timestamptz;
  v_move public.moves;
  v_items integer := 0;
  v_qty integer := 0;
begin
  if auth.uid() is null then
    raise exception 'ต้องล็อกอินก่อน';
  end if;
  if not public.is_admin() then
    raise exception 'เฉพาะแอดมินเท่านั้นที่ยกเลิกบิลได้';
  end if;
  if v_bill is null and p_id is null then
    raise exception 'ไม่พบบิลที่ต้องการยกเลิก';
  end if;

  select array_agg(id), max(date)
    into v_ids, v_latest
    from public.moves
   where kind = 'ขายออก'
     and ((v_bill is not null and bill_id = v_bill)
       or (v_bill is null and id = p_id));

  if v_ids is null then
    raise exception 'ไม่พบรายการขายนี้ (อาจถูกยกเลิกไปแล้ว)';
  end if;
  if now() - v_latest > interval '24 hours' then
    raise exception 'ยกเลิกได้ภายใน 24 ชั่วโมงหลังขายเท่านั้น';
  end if;

  for v_move in select * from public.moves where id = any(v_ids) loop
    update public.products
       set qty = qty + v_move.qty,
           updated_at = now()
     where code = v_move.code;
    v_items := v_items + 1;
    v_qty := v_qty + v_move.qty;
  end loop;

  delete from public.moves where id = any(v_ids);

  return jsonb_build_object('bill', v_bill, 'items', v_items, 'qty', v_qty);
end;
$$;

grant execute on function public.cancel_sale(text, bigint) to authenticated;
revoke execute on function public.cancel_sale(text, bigint) from anon, public;

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
  v_barcode text;
  v_cost numeric;
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
  if p_mode not in ('reconcile','add','meta','report') then
    raise exception 'โหมดการนำเข้าไม่ถูกต้อง';
  end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    v_code := trim(coalesce(r->>'code',''));
    v_qty := (r->>'qty')::integer;
    v_name := nullif(trim(coalesce(r->>'name','')),'');
    v_category := nullif(trim(coalesce(r->>'category','')),'');
    v_barcode := nullif(trim(coalesce(r->>'barcode','')),'');
    begin
      v_cost := nullif(trim(coalesce(r->>'cost','')),'')::numeric;
    exception when others then
      v_cost := null;
    end;
    if v_cost is not null and v_cost < 0 then
      v_cost := null;
    end if;

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

      insert into public.products (code, name, category, barcode, qty, cost, image)
      values (
        v_code,
        coalesce(v_name, v_code),
        'ไม่มีหมวดหมู่',
        v_barcode,
        v_qty,
        coalesce(v_cost, 0),
        null
      )
      returning * into v_product;

      insert into public.moves (kind, code, name, qty, price, note, before_qty, after_qty, created_by)
      values ('รับเข้า', v_code, v_product.name, v_qty, coalesce(v_cost, 0), 'สร้างสินค้าใหม่จาก Excel', 0, v_qty, auth.uid());

      v_results := v_results || jsonb_build_object('code', v_code, 'status', 'created', 'qty', v_qty);
      continue;
    end if;

    if p_mode = 'reconcile' then
      v_diff := v_qty - v_product.qty;
      if v_diff <> 0 or v_barcode is not null or v_cost is not null then
        update public.products set qty = v_qty, barcode = coalesce(v_barcode, barcode), cost = coalesce(v_cost, cost), updated_at = now() where code = v_code;
      end if;
      if v_diff <> 0 then
        insert into public.moves (kind, code, name, qty, price, note, before_qty, after_qty, created_by)
        values ('ตรวจนับ', v_code, v_product.name, abs(v_diff), v_product.cost,
                'ปรับยอดจาก Excel ' || case when v_diff > 0 then '+' else '' end || v_diff, v_product.qty, v_qty, auth.uid());
      end if;
      v_results := v_results || jsonb_build_object('code', v_code, 'status', 'reconciled', 'diff', v_diff, 'qty', v_qty);
    elsif p_mode = 'add' then
      -- จำนวนคงเดิม (หรือ 0) ไม่ต้องบวกเพิ่ม
      if v_qty = 0 or v_qty = v_product.qty then
        if v_barcode is not null or v_cost is not null then
          update public.products set barcode = coalesce(v_barcode, barcode), cost = coalesce(v_cost, cost), updated_at = now() where code = v_code;
        end if;
        v_results := v_results || jsonb_build_object('code', v_code, 'status', 'unchanged', 'qty', v_qty, 'system_qty', v_product.qty);
      else
        update public.products set qty = qty + v_qty, barcode = coalesce(v_barcode, barcode), cost = coalesce(v_cost, cost), updated_at = now() where code = v_code;
        insert into public.moves (kind, code, name, qty, price, note, before_qty, after_qty, created_by)
        values ('รับเข้า', v_code, v_product.name, v_qty, v_product.cost, 'นำเข้าจาก Excel (บวกจำนวน)', v_product.qty, v_product.qty + v_qty, auth.uid());
        v_results := v_results || jsonb_build_object('code', v_code, 'status', 'added', 'qty', v_qty, 'system_qty', v_product.qty);
      end if;
    elsif p_mode = 'meta' then
      -- อัปเดตเฉพาะบาร์โค้ด/ราคา ไม่แตะจำนวน
      update public.products set barcode = coalesce(v_barcode, barcode), cost = coalesce(v_cost, cost), updated_at = now() where code = v_code;
      v_results := v_results || jsonb_build_object('code', v_code, 'status', 'updated', 'qty', v_product.qty);
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

-- 9) Storage bucket สำหรับรูปสินค้า (เก็บไฟล์จริง + แชร์เป็นลิงก์)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-images','product-images',true,5242880,array['image/jpeg','image/png','image/webp','image/gif'])
on conflict (id) do update set public=true, file_size_limit=5242880, allowed_mime_types=array['image/jpeg','image/png','image/webp','image/gif'];

drop policy if exists "product_images_read" on storage.objects;
create policy "product_images_read" on storage.objects for select using (bucket_id='product-images');

drop policy if exists "product_images_insert" on storage.objects;
create policy "product_images_insert" on storage.objects for insert to authenticated with check (bucket_id='product-images' and public.is_admin());

drop policy if exists "product_images_update" on storage.objects;
create policy "product_images_update" on storage.objects for update to authenticated using (bucket_id='product-images' and public.is_admin()) with check (bucket_id='product-images' and public.is_admin());

drop policy if exists "product_images_delete" on storage.objects;
create policy "product_images_delete" on storage.objects for delete to authenticated using (bucket_id='product-images' and public.is_admin());

-- 10) ผู้ใช้คนแรก: หลัง signup ให้ปรับ role เป็น admin ด้วย SQL นี้ (แทนที่ YOUR_EMAIL)
-- update public.profiles set role = 'admin' where email = 'YOUR_EMAIL';
