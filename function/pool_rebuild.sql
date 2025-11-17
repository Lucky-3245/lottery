-- FUNCTION: lottery.pool_rebuild(integer)

-- DROP FUNCTION IF EXISTS lottery.pool_rebuild(integer);

CREATE OR REPLACE FUNCTION lottery.pool_rebuild(
	p_pool_id integer)
    RETURNS integer
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    v_total_new_prizes integer := 0;
    v_start_time timestamp;
    v_elapsed_microseconds integer;
BEGIN
    -- 记录函数开始时间
    v_start_time := clock_timestamp();
    RAISE NOTICE '开始生成奖池序列:奖池ID=%', p_pool_id;

    -- 验证输入参数
    IF p_pool_id IS NULL THEN
        RAISE EXCEPTION '奖池ID不能为空';
    END IF;

    -- 验证奖池是否存在
    IF NOT EXISTS (SELECT 1 FROM lottery.pool_prize WHERE pool_id = ABS(p_pool_id) LIMIT 1) THEN
        RAISE EXCEPTION '奖池 % (或其主奖池 % )不存在或没有奖品配置', p_pool_id, ABS(p_pool_id);
    END IF;

    ---步骤1: 统计新奖品数量
    RAISE NOTICE '正在统计奖池 % 的奖品数量...', p_pool_id;
    SELECT COALESCE(SUM(quantity), 0) INTO v_total_new_prizes 
    FROM lottery.pool_prize 
    WHERE pool_id = ABS(p_pool_id);
    
    v_elapsed_microseconds := EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000000;
    RAISE NOTICE '[%μs] 步骤1: 统计新奖品数量完成,总数=%', v_elapsed_microseconds, v_total_new_prizes;

    -- 如果没有奖品,更新状态并返回
    IF v_total_new_prizes = 0 THEN
        RAISE NOTICE '奖池 % 没有奖品,更新状态表...', p_pool_id;
        
        UPDATE lottery.pool_status 
        SET 
            seq = 0,
            total_count = 0,
            update_count = update_count + 1
        WHERE pool_id = p_pool_id;
        
        v_elapsed_microseconds := EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000000;
        RAISE NOTICE '[%μs] 函数执行完成,无奖品情况。', v_elapsed_microseconds;
        RETURN 0;
    END IF;

    ---步骤2: 清空目标奖池旧序列
    RAISE NOTICE '清空奖池 % 的旧序列...', p_pool_id;
    DELETE FROM lottery.pool_sequence WHERE pool_id = p_pool_id;
    v_elapsed_microseconds := EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000000;
    RAISE NOTICE '[%μs] 步骤2: 清空奖池旧序列完成。', v_elapsed_microseconds;

    ---步骤3: 构建并插入新的奖池序列 - 简化高效版本
    RAISE NOTICE '正在构建奖池序列...';
    
    -- 首先创建一个包含所有奖品的临时表（展开数量）
    CREATE TEMP TABLE temp_all_prizes AS
    SELECT 
        pp.prize_id,
        pp.position,
        generate_series(1, pp.quantity) as instance_num
    FROM lottery.pool_prize pp
    WHERE pp.pool_id = ABS(p_pool_id);

    -- 创建序列号映射表
    CREATE TEMP TABLE temp_sequence_mapping AS
    WITH fixed_positions AS (
        SELECT 
            prize_id,
            CASE
                WHEN position > 0 THEN position
                ELSE v_total_new_prizes + position + 1
            END AS sequence_order
        FROM temp_all_prizes
        WHERE position <> 0
    ),
    random_prizes AS (
        SELECT 
            prize_id,
            ROW_NUMBER() OVER (ORDER BY random()) as rn
        FROM temp_all_prizes
        WHERE COALESCE(position, 0) = 0
    ),
    all_fixed_positions AS (
        SELECT 
            CASE
                WHEN position > 0 THEN position
                ELSE v_total_new_prizes + position + 1
            END AS fixed_pos
        FROM temp_all_prizes
        WHERE position <> 0
    ),
    available_positions AS (
        SELECT 
            ROW_NUMBER() OVER (ORDER BY gs) as pos_rn,
            gs as available_pos
        FROM generate_series(1, v_total_new_prizes) gs
        WHERE gs NOT IN (SELECT fixed_pos FROM all_fixed_positions)
    )
    SELECT 
        rp.prize_id,
        ap.available_pos as sequence_order
    FROM random_prizes rp
    JOIN available_positions ap ON rp.rn = ap.pos_rn;

    -- 插入固定位置的奖品
    INSERT INTO lottery.pool_sequence(pool_id, sequence_order, prize_id)
    SELECT 
        p_pool_id,
        CASE
            WHEN position > 0 THEN position
            ELSE v_total_new_prizes + position + 1
        END,
        prize_id
    FROM temp_all_prizes
    WHERE position <> 0;

    -- 插入随机位置的奖品
    INSERT INTO lottery.pool_sequence(pool_id, sequence_order, prize_id)
    SELECT p_pool_id, sequence_order, prize_id
    FROM temp_sequence_mapping;

    -- 清理临时表
    DROP TABLE temp_all_prizes;
    DROP TABLE temp_sequence_mapping;

    v_elapsed_microseconds := EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000000;
    RAISE NOTICE '[%μs] 步骤3: 构建并插入新的奖池序列完成。', v_elapsed_microseconds;

    ---步骤4: 更新奖池状态表
    RAISE NOTICE '奖池序列构建完成,正在更新状态表...';
    UPDATE lottery.pool_status 
    SET 
        seq = 0,
        total_count = v_total_new_prizes,
        update_count = update_count + 1
    WHERE pool_id = p_pool_id;
    
    -- 检查是否成功更新
    IF NOT FOUND THEN
        RAISE EXCEPTION '奖池状态记录不存在,无法更新奖池ID: %', p_pool_id;
    END IF;

    v_elapsed_microseconds := EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000000;
    RAISE NOTICE '[%μs] 步骤4: 更新状态表完成。', v_elapsed_microseconds;

    RAISE NOTICE '奖池 % 序列生成成功,总奖品数: %', p_pool_id, v_total_new_prizes;
    v_elapsed_microseconds := EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000000;
    RAISE NOTICE '[%μs] 函数执行成功,总耗时。', v_elapsed_microseconds;
    
    RETURN v_total_new_prizes;

EXCEPTION
    WHEN OTHERS THEN
        DROP TABLE IF EXISTS temp_all_prizes;
        DROP TABLE IF EXISTS temp_sequence_mapping;
        RAISE WARNING 'pool_rebuild 函数执行失败,奖池ID:% 错误信息:% ', 
                     COALESCE(p_pool_id, 0), SQLERRM;
        v_elapsed_microseconds := EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000000;
        RAISE WARNING '[%μs] 函数执行失败,总耗时。', v_elapsed_microseconds;
        RAISE;
END
$BODY$;
