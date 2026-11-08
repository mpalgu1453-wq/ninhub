-- เปิดแคตตาล็อกสำหรับลูกค้า + ระบบส่วนลดตามช่วงวันที่ (ไม่ต้องเข้าสู่ระบบ)
-- วิธีใช้: Supabase → SQL Editor → New query → วางทั้งหมด → Run
-- รันซ้ำได้ทุกครั้งที่อัปเดตไฟล์นี้ (ไม่ลบข้อมูลสินค้า/ส่วนลด)
-- หน้าเข้าสู่ระบบมีปุ่ม "🛍️ ดูสินค้าสำหรับลูกค้า" และแอดมินมีเมนู "🏷️ ส่วนลด"

-- 1) ราคาขายหน้าร้าน
alter table public.products add column if not exists price numeric not null default 0 check (price >= 0);

-- 2) ตารางส่วนลดรายสินค้า (เลือกช่วงวันที่ได้)
create table if not exists public.discounts (
  id bigint generated always as identity primary key,
  code text not null references public.products(code) on delete cascade,
  kind text not null check (kind in ('percent','amount')),
  value numeric not null check (value > 0),
  starts_on date not null default current_date,
  ends_on date not null,
  note text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_on >= starts_on),
  check ((kind = 'percent' and value <= 100) or kind = 'amount')
);

create index if not exists discounts_code_idx on public.discounts (code);
create index if not exists discounts_dates_idx on public.discounts (active, starts_on, ends_on);

alter table public.discounts enable row level security;

drop policy if exists "discounts_select_authenticated" on public.discounts;
create policy "discounts_select_authenticated"
on public.discounts for select to authenticated
using (true);

drop policy if exists "discounts_insert_admin" on public.discounts;
create policy "discounts_insert_admin"
on public.discounts for insert to authenticated
with check (public.is_admin());

drop policy if exists "discounts_update_admin" on public.discounts;
create policy "discounts_update_admin"
on public.discounts for update to authenticated
using (public.is_admin())
with check (public.is_admin());

drop policy if exists "discounts_delete_admin" on public.discounts;
create policy "discounts_delete_admin"
on public.discounts for delete to authenticated
using (public.is_admin());

-- 3) ฟังก์ชันแคตตาล็อกสาธารณะ (คืนราคาหลังหักส่วนลดที่ถูกที่สุดของวันนี้)
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
  select
    p.code,
    p.name,
    p.category,
    p.qty,
    p.price,
    dc.sale_price,
    dc.kind as discount_kind,
    dc.value as discount_value,
    dc.ends_on as discount_until,
    case when p.image like 'https://%' then p.image else null end as image
  from public.products p
  left join lateral (
    select
      greatest(0, round(case when d.kind = 'percent' then p.price * (1 - d.value / 100) else p.price - d.value end, 2)) as sale_price,
      d.kind,
      d.value,
      d.ends_on
    from public.discounts d
    where d.code = p.code
      and d.active
      and current_date between d.starts_on and d.ends_on
      and p.price > 0
    order by (case when d.kind = 'percent' then p.price * (1 - d.value / 100) else p.price - d.value end) asc
    limit 1
  ) dc on true
  order by p.name;
$$;

revoke all on function public.public_catalog() from public;
grant execute on function public.public_catalog() to anon, authenticated;
