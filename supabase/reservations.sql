-- ระบบจองสินค้าจากเว็บลูกค้า (repo: ninhub-shop) → เก็บลงฐานข้อมูลเดียวกัน
-- วิธีใช้: Supabase → SQL Editor → New query → วางทั้งหมด → Run
-- รันซ้ำได้ทุกครั้ง (ไม่ลบข้อมูลการจอง/สินค้า)
--
-- หลักการ:
--   * เว็บลูกค้า (anon) จองได้ผ่านฟังก์ชัน public.create_reservation() เท่านั้น
--   * เว็บลูกค้าอ่านตาราง reservations โดยตรงไม่ได้ (กันข้อมูลลูกค้ารั่ว)
--   * แอดมินในเว็บสต๊อกอ่าน/อัปเดต/ลบได้ตามสิทธิ์ public.is_admin()
--   * การจอง "ไม่ตัดสต๊อกอัตโนมัติ" — สต๊อกจะลดเมื่อบันทึกขายที่หน้า "ขายสินค้า" ตามปกติ

-- 1) ตารางการจอง
create table if not exists public.reservations (
  id bigint generated always as identity primary key,
  code text not null,
  product_name text not null,
  qty integer not null check (qty > 0),
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

create index if not exists reservations_status_idx on public.reservations (status, created_at desc);
create index if not exists reservations_phone_idx on public.reservations (phone);
create index if not exists reservations_code_idx on public.reservations (code);
create index if not exists reservations_created_idx on public.reservations (created_at desc);

-- 2) อัปเดต updated_at อัตโนมัติ
create or replace function public.reservations_touch()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists reservations_touch_trg on public.reservations;
create trigger reservations_touch_trg
before update on public.reservations
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
returns table (id bigint, status text, created_at timestamptz)
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
  v_id bigint;
  v_created timestamptz;
begin
  if length(v_name) < 2 then
    raise exception 'กรุณากรอกชื่อผู้จองอย่างน้อย 2 ตัวอักษร';
  end if;

  if length(v_phone) < 9 or length(v_phone) > 15 then
    raise exception 'กรุณากรอกเบอร์โทรให้ถูกต้อง (9–15 หลัก)';
  end if;

  if v_qty < 1 or v_qty > 20 then
    raise exception 'จำนวนที่จองต้องอยู่ระหว่าง 1–20 ชิ้น';
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

  select * into v_product from public.products where code = p_code;
  if not found then
    raise exception 'ไม่พบสินค้านี้ในระบบ';
  end if;

  if coalesce(v_product.qty, 0) < v_qty then
    raise exception 'สินค้าเหลือไม่พอ (เหลือ % ชิ้น)', coalesce(v_product.qty, 0);
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

  insert into public.reservations (code, product_name, qty, customer_name, phone, note, pickup_date)
  values (p_code, v_product.name, v_qty, v_name, v_phone, v_note, p_pickup_date)
  returning public.reservations.id, public.reservations.created_at into v_id, v_created;

  return query select v_id, 'pending'::text, v_created;
end;
$$;

revoke all on function public.create_reservation(text, integer, text, text, text, date) from public;
grant execute on function public.create_reservation(text, integer, text, text, text, date) to anon, authenticated;

-- 5) ฟังก์ชันให้ลูกค้าตรวจสอบการจองของตัวเองด้วยเบอร์โทร
drop function if exists public.reservation_lookup(text);

create or replace function public.reservation_lookup(p_phone text)
returns table (
  id bigint,
  code text,
  product_name text,
  qty integer,
  pickup_date date,
  status text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select r.id, r.code, r.product_name, r.qty, r.pickup_date, r.status, r.created_at
  from public.reservations r
  where r.phone = regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g')
    and length(regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g')) >= 9
  order by r.created_at desc
  limit 20;
$$;

revoke all on function public.reservation_lookup(text) from public;
grant execute on function public.reservation_lookup(text) to anon, authenticated;

-- 6) (ทางเลือก) ให้แอดมินยกเลิกการจองที่ค้างเกิน N วันอัตโนมัติ — เปิดใช้เมื่อต้องการ
-- update public.reservations
-- set status = 'cancelled', admin_note = 'ยกเลิกอัตโนมัติ (ไม่มารับสินค้าภายใน 7 วัน)'
-- where status = 'confirmed'
--   and pickup_date is not null
--   and pickup_date < current_date - interval '7 days';
