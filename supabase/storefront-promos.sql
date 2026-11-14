-- ตารางโปรโมชั่นหน้าร้าน (Hero Slider 6 ช่อง + โปรโมชั่นพิเศษ Bento 5 ช่อง)
-- วิธีใช้: Supabase → SQL Editor → New query → วางทั้งหมด → Run (ครั้งเดียว)
-- รันซ้ำได้ปลอดภัย (ไม่ลบข้อมูลเดิมที่แก้ไขไว้)

create table if not exists public.storefront_promos (
  slot text primary key,
  kind text not null check (kind in ('hero', 'bento')),
  title text not null default '',
  subtitle text not null default '',
  badge text not null default '',
  description text not null default '',
  image text not null default '',
  fit text not null default 'auto' check (fit in ('auto', 'cover', 'contain')),
  product_codes text[] not null default '{}',
  sort_order integer not null default 0,
  active boolean not null default true,
  updated_at timestamptz not null default now()
);

alter table public.storefront_promos enable row level security;

drop policy if exists "storefront_promos_select_public" on public.storefront_promos;
create policy "storefront_promos_select_public"
on public.storefront_promos for select to anon, authenticated
using (active = true or public.is_admin());

drop policy if exists "storefront_promos_insert_admin" on public.storefront_promos;
create policy "storefront_promos_insert_admin"
on public.storefront_promos for insert to authenticated
with check (public.is_admin());

drop policy if exists "storefront_promos_update_admin" on public.storefront_promos;
create policy "storefront_promos_update_admin"
on public.storefront_promos for update to authenticated
using (public.is_admin())
with check (public.is_admin());

drop policy if exists "storefront_promos_delete_admin" on public.storefront_promos;
create policy "storefront_promos_delete_admin"
on public.storefront_promos for delete to authenticated
using (public.is_admin());

grant select on public.storefront_promos to anon, authenticated;
grant insert, update, delete on public.storefront_promos to authenticated;

-- สร้างช่องมาตรฐาน 11 ช่อง (Hero 6 + Bento 5) หากยังไม่มี
insert into public.storefront_promos (slot, kind, title, subtitle, badge, description, sort_order) values
  ('hero-1', 'hero', 'โปรโมชั่นแบนเนอร์ 1', 'พร้อมจองแล้ววันนี้ · รับสินค้าภายใน 3 วัน', 'แนะนำ', '', 1),
  ('hero-2', 'hero', 'โปรโมชั่นแบนเนอร์ 2', 'พร้อมจองแล้ววันนี้ · รับสินค้าภายใน 3 วัน', 'แนะนำ', '', 2),
  ('hero-3', 'hero', 'โปรโมชั่นแบนเนอร์ 3', 'พร้อมจองแล้ววันนี้ · รับสินค้าภายใน 3 วัน', 'แนะนำ', '', 3),
  ('hero-4', 'hero', 'โปรโมชั่นแบนเนอร์ 4', 'พร้อมจองแล้ววันนี้ · รับสินค้าภายใน 3 วัน', 'แนะนำ', '', 4),
  ('hero-5', 'hero', 'โปรโมชั่นแบนเนอร์ 5', 'พร้อมจองแล้ววันนี้ · รับสินค้าภายใน 3 วัน', 'แนะนำ', '', 5),
  ('hero-6', 'hero', 'โปรโมชั่นแบนเนอร์ 6', 'พร้อมจองแล้ววันนี้ · รับสินค้าภายใน 3 วัน', 'แนะนำ', '', 6),
  ('bento-main', 'bento', 'โปรโมชั่นพิเศษหลัก', 'ดีลพิเศษประจำร้าน Power Buy Central Northville', 'โปรโมชั่นพิเศษ', '', 10),
  ('bento-1', 'bento', 'โปรโมชั่นพิเศษ 1', 'สินค้าแนะนำราคาพิเศษ', 'โปรโมชั่น', '', 11),
  ('bento-2', 'bento', 'โปรโมชั่นพิเศษ 2', 'อุปกรณ์เสริมและจอยเกม', 'โปรโมชั่น', '', 12),
  ('bento-3', 'bento', 'โปรโมชั่นพิเศษ 3', 'ชุดเครื่องเกมสุดคุ้ม', 'โปรโมชั่น', '', 13),
  ('bento-4', 'bento', 'โปรโมชั่นพิเศษ 4', 'แผ่นเกมฮิตและมาใหม่', 'โปรโมชั่น', '', 14)
on conflict (slot) do nothing;
