begin;
-- Adjustments must be exactly representable by the stock and movement columns.
create or replace function public.adjust_inventory(p_ingredient_id uuid,p_quantity numeric,p_type text,p_reason text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_ingredient public.ingredients%rowtype;
begin
 select * into v_ingredient from public.ingredients where id=p_ingredient_id for update;
 if auth.uid() is null or not found or v_ingredient.restaurant_id<>auth.uid() then raise exception 'Ingrediente no encontrado';end if;
 if p_quantity is null or p_quantity='NaN'::numeric or p_quantity=0 or p_quantity<>round(p_quantity,3) or p_type is null or p_type not in ('purchase','adjustment','waste') or length(trim(coalesce(p_reason,'')))<2 then raise exception 'Cantidad, tipo o motivo inválido';end if;
 if (p_type='purchase' and p_quantity<0) or (p_type='waste' and p_quantity>0) then raise exception 'Una compra suma existencias y una merma las descuenta';end if;
 if v_ingredient.stock+p_quantity<0 then raise exception 'El ajuste supera la existencia disponible (% %)',v_ingredient.stock,v_ingredient.unit;end if;
 update public.ingredients set stock=stock+p_quantity,updated_at=now() where id=p_ingredient_id returning * into v_ingredient;
 insert into public.inventory_movements(restaurant_id,ingredient_id,movement_type,quantity,reason,created_by)
 values(v_ingredient.restaurant_id,p_ingredient_id,p_type,p_quantity,left(trim(p_reason),200),auth.uid());
 return to_jsonb(v_ingredient);
end;$$;
commit;
