-- เปิดแคตตาล็อกสำหรับลูกค้า (ไม่ต้องเข้าสู่ระบบ)
-- วิธีใช้: Supabase → SQL Editor → New query → วางทั้งหมด → Run (ครั้งเดียว)
-- หน้าเข้าสู่ระบบจะมีปุ่ม "🛍️ ดูสินค้าสำหรับลูกค้า" ให้ลูกค้ากดดูสินค้าได้
-- เปิดเผยเฉพาะรหัส ชื่อ หมวดหมู่ จำนวนคงเหลือ และลิงก์รูป — ไม่รวมต้นทุน/บาร์โค้ด

create or replace function public.public_catalog()
returns table(code text, name text, category text, qty integer, image text)
language sql
stable
security definer
set search_path = public
as $$
  select
    p.code,
    p.name,
    p.category,
    p.qty,
    case when p.image like 'https://%' then p.image else null end as image
  from public.products p
  order by p.name;
$$;

revoke all on function public.public_catalog() from public;
grant execute on function public.public_catalog() to anon, authenticated;
