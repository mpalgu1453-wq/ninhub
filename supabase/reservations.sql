-- ระบบจองสินค้าจากเว็บลูกค้า (repo: ninhub-shop) → เก็บลงฐานข้อมูลเดียวกัน
-- วิธีใช้: Supabase → SQL Editor → New query → วางทั้งหมด → Run
-- รันซ้ำได้ทุกครั้ง (ไม่ลบข้อมูลการจอง/สินค้า)
--
-- หลักการ:
--   * เว็บลูกค้า (anon) จองได้ผ่านฟังก์ชัน public.create_reservation() เท่านั้น
--   * เว็บลูกค้าอ่านตาราง reservations โดยตรงไม่ได้ (กันข้อมูลลูกค้ารั่ว)
--   * แอดมินในเว็บสต๊อกอ่าน/อัปเดต/ลบได้ตามสิทธิ์ public.is_admin()
--   * เมื่อลูกค้าจอง (status = 'pending' หรือ 'confirmed') ยอดที่แสดงบนเว็บลูกค้า (public_catalog) จะถูกหักออกทันที
--   * แต่ "ไม่ตัดสต๊อกจริงฝั่งหลังบ้าน (products.qty)" — แอดมินกดบันทึกขายเองที่หน้า "ขายสินค้า" ตามปกติ แล้วค่อยกด "รับสินค้าแล้ว" (completed)

-- 1) ตารางการจอง
create table if not exists public.reservations (
  id bigint generated always as identity primary key,
  order_code text,
  code text not null,
  product_name text not null,
  qty integer not null check (qty >= 1 and qty <= 10),
  customer_name text not null,
  phone text not null,
  note text,
  pickup_date date,
  status text not null default 'pending'
    check (status in ('pending','confirmed','completed','cancelled')),
  admin_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.reservations add column if not exists order_code text;
alter table public.reservations drop constraint if exists reservations_qty_check;
alter table public.reservations add constraint reservations_qty_check check (qty >= 1 and qty <= 10);

update public.reservations
set order_code = 'RSV-' || to_char(created_at at time zone 'Asia/Bangkok', 'YYMMDD') || '-' || lpad(id::text, 4, '0')
where order_code is null or btrim(order_code) = '';

create unique index if not exists reservations_order_code_key on public.reservations (order_code);
create index if not exists reservations_status_idx on public.reservations (status, created_at desc);
create index if not exists reservations_phone_idx on public.reservations (phone);
create index if not exists reservations_code_idx on public.reservations (code);
create index if not exists reservations_created_idx on public.reservations (created_at desc);

-- ฟังก์ชันสุ่มรหัสออเดอร์ไม่ซ้ำกัน รูปแบบ RSV-YYMMDD-XXXX
create or replace function public.gen_reservation_code()
returns text
language plpgsql
as $$
declare
  v_chars constant text := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  v_prefix text := 'RSV-' || to_char(now() at time zone 'Asia/Bangkok', 'YYMMDD') || '-';
  v_suffix text;
  v_code text;
  i integer;
  attempt integer := 0;
begin
  loop
    v_suffix := '';
    for i in 1..4 loop
      v_suffix := v_suffix || substr(v_chars, 1 + floor(random() * length(v_chars))::integer, 1);
    end loop;
    v_code := v_prefix || v_suffix;
    exit when not exists (select 1 from public.reservations r where r.order_code = v_code);
    attempt := attempt + 1;
    if attempt > 30 then
      v_code := v_prefix || substr(md5(random()::text || clock_timestamp()::text), 1, 6);
      exit;
    end if;
  end loop;
  return upper(v_code);
end;
$$;

-- 2) อัปเดต updated_at และสร้าง order_code อัตโนมัติ
create or replace function public.reservations_touch()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'INSERT' and (new.order_code is null or btrim(new.order_code) = '') then
    new.order_code := public.gen_reservation_code();
  end if;
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists reservations_touch_trg on public.reservations;
create trigger reservations_touch_trg
before insert or update on public.reservations
for each row execute function public.reservations_touch();

-- 3) RLS: ลูกค้าอ่านไม่ได้ · แอดมินจัดการได้
alter table public.reservations enable row level security;

