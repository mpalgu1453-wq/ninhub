-- ============================================================
-- อัปเกรด: นำเข้า Excel แล้วสร้างสินค้าใหม่อัตโนมัติ
-- วิธีใช้: Supabase Dashboard > SQL Editor > New query
--          คัดลอกไฟล์นี้ทั้งหมด > วาง > Run
-- ไฟล์นี้ปลอดภัยกับข้อมูลเดิม (ไม่ลบตาราง ไม่ลบข้อมูล)
-- ============================================================

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
        coalesce(v_category, 'อื่นๆ'),
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

    -- รหัสมีอยู่แล้ว
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
