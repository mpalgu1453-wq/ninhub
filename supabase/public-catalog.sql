-- เปิดแคตตาล็อกสำหรับลูกค้า (ไม่ต้องเข้าสู่ระบบ)
-- วิธีใช้: Supabase → SQL Editor → New query → วางทั้งหมด → Run
-- รันซ้ำได้ทุกครั้งที่อัปเดตไฟล์นี้ (ไม่ลบข้อมูลสินค้า)
-- หน้าเข้าสู่ระบบจะมีปุ่ม "🛍️ ดูสินค้าสำหรับลูกค้า" ให้ลูกค้ากดดูสินค้าได้
-- เปิดเผยเฉพาะรหัส ชื่อ หมวดหมู่ จำนวนคงเหลือ ราคาขาย และลิงก์รูป — ไม่รวมต้นทุน/บาร์โค้ด

-- 1) เพิ่มคอลัมน์ราคาขายหน้าร้าน (ถ้ายังไม่มี)
alter table public.products add column if not exists price numeric not null default 0 check (price >= 0);

-- 2) สร้างฟังก์ชันใหม่ (ต้อง drop ก่อนเพราะชนิดคอลัมน์ที่คืนเปลี่ยน)
drop function if exists public.public_catalog();

create function public.public_catalog()
returns table(code text, name text, category text, qty integer, price numeric, image text)
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
    p.price,
    case when p.image like 'https://%' then p.image else null end as image
  from public.products p
  order by p.name;
$$;

revoke all on function public.public_catalog() from public;
grant execute on function public.public_catalog() to anon, authenticated;
