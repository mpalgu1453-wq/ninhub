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

    -- รหัสมีอยู่แล้ว
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

-- ย้ายสินค้าที่มีชื่อหมวดหมู่นอกเหนือจากรายการหลัก (เช่น เครื่อง, JOY&ACC จาก Excel) ให้เป็น "ไม่มีหมวดหมู่" (รันซ้ำได้)
update public.products
set category = 'ไม่มีหมวดหมู่'
where category is null
   or btrim(category) not in ('เครื่องเกม', 'ตุ๊กตา', 'จอยเกม/ACC', 'แผ่นเกม', 'ของแถม', 'ไม่มีหมวดหมู่');

-- บิลขายแบบหลายรายการ: เพิ่ม bill_id ให้ตาราง moves (รันซ้ำได้)
alter table public.moves add column if not exists bill_id text;
create index if not exists moves_bill_idx on public.moves (bill_id);

-- RPC: บันทึกหลายรายการในบิลเดียว (ขาย/รับเข้า/โอน) อัปเดตสต๊อกในครั้งเดียว
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
