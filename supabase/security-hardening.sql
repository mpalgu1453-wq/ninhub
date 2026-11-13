-- ความปลอดภัยของฐานข้อมูล (ทำครั้งเดียว / รันซ้ำได้ ไม่ลบข้อมูล)
-- วิธีใช้: Supabase → SQL Editor → New query → วางทั้งหมด → Run
--
-- ไฟล์นี้เพิ่ม:
--   1) public.security_audit()        — ตรวจว่าทุกตารางใน public เปิด RLS ครบหรือไม่ (แอดมินเท่านั้น)
--   2) public.reservations_safe       — view การจองที่ปิดเบอร์โทร (สำหรับ pgAdmin/ผู้ใช้ readonly)
--   3) public.products_safe           — view สินค้าที่ไม่แสดงต้นทุน/บาร์โค้ด
--   4) role readonly_login            — ผู้ใช้ฐานข้อมูลแบบอ่านอย่างเดียว (ไม่มีรหัสผ่านในไฟล์)
--   5) public.purge_old_reservations() — ล้างการจองเก่า (completed/cancelled) ตามจำนวนวัน
--
-- สิ่งที่ต้องทำเองในหน้าเว็บ (ทำใน Dashboard ไม่ใช่ SQL):
--   * Supabase → Account → MFA: เปิด 2FA
--   * Project Settings → Database → Network Restrictions: จำกัด IP ที่ต่อฐานข้อมูลตรง
--   * Project Settings → Database → Reset database password เมื่อสงสัยว่ารหัสผ่านรั่ว
--   * Authentication → Policies: ตั้งรหัสผ่านขั้นต่ำ 12 ตัวอักษร + เปิด Leaked password protection

-- 1) ตรวจ RLS ทุกตาราง -------------------------------------------------------
create or replace function public.security_audit()
returns table (table_name text, rls_enabled boolean, policy_count bigint)
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    raise exception 'ต้องเป็นแอดมินเท่านั้น';
  end if;

  return query
    select c.relname::text,
           c.relrowsecurity,
           (select count(*) from pg_policies p
             where p.schemaname = 'public' and p.tablename = c.relname)
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r'
    order by c.relname;
end;
$$;

revoke all on function public.security_audit() from public;
grant execute on function public.security_audit() to authenticated;

-- 2) view การจองที่ปิดเบอร์โทร (เจ้าของ view คือ postgres จึงอ่านข้อมูลได้แม้มี RLS)
drop view if exists public.reservations_safe;
create view public.reservations_safe as
select
  id,
  code,
  product_name,
  qty,
  customer_name,
  case
    when length(phone) >= 7 then left(phone, 3) || '****' || right(phone, 3)
    else '****'
  end as phone_masked,
  note,
  pickup_date,
  status,
  admin_note,
  created_at,
  updated_at
from public.reservations;

comment on view public.reservations_safe is 'การจองสำหรับผู้ใช้ฐานข้อมูลแบบอ่านอย่างเดียว (เบอร์โทรถูกปิดบางส่วน)';
revoke all on public.reservations_safe from public;

-- 3) view สินค้าที่ไม่เปิดต้นทุน/บาร์โค้ด
drop view if exists public.products_safe;
create view public.products_safe as
select code, name, category, qty, price, image, created_at, updated_at
from public.products;

comment on view public.products_safe is 'สินค้าสำหรับผู้ใช้ฐานข้อมูลแบบอ่านอย่างเดียว (ไม่มีต้นทุน/บาร์โค้ด)';
revoke all on public.products_safe from public;

-- 4) role อ่านอย่างเดียว (ไม่เก็บรหัสผ่านใน repo) -----------------------------
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'readonly_login') then
    execute 'create role readonly_login';
  end if;
end;
$$;

grant connect on database postgres to readonly_login;
grant usage on schema public to readonly_login;
grant select on public.reservations_safe to readonly_login;
grant select on public.products_safe to readonly_login;

-- ตั้งรหัสผ่านครั้งเดียวใน SQL Editor (รันบรรทัดล่างโดยแก้รหัสเอง แล้วลบทิ้ง):
-- alter role readonly_login with login password 'ใส่รหัสยาวอย่างน้อย 20 ตัว';
--
-- ปิดการเชื่อมต่อชั่วคราวเมื่อไม่ใช้งาน:
-- alter role readonly_login with nologin;
--
-- ตรวจสิทธิ์ของ role นี้ (ควรเห็นเฉพาะ 2 view):
-- select table_name, privilege_type from information_schema.role_table_grants where grantee = 'readonly_login';

-- 5) ล้างการจองเก่า (ข้อมูลส่วนบุคคลเก็บเท่าที่จำเป็น) -------------------------
create or replace function public.purge_old_reservations(p_days integer default 90)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_deleted integer;
begin
  if auth.uid() is not null and not public.is_admin() then
    raise exception 'ต้องเป็นแอดมินเท่านั้น';
  end if;

  if p_days < 30 then
    raise exception 'ลบได้เฉพาะข้อมูลที่เก่ากว่า 30 วันขึ้นไป (กันลบพลาด)';
  end if;

  delete from public.reservations
   where status in ('completed', 'cancelled')
     and created_at < now() - (p_days || ' days')::interval;

  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

revoke all on function public.purge_old_reservations(integer) from public;
grant execute on function public.purge_old_reservations(integer) to authenticated;

-- ตัวอย่างการใช้งาน (ทำมือทุกครั้ง ไม่ได้ตั้งเวลาอัตโนมัติ):
-- select public.purge_old_reservations(90);
