-- จำกัดสิทธิ์บันทึกการเคลื่อนไหวสินค้า (รับเข้า / ขายออก / โอนออก) ให้เฉพาะแอดมิน
-- รันไฟล์นี้ใน Supabase → SQL Editor (รันซ้ำได้ ปลอดภัย)
-- ผลลัพธ์: พนักงาน (role = staff) บันทึกไม่ได้เลย แม้เรียก API ตรง ๆ

-- 1) record_move: เฉพาะแอดมิน
create or replace function public.record_move(
  p_code text,
  p_kind text,
  p_qty integer,
  p_price numeric default 0,
  p_store text default null,
  p_note text default null
)
returns public.moves
language plpgsql
security definer set search_path = public
as $$
declare
  v_product public.products;
  v_before integer;
  v_after integer;
  v_move public.moves;
begin
  if auth.uid() is null then
    raise exception 'ต้องล็อกอินก่อนบันทึกรายการ';
  end if;

  if not public.is_admin() then
    raise exception 'เฉพาะแอดมินเท่านั้นที่บันทึกการเคลื่อนไหวสินค้าได้';
  end if;

  select * into v_product from public.products where code = p_code for update;
  if not found then
    raise exception 'ไม่พบรหัสสินค้า: %', p_code;
  end if;

  if p_qty is null or p_qty <= 0 then
    raise exception 'จำนวนต้องมากกว่า 0';
  end if;

  v_before := v_product.qty;
  if p_kind = 'รับเข้า' then
    v_after := v_before + p_qty;
  elsif p_kind in ('ขายออก', 'โอนออก') then
    v_after := v_before - p_qty;
    if v_after < 0 then
      raise exception 'จำนวนไม่พอ: มี % ชิ้น', v_before;
    end if;
  elsif p_kind = 'ตรวจนับ' then
    v_after := p_qty;
  else
    raise exception 'ประเภทรายการไม่ถูกต้อง: %', p_kind;
  end if;

  update public.products set qty = v_after, updated_at = now() where code = p_code;

  insert into public.moves (kind, code, name, qty, price, store, note, before_qty, after_qty, created_by)
  values (p_kind, p_code, v_product.name, p_qty, coalesce(p_price,0), p_store, p_note, v_before, v_after, auth.uid())
  returning * into v_move;

  return v_move;
end;
$$;

grant execute on function public.record_move(text, text, integer, numeric, text, text) to authenticated;
revoke execute on function public.record_move(text, text, integer, numeric, text, text) from anon, public;

-- 2) record_bill: เฉพาะแอดมิน
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
  if not public.is_admin() then
    raise exception 'เฉพาะแอดมินเท่านั้นที่บันทึกการเคลื่อนไหวสินค้าได้';
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
