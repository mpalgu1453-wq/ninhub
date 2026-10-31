-- เปิดใช้ Supabase Storage สำหรับเก็บรูปสินค้า + แชร์เป็นลิงก์
-- วิธีใช้: Supabase → SQL Editor → New query → วางทั้งหมด → Run (ครั้งเดียว)
-- หลังรันแล้ว เว็บจะอัปโหลดรูปขึ้น bucket "product-images" และเก็บแค่ลิงก์ในตาราง products

-- 1) สร้าง bucket แบบ public (อ่านรูปได้โดยไม่ต้องล็อกอิน)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'product-images',
  'product-images',
  true,
  5242880,
  array['image/jpeg','image/png','image/webp','image/gif']
)
on conflict (id) do update
  set public = true,
      file_size_limit = 5242880,
      allowed_mime_types = array['image/jpeg','image/png','image/webp','image/gif'];

-- 2) อ่านรูปได้ทุกคน (bucket public)
drop policy if exists "product_images_read" on storage.objects;
create policy "product_images_read" on storage.objects
  for select using (bucket_id = 'product-images');

-- 3) เฉพาะแอดมินเท่านั้นที่อัปโหลด / แก้ / ลบรูปได้
drop policy if exists "product_images_insert" on storage.objects;
create policy "product_images_insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'product-images' and public.is_admin());

drop policy if exists "product_images_update" on storage.objects;
create policy "product_images_update" on storage.objects
  for update to authenticated
  using (bucket_id = 'product-images' and public.is_admin())
  with check (bucket_id = 'product-images' and public.is_admin());

drop policy if exists "product_images_delete" on storage.objects;
create policy "product_images_delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'product-images' and public.is_admin());
