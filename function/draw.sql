-- FUNCTION: lottery.draw(integer, bigint, integer)

-- DROP FUNCTION IF EXISTS lottery.draw(integer, bigint, integer);

CREATE OR REPLACE FUNCTION lottery.draw(
	p_game_id integer,
	p_user_id bigint,
	p_draw_count integer DEFAULT 1)
    RETURNS TABLE(result_prize_id integer, result_parent_id integer, result_prize_name character varying, result_prize_type text, result_game_type text, result_total_quantity bigint, result_total_value numeric) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE SECURITY DEFINER PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    v_start_time TIMESTAMP;
    v_elapsed_microseconds BIGINT;
	v_pool_record RECORD;
    -- 用户 & 游戏数据
    v_user_balance numeric(12,2);
    v_user_profit_loss numeric(12,2);
    v_user_turnover numeric(12,2);
    v_user_level integer;

    -- 奖池 & 抽奖逻辑
    v_selected_pool_id integer;
    v_main_pool_id integer; -- 主奖池ID (配置ID)
    v_cache_record record;
    v_next_pool_id integer;
    
    -- 奖池参数
    v_draw_price numeric(12,2);
    v_ticket_ids jsonb;
    v_draw_mode lottery.draw_mode_enum;
    v_gift_multiplier integer;
    v_is_separately boolean;
    v_pool_auto_create boolean;

    -- 成本与收益
    v_draw_cost numeric(12,2);
    v_total_winnings_value_with_multiplier numeric(12,2) := 0;
    v_total_winnings_value numeric(12,2) := 0;

    -- 抽奖结果变量
    v_old_seq integer;
    v_new_seq integer;
    i integer;
    v_total_count integer;
    v_actual_draw_count integer; -- 实际抽奖次数
    v_current_seq integer;

    -- 并发控制
    max_retries integer := 5;
    retry_count integer := 0;
    v_excluded_pool_ids integer[] := ARRAY[]::integer[];
    success boolean := false;

    -- 聚合输出
    v_aggregated_output RECORD;