drop policy if exists "reservations_select_admin" on public.reservations;
create policy "reservations_select_admin"
on public.reservations for select to authenticated
using (public.is_admin());

drop policy if exists "reservations_update_admin" on public.reservations;
create policy "reservations_update_admin"
on public.reservations for update to authenticated
using (public.is_admin())
with check (public.is_admin());

drop policy if exists "reservations_delete_admin" on public.reservations;
create policy "reservations_delete_admin"
on public.reservations for delete to authenticated
using (public.is_admin());

-- 4) ฟังก์ชันสร้างการจอง (เรียกจากเว็บลูกค้าด้วย anon key)
drop function if exists public.create_reservation(text, integer, text, text, text, date);

create or replace function public.create_reservation(
  p_code text,
  p_qty integer,
  p_customer_name text,
  p_phone text,
  p_note text default null,
  p_pickup_date date default null
)
returns table (id bigint, order_code text, status text, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text := btrim(coalesce(p_customer_name, ''));
  v_phone text := regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g');
  v_qty integer := coalesce(p_qty, 1);
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_product public.products%rowtype;
  v_reserved integer := 0;
  v_available integer := 0;
  v_id bigint;
  v_order_code text;
  v_created timestamptz;
begin
  if length(v_name) < 2 then
    raise exception 'กรุณากรอกชื่อผู้จองอย่างน้อย 2 ตัวอักษร';
  end if;

  if length(v_phone) < 9 or length(v_phone) > 15 then
    raise exception 'กรุณากรอกเบอร์โทรให้ถูกต้อง (9–15 หลัก)';
  end if;

  if v_qty < 1 or v_qty > 10 then
    raise exception 'จำกัดการจองไม่เกิน 10 ชิ้นต่อ 1 ใบเสร็จ (1–10 ชิ้น)';
  end if;

  if v_note is not null and length(v_note) > 300 then
    raise exception 'หมายเหตุยาวเกินไป (ไม่เกิน 300 ตัวอักษร)';
  end if;

  if p_pickup_date is not null and p_pickup_date < current_date then
    raise exception 'วันที่รับสินค้าต้องไม่เป็นวันในอดีต';
  end if;

  if p_pickup_date is not null and p_pickup_date > current_date + 2 then
    raise exception 'วันที่รับสินค้าต้องอยู่ภายใน 3 วัน (ถึง %)', to_char(current_date + 2, 'DD/MM/YYYY');
  end if;

  select * into v_product from public.products where code = p_code for update;
  if not found then
    raise exception 'ไม่พบสินค้านี้ในระบบ';
  end if;

  select coalesce(sum(r.qty), 0)::integer into v_reserved
  from public.reservations r
  where r.code = p_code
    and r.status in ('pending', 'confirmed');

  v_available := greatest(0, coalesce(v_product.qty, 0) - v_reserved);

  if v_available < v_qty then
    raise exception 'สินค้าเหลือไม่พอสำหรับการจอง (คงเหลือให้จอง % ชิ้น)', v_available;
  end if;

  -- กันกดซ้ำ/สแปม: เบอร์เดิม + สินค้าเดิม ภายใน 10 นาที
  if exists (
    select 1 from public.reservations r
    where r.code = p_code
      and r.phone = v_phone
      and r.status in ('pending', 'confirmed')
      and r.created_at > now() - interval '10 minutes'
  ) then
    raise exception 'มีการจองสินค้านี้จากเบอร์นี้แล้ว กรุณารอการยืนยันจากร้าน';
  end if;

  -- เพดานการจองต่อเบอร์ต่อวัน (กันสแปม/กลั่นแกล้งร้าน)
  if (
    select count(*) from public.reservations r
    where r.phone = v_phone
      and r.created_at > now() - interval '24 hours'
  ) >= 5 then
    raise exception 'เบอร์นี้จองครบ 5 รายการใน 24 ชั่วโมงแล้ว กรุณาติดต่อร้านโดยตรง';
  end if;

  v_order_code := public.gen_reservation_code();

  insert into public.reservations (order_code, code, product_name, qty, customer_name, phone, note, pickup_date)
  values (v_order_code, p_code, v_product.name, v_qty, v_name, v_phone, v_note, p_pickup_date)
  returning public.reservations.id, public.reservations.order_code, public.reservations.created_at
  into v_id, v_order_code, v_created;

  return query select v_id, v_order_code, 'pending'::text, v_created;
end;
$$;

revoke all on function public.create_reservation(text, integer, text, text, text, date) from public;
grant execute on function public.create_reservation(text, integer, text, text, text, date) to anon, authenticated;

-- 5) ฟังก์ชันให้ลูกค้าตรวจสอบการจองของตัวเองด้วยเบอร์โทร หรือ รหัสออเดอร์ (RSV-...)
drop function if exists public.reservation_lookup(text);

create or replace function public.reservation_lookup(p_phone text)
returns table (
  id bigint,
  order_code text,
  code text,
  product_name text,
  qty integer,
  customer_name text,
  pickup_date date,
  status text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select r.id, r.order_code, r.code, r.product_name, r.qty, r.customer_name, r.pickup_date, r.status, r.created_at
  from public.reservations r
  where (
    length(regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g')) >= 9
    and r.phone = regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g')
  ) or (
    length(btrim(coalesce(p_phone, ''))) >= 6
    and upper(r.order_code) = upper(btrim(coalesce(p_phone, '')))
  )
  order by r.created_at desc
  limit 20;
$$;

revoke all on function public.reservation_lookup(text) from public;
grant execute on function public.reservation_lookup(text) to anon, authenticated;

-- 6) อัปเดตแคตตาล็อกสาธารณะ (public_catalog) ให้หักยอดที่ติดจอง (pending, confirmed) อัตโนมัติบนหน้าเว็บลูกค้า
--    โดยไม่แตะสต๊อกจริงใน public.products.qty ฝั่งหลังบ้านแอดมิน
drop function if exists public.public_catalog();

create function public.public_catalog()
returns table(
  code text,
  name text,
  category text,
  qty integer,
  price numeric,
  sale_price numeric,
  discount_kind text,
  discount_value numeric,
  discount_until date,
  image text
)
language sql
stable
security definer
set search_path = public
as $$
  with rsv as (
    select r.code, coalesce(sum(r.qty), 0)::integer as reserved_qty
    from public.reservations r
    where r.status in ('pending', 'confirmed')
    group by r.code
  ),
  base as (
    select
      p.code,
      p.name,
      p.category,
      greatest(0, coalesce(p.qty, 0) - coalesce(rsv.reserved_qty, 0))::integer as qty,
      p.image,
      coalesce(
        nullif(p.price, 0),
        nullif(p.cost, 0),
        (select m.price from public.moves m where m.code = p.code and coalesce(m.price, 0) > 0 order by m.date desc limit 1),
        0
      ) as base_price
    from public.products p
    left join rsv on rsv.code = p.code
  )
  select
    b.code,
    b.name,
    b.category,
    b.qty,
    b.base_price as price,
    dc.sale_price,
    dc.kind as discount_kind,
    dc.value as discount_value,
    dc.ends_on as discount_until,
    case when b.image like 'https://%' then b.image else null end as image
  from base b
  left join lateral (
    select
      greatest(0, round(case when d.kind = 'percent' then b.base_price * (1 - d.value / 100) else b.base_price - d.value end, 2)) as sale_price,
      d.kind,
      d.value,
      d.ends_on
    from public.discounts d
    where d.code = b.code
      and d.active
      and current_date between d.starts_on and d.ends_on
      and b.base_price > 0
    order by (case when d.kind = 'percent' then b.base_price * (1 - d.value / 100) else b.base_price - d.value end) asc
    limit 1
  ) dc on true
  order by b.name;
$$;

revoke all on function public.public_catalog() from public;
grant execute on function public.public_catalog() to anon, authenticated;

-- 7) (ทางเลือก) ให้แอดมินยกเลิกการจองที่ค้างเกิน N วันอัตโนมัติ — เปิดใช้เมื่อต้องการ
-- update public.reservations
-- set status = 'cancelled', admin_note = 'ยกเลิกอัตโนมัติ (ไม่มารับสินค้าภายใน 7 วัน)'
-- where status = 'confirmed'
--   and pickup_date is not null
--   and pickup_date < current_date - interval '7 days';
