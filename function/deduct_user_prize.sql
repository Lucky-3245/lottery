-- FUNCTION: lottery.deduct_user_prize(bigint, integer, integer)

-- DROP FUNCTION IF EXISTS lottery.deduct_user_prize(bigint, integer, integer);

CREATE OR REPLACE FUNCTION lottery.deduct_user_prize(
	p_user_id bigint,
	p_prize_id integer,
	p_quantity integer)
    RETURNS boolean
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    v_rows_affected INTEGER;
    v_result BOOLEAN := FALSE;
BEGIN
    -- 验证礼物数量必须大于0
    IF p_quantity <= 0 THEN
        RETURN FALSE;
    END IF;

    -- 使用CTE链式操作:先更新,再删除零数量记录,最后记录日志
    WITH validate_and_update AS (
        -- 验证并更新数量
        UPDATE lottery.user_backpack
        SET quantity = quantity - p_quantity,
            updated_at = NOW()
        WHERE user_id = p_user_id 
          AND prize_id = p_prize_id 
          AND quantity >= p_quantity  -- 确保数量足够
        RETURNING user_id, prize_id, (quantity - p_quantity) as new_quantity
    ),
    delete_zero AS (
        -- 删除数量为0的记录
        DELETE FROM lottery.user_backpack
        WHERE user_id = p_user_id 
          AND prize_id = p_prize_id 
          AND quantity = 0
    ),
    log_insert AS (
        -- 记录操作日志
        INSERT INTO lottery.user_draw_log (user_id, game_id, prize_id, quantity_won, pool_id)
        SELECT user_id, 0, prize_id, -p_quantity, 0
        FROM validate_and_update
    )
    SELECT COUNT(*) INTO v_rows_affected FROM validate_and_update;

    -- 如果更新成功（影响了行）,返回TRUE
    v_result := (v_rows_affected > 0);
    
    RETURN v_result;
EXCEPTION
    WHEN OTHERS THEN
        RETURN FALSE;
END;
$BODY$;