BEGIN
    -- 步骤0: 参数校验
    IF p_draw_count <= 0 THEN
        RAISE EXCEPTION '抽奖次数必须为正整数.';
    END IF;

    v_actual_draw_count := p_draw_count; -- 默认等于传入参数
    v_start_time := clock_timestamp();

    -- 确保临时表存在并清空
    CREATE TEMP TABLE IF NOT EXISTS temp_draw_results (pool_id integer, prize_id integer, quantity integer, value numeric) ON COMMIT DROP;
    TRUNCATE TABLE temp_draw_results;

    v_elapsed_microseconds := EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000000;
    RAISE NOTICE '[%μs] 步骤1: 开始 version:1', v_elapsed_microseconds;

    SELECT pc.draw_price, pc.ticket_ids, pc.draw_mode, pc.gift_multiplier, pc.is_separately
    INTO v_draw_price, v_ticket_ids, v_draw_mode, v_gift_multiplier, v_is_separately
    FROM lottery.pool_cache pc
    WHERE pc.game_id = p_game_id
    ORDER BY pc.priority DESC
    LIMIT 1;

    IF NOT FOUND THEN
        v_elapsed_microseconds := EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000000;
        RAISE EXCEPTION '[%μs] 错误: 奖池未配置.game_id:% user_id:%', v_elapsed_microseconds,p_game_id,p_user_id;
    END IF;

    v_elapsed_microseconds := EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000000;
    RAISE NOTICE '[%μs] 步骤2: 获取奖池参数完成. draw_mode=%, draw_price=%.', v_elapsed_microseconds, v_draw_mode, v_draw_price;

    IF v_is_separately THEN
        -- 使用 INSERT ... ON CONFLICT 来原子化地创建用户数据,避免并发冲突
        INSERT INTO lottery.user_data (id, game_id, balance, profit_loss, turnover, level)
        VALUES (p_user_id, p_game_id, 0, 0, 0, 0)
        ON CONFLICT (id, game_id) DO NOTHING;

        -- 无论之前是否存在,现在都直接 SELECT FOR UPDATE 来锁定并获取数据
        SELECT ud.balance, ud.profit_loss, ud.turnover, ud.level
        INTO v_user_balance, v_user_profit_loss, v_user_turnover, v_user_level
        FROM lottery.user_data ud
        WHERE ud.id = p_user_id AND ud.game_id = p_game_id FOR UPDATE;
    ELSE
        -- 对全局数据也应用相同的逻辑
        INSERT INTO lottery.user_data (id, game_id, balance, profit_loss, turnover, level)
        VALUES (p_user_id, 0, 0, 0, 0, 0)
        ON CONFLICT (id, game_id) DO NOTHING;

        SELECT ud.balance, ud.profit_loss, ud.turnover, ud.level
        INTO v_user_balance, v_user_profit_loss, v_user_turnover, v_user_level
        FROM lottery.user_data ud
        WHERE ud.id = p_user_id AND ud.game_id = 0 FOR UPDATE;
    END IF;

    v_elapsed_microseconds := EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000000;
    RAISE NOTICE '[%μs] 用户数据: balance=%, level=%, turnover=%, profit_loss=%.', v_elapsed_microseconds, v_user_balance, v_user_level, v_user_turnover, v_user_profit_loss;

    IF v_draw_mode IN ('COIN', 'COIN_DELAYED') THEN
        v_draw_cost := v_draw_price * p_draw_count;
        v_elapsed_microseconds := EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000000;
        RAISE NOTICE '[%μs] 步骤4: COIN模式, 预计扣款=%.', v_elapsed_microseconds, v_draw_cost;

	ELSIF v_draw_mode IN ('GIFT', 'GIFT_DELAYED') THEN
	    -- 提取multiplier并计算实际抽奖次数
	    v_gift_multiplier := COALESCE((v_ticket_ids->>'multiplier')::integer, 1);
    	v_actual_draw_count := p_draw_count * v_gift_multiplier;
	    
	    -- 验证门票（直接检查是否存在不足的门票）
	    FOR v_selected_pool_id, v_user_balance, v_user_level IN
	        SELECT req.key::integer, req.value::integer * p_draw_count, COALESCE(ub.quantity, 0)
	        FROM jsonb_each_text(v_ticket_ids) req
	        LEFT JOIN lottery.user_backpack ub ON ub.prize_id = req.key::integer AND ub.user_id = p_user_id
	        WHERE req.key <> 'multiplier' AND (ub.quantity IS NULL OR ub.quantity < req.value::integer * p_draw_count)
	        LIMIT 1
	    LOOP
	        RAISE EXCEPTION '门票不足 prize_id=%, 需要: %, 拥有: %', v_selected_pool_id, v_user_balance, v_user_level;
	    END LOOP;
	
	    -- 扣除门票
	    UPDATE lottery.user_backpack ub 
	    SET quantity = ub.quantity - req.value::integer * p_draw_count, updated_at = now()
	    FROM jsonb_each_text(v_ticket_ids) req
	    WHERE ub.user_id = p_user_id AND ub.prize_id = req.key::integer AND req.key <> 'multiplier';
	
	    -- 日志输出
	    v_elapsed_microseconds := EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000000;
	    RAISE NOTICE '[%μs] GIFT模式, multiplier=%, 消耗门票, 实际抽奖次数: %', 
	        v_elapsed_microseconds, v_gift_multiplier, v_actual_draw_count;
    ELSE
        v_elapsed_microseconds := EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000000;
        RAISE EXCEPTION '[%μs] 错误: 未知的 draw_mode: %', v_elapsed_microseconds, v_draw_mode;
    END IF;

    v_elapsed_microseconds := EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000000;
    RAISE NOTICE '[%μs] 步骤5: 开始选择奖池. 实际抽奖次数=%.', v_elapsed_microseconds, v_actual_draw_count;

    <<retry_loop>>
    LOOP
        -- 步骤 5.1: 根据用户资格查找合适的奖池配置 (主奖池)
        SELECT pc.pool_id, pc.auto_create 
        INTO v_main_pool_id, v_pool_auto_create 
        FROM lottery.pool_cache pc 
        WHERE pc.game_id = p_game_id 
        AND pc.pool_id <> ALL(v_excluded_pool_ids) 
        AND (pc.priority = 0 OR (
            -- 用户白名单检查
            (array_length(pc.whitelist_users, 1) IS NULL OR p_user_id = ANY(pc.whitelist_users)) 
            -- 用户等级检查
            AND (pc.level_min IS NULL OR v_user_level >= pc.level_min) 
            AND (pc.level_max IS NULL OR v_user_level <= pc.level_max) 
            -- 用户消费检查
            AND (pc.consumption_min IS NULL OR v_user_turnover >= pc.consumption_min) 
            AND (pc.consumption_max IS NULL OR v_user_turnover <= pc.consumption_max) 
            -- 用户盈亏检查
            AND (pc.profit_min IS NULL OR v_user_profit_loss >= pc.profit_min) 
            AND (pc.profit_max IS NULL OR v_user_profit_loss <= pc.profit_max)
            -- 抽奖次数约束检查
            AND (pc.count_min IS NULL OR p_draw_count >= pc.count_min)
            AND (pc.count_max IS NULL OR p_draw_count <= pc.count_max)
        ))
		ORDER BY pc.priority DESC 
        LIMIT 1;

        IF NOT FOUND THEN
			SELECT * INTO v_pool_record FROM lottery.pool_cache pc WHERE pc.game_id = p_game_id;
            RAISE EXCEPTION '无可用奖池:%' ,row_to_json(v_pool_record);
        END IF;

        -- 步骤 5.2: 锁定主奖池行,获取当前运行的子奖池信息
        SELECT ps.now, ps.next, ps.total_count INTO v_selected_pool_id, v_next_pool_id, v_total_count
        FROM lottery.pool_status ps WHERE ps.pool_id = v_main_pool_id FOR UPDATE;
		
        RAISE NOTICE '当前奖池: % , v_old_seq: %, v_total_count: %', v_selected_pool_id, v_old_seq, v_total_count;

        IF v_selected_pool_id IS NULL THEN
            RAISE NOTICE '主奖池 % 未初始化 (now is NULL),尝试寻找下一个奖池。', v_main_pool_id;
            -- 将当前不可用的主奖池加入排除列表
            v_excluded_pool_ids := array_append(v_excluded_pool_ids, v_main_pool_id);

            retry_count := retry_count + 1;
            IF retry_count >= max_retries THEN
                RAISE EXCEPTION '无可用奖池(超过最大重试次数%)', max_retries;
            END IF;
            CONTINUE retry_loop; -- 回到循环开始,查找下一个奖池
        END IF;

        -- 步骤 5.3: 显式锁定将要操作的子奖池行,防止其在轮换中被修改
        PERFORM 1 FROM lottery.pool_status WHERE pool_id = v_selected_pool_id FOR UPDATE;

        -- 步骤 5.3.1: 对一次性奖池 (auto_create=false) 进行余量预检查
        IF v_pool_auto_create = false THEN
            -- 由于已锁定,可以直接安全地读取当前 seq
            SELECT seq INTO v_current_seq FROM lottery.pool_status WHERE pool_id = v_selected_pool_id;
            IF (v_total_count - v_current_seq) < v_actual_draw_count THEN
                RAISE NOTICE '一次性奖池 % 余量不足 (剩余: %, 需要: %), 尝试下一个奖池。', v_selected_pool_id, (v_total_count - v_current_seq), v_actual_draw_count;
                v_excluded_pool_ids := array_append(v_excluded_pool_ids, v_main_pool_id);
                retry_count := retry_count + 1;
                IF retry_count >= max_retries THEN
                    RAISE EXCEPTION '无可用奖池(超过最大重试次数%)', max_retries;
                END IF;
                CONTINUE retry_loop;
            END IF;
        END IF;

        -- 步骤 5.4: 原子性增加 seq,同时使用乐观锁检查是否超限
        WITH update_seq AS (
            UPDATE lottery.pool_status
            SET seq = seq + v_actual_draw_count
            WHERE pool_id = v_selected_pool_id
            RETURNING seq - v_actual_draw_count AS old_seq, seq AS new_seq, total_count
        )
        SELECT us.old_seq, us.new_seq, us.total_count INTO v_old_seq, v_new_seq, v_total_count FROM update_seq us;

        -- 步骤 5.5: 检查UPDATE是否成功
        IF v_old_seq IS NULL OR v_old_seq >= v_total_count THEN -- UPDATE更新了0行,或在获取锁后奖池已被抽完
            RAISE NOTICE '奖池 % 在尝试分配序列时已耗尽 (old_seq: %, total: %),尝试寻找下一个奖池。', v_selected_pool_id, v_old_seq, v_total_count;
            -- 将当前已耗尽的奖池加入排除列表
            v_excluded_pool_ids := array_append(v_excluded_pool_ids, v_main_pool_id);

            retry_count := retry_count + 1;
            IF retry_count >= max_retries THEN
                RAISE EXCEPTION '无可用奖池(超过最大重试次数%)', max_retries;
            END IF;
            CONTINUE retry_loop; -- 回到循环开始,查找下一个奖池
        ELSE
            -- 步骤 6: 判断是否抽穿并执行相应逻辑 (低频路径)
            IF v_new_seq >= v_total_count THEN
                IF v_pool_auto_create = true THEN -- 可再生奖池 (公共或高优)
                    -- 等待 next 奖池生成
                    FOR i IN 1..5 LOOP
                        IF v_next_pool_id IS NOT NULL THEN EXIT; END IF;
                        RAISE NOTICE '[%μs] 奖池 % 已抽穿,等待 next 奖池生成... (尝试 %/5)', EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000000, v_selected_pool_id, i;
                        PERFORM pg_sleep(0.02); -- 等待20毫秒
                        SELECT next INTO v_next_pool_id FROM lottery.pool_status WHERE pool_id = v_main_pool_id; -- 重新查询
                    END LOOP;

                    IF v_next_pool_id IS NOT NULL THEN
                        RAISE NOTICE '[%μs] 奖池 % 被抽穿,执行轮换到 %', EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000000, v_selected_pool_id, v_next_pool_id;
                        -- 只有当奖池被"穿透"时,才需要把超出的部分加到下一个奖池
                        IF v_new_seq > v_total_count THEN
                            UPDATE lottery.pool_status SET seq = seq + (v_new_seq - v_total_count) WHERE pool_id = v_next_pool_id;
                        END IF;
                        -- 切换到下一个奖池
                        UPDATE lottery.pool_status SET now = v_next_pool_id, next = NULL WHERE pool_id = v_main_pool_id;
                        PERFORM pg_notify('pool_swap_queue', v_next_pool_id::text);
                    ELSE
                        -- 即使等待后 next 仍然为 NULL,这是一个异常情况,需要回滚并报错
                        RAISE EXCEPTION '奖池 % 已耗尽且无法轮换,请稍后重试。', v_main_pool_id;
                    END IF;

                ELSE -- 一次性奖池 (auto_create = false)
                    -- 对于没有next_pool的一次性奖池,如果被抽完或抽穿,不应尝试轮换,而是继续完成本次抽奖。
                    -- 抽奖查询逻辑中的 LEAST(v_new_seq, v_total_count) 会确保只从当前奖池获取到 v_total_count 为止的奖品。
                    v_elapsed_microseconds := EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000000;
                    RAISE NOTICE '[%μs] 一次性奖池 % 已耗尽,完成后将不再可用。', v_elapsed_microseconds, v_selected_pool_id;
                    UPDATE lottery.pool_status SET now = NULL WHERE pool_id = v_main_pool_id;
                END IF;
            END IF;

            success := true; -- 成功获取序列号
            EXIT retry_loop; -- 退出循环
        END IF;
    END LOOP;

    -- 只有成功获取序列号才继续
    IF NOT success THEN
        -- 理论上不会到这里,因为上面的循环会 RAISE EXCEPTION
        RAISE EXCEPTION '获取抽奖序列失败,未知错误。';
    END IF;

    v_elapsed_microseconds := EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000000;
    RAISE NOTICE '[%μs] 原子增加seq完成. old_seq: %, new_seq: %, total_count: %', v_elapsed_microseconds, v_old_seq, v_new_seq, v_total_count;

    v_elapsed_microseconds := EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000000;
    RAISE NOTICE '[%μs] 步骤7: 开始查询奖品, old_seq=%, new_seq=%.', v_elapsed_microseconds, v_old_seq, v_new_seq;

    -- 步骤 8: 一次性查询所有奖品并插入临时表,统一处理轮换和不轮换的情况
    INSERT INTO temp_draw_results (pool_id, prize_id, quantity, value)
    SELECT
        ps.pool_id, ps.prize_id, 1, p.value
    FROM lottery.pool_sequence ps
    JOIN lottery.prize p ON ps.prize_id = p.id
    WHERE
        -- 从旧奖池获取
        (ps.pool_id = v_selected_pool_id AND ps.sequence_order > v_old_seq AND ps.sequence_order <= LEAST(v_new_seq, v_total_count))
        OR
        -- 如果发生轮换,从新奖池获取超出部分
        (v_new_seq > v_total_count AND ps.pool_id = v_next_pool_id AND ps.sequence_order > 0 AND ps.sequence_order <= (v_new_seq - v_total_count));

    -- 步骤 9: 计算总奖金价值
    SELECT COALESCE(SUM(tr.value), 0) * v_gift_multiplier INTO v_total_winnings_value_with_multiplier FROM temp_draw_results tr;

    -- 步骤 10: 更新用户统计数据 (balance, turnover, profit_loss)
    IF v_draw_mode IN ('COIN', 'COIN_DELAYED') THEN
        UPDATE lottery.user_data
        SET
            balance = balance - v_draw_cost,
            turnover = turnover + v_total_winnings_value_with_multiplier,
            profit_loss = profit_loss + (v_total_winnings_value_with_multiplier * 0.85 - v_draw_cost),
            updated_at = now()
        WHERE
            id = p_user_id AND
            game_id = (CASE WHEN v_is_separately THEN p_game_id ELSE 0 END);
    ELSE -- GIFT 模式
        UPDATE lottery.user_data
        SET
            turnover = turnover + v_total_winnings_value_with_multiplier, -- v_draw_cost 在GIFT模式下为0,但为保持逻辑一致性而保留
            profit_loss = profit_loss + v_total_winnings_value_with_multiplier * 0.85,
            updated_at = now()
        WHERE
            id = p_user_id AND
            game_id = (CASE WHEN v_is_separately THEN p_game_id ELSE 0 END);
    END IF;
    
    -- 步骤 11: 更新用户背包 - 使用 parent_id 而不是 prize_id
    WITH aggregated_prizes AS (
        SELECT 
            prize_id, 
            SUM(quantity) as total_quantity
        FROM temp_draw_results
        GROUP BY prize_id
    ),
    prize_with_parent AS (
        SELECT 
            ap.prize_id,
            COALESCE(p.parent_id, p.id) as parent_id,
            ap.total_quantity * v_gift_multiplier as total_quantity
        FROM aggregated_prizes ap
        JOIN lottery.prize p ON ap.prize_id = p.id
    )
    INSERT INTO lottery.user_backpack (user_id, prize_id, quantity)
    SELECT p_user_id, pwp.parent_id, pwp.total_quantity
    FROM prize_with_parent pwp
    ON CONFLICT (user_id, prize_id) 
    DO UPDATE SET quantity = lottery.user_backpack.quantity + EXCLUDED.quantity, updated_at = now();

    -- 步骤 12: 写入抽奖日志 - 使用 parent_id
    INSERT INTO lottery.user_draw_log (user_id, game_id, prize_id, pool_id, quantity_won)
    SELECT 
        p_user_id, 
        p_game_id, 
        COALESCE(p.parent_id, p.id) as prize_id,
        tr.pool_id,
        SUM(tr.quantity)::integer * v_gift_multiplier
    FROM temp_draw_results tr
    JOIN lottery.prize p ON tr.prize_id = p.id
    GROUP BY COALESCE(p.parent_id, p.id), tr.pool_id;

    -- 步骤 10: 更新奖池统计信息 (total_input, total_output)
    WITH aggregated_results AS (
        SELECT
            tr.pool_id,
            SUM(tr.quantity) as total_quantity,
            SUM(tr.value) as total_value
        FROM temp_draw_results tr
        GROUP BY tr.pool_id
    )
    UPDATE lottery.pool_status ps
    SET total_input = ps.total_input + (ar.total_quantity * v_draw_price), 
        total_output = ps.total_output + ar.total_value
    FROM aggregated_results ar
    WHERE ps.pool_id = ar.pool_id;
    
    v_elapsed_microseconds := EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000000;
    RAISE NOTICE '抽奖完成:耗时 %ms 
	投入:% 产出 % 盈亏: % 
	', v_elapsed_microseconds*0.001,v_draw_cost,v_total_winnings_value_with_multiplier,v_total_winnings_value_with_multiplier * 0.85 - v_draw_cost;

    -- 步骤 11: 返回最终的抽奖结果表格
	RETURN QUERY
	SELECT
	    t.prize_id,
	    COALESCE(p.parent_id::integer, p.id::integer) as parent_id,
	    p.name as prize_name,
	    p.type::text as prize_type,
	    p.game_type::text as game_type,
	    -- 新增:parent_id字段逻辑
	    SUM(t.quantity)::bigint * v_gift_multiplier as total_quantity,
	    SUM(t.value) * v_gift_multiplier as total_value
	FROM temp_draw_results t
	JOIN lottery.prize p ON t.prize_id = p.id
	GROUP BY 
	    t.prize_id, 
	    p.parent_id,
	    p.name, 
	    p.type, 
	    p.game_type, 
	    p.id
	ORDER BY t.prize_id;

EXCEPTION
    WHEN OTHERS THEN
        v_elapsed_microseconds := EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000000;
        RAISE WARNING '[%μs] 发生异常: %', v_elapsed_microseconds, SQLERRM; -- 保留WARNING用于日志记录
        RAISE; -- 重新抛出异常以确保事务回滚
END;
$BODY$;