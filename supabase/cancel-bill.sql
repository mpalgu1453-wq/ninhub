-- ยกเลิกบิลขายได้ภายใน 24 ชั่วโมง (เฉพาะแอดมิน)
-- รันไฟล์นี้ใน Supabase → SQL Editor → New query → วาง → Run
-- วิธีทำงาน: ตรวจสิทธิ์แอดมิน + ตรวจเวลาไม่เกิน 24 ชม. → คืนจำนวนสินค้าเข้าคลัง → ลบรายการขายของบิลนั้น

create or replace function public.cancel_sale(
  p_bill text default null,
  p_id bigint default null
)
returns jsonb
language plpgsql
security definer set search_path = public
as $$
declare
  v_bill text := nullif(btrim(coalesce(p_bill, '')), '');
  v_ids bigint[];
  v_latest timestamptz;
  v_move public.moves;
  v_items integer := 0;
  v_qty integer := 0;
begin
  if auth.uid() is null then
    raise exception 'ต้องล็อกอินก่อน';
  end if;
  if not public.is_admin() then
    raise exception 'เฉพาะแอดมินเท่านั้นที่ยกเลิกบิลได้';
  end if;
  if v_bill is null and p_id is null then
    raise exception 'ไม่พบบิลที่ต้องการยกเลิก';
  end if;

  select array_agg(id), max(date)
    into v_ids, v_latest
    from public.moves
   where kind = 'ขายออก'
     and ((v_bill is not null and bill_id = v_bill)
       or (v_bill is null and id = p_id));

  if v_ids is null then
    raise exception 'ไม่พบรายการขายนี้ (อาจถูกยกเลิกไปแล้ว)';
  end if;
  if now() - v_latest > interval '24 hours' then
    raise exception 'ยกเลิกได้ภายใน 24 ชั่วโมงหลังขายเท่านั้น';
  end if;

  for v_move in select * from public.moves where id = any(v_ids) loop
    update public.products
       set qty = qty + v_move.qty,
           updated_at = now()
     where code = v_move.code;
    v_items := v_items + 1;
    v_qty := v_qty + v_move.qty;
  end loop;

  delete from public.moves where id = any(v_ids);

  return jsonb_build_object('bill', v_bill, 'items', v_items, 'qty', v_qty);
end;
$$;

grant execute on function public.cancel_sale(text, bigint) to authenticated;
revoke execute on function public.cancel_sale(text, bigint) from anon, public;
