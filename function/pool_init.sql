-- FUNCTION: lottery.pool_init(integer)

-- DROP FUNCTION IF EXISTS lottery.pool_init(integer);

CREATE OR REPLACE FUNCTION lottery.pool_init(
	p_pool_id integer)
    RETURNS void
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    v_start_time timestamptz := clock_timestamp();
    v_elapsed_ms numeric;

    v_pool record;
    v_status record;
    v_main_pool_id integer;
    v_new_next_pool_id integer;

BEGIN
    RAISE NOTICE '[pool_init] 开始初始化, 目标奖池ID: %', p_pool_id;

    -- 步骤 1: 获取奖池配置,如果不存在则退出
    SELECT * INTO v_pool FROM lottery.pool WHERE id = p_pool_id AND is_enabled = TRUE;
    IF NOT FOUND THEN
        RAISE WARNING '[pool_init] 奖池ID % 在 lottery.pool 中不存在或未启用!', p_pool_id;
        RETURN;
    END IF;

    -- 步骤 2: 根据奖池类型进入不同逻辑分支
    IF v_pool.auto_create = false THEN
        -- 分支 A: 一次性奖池
        RAISE NOTICE '[pool_init] 检测到一次性奖池 %', p_pool_id;
        
        -- 为其创建状态记录,now 指向自己
        INSERT INTO lottery.pool_status (pool_id, father, now) VALUES (p_pool_id, p_pool_id, p_pool_id)
        ON CONFLICT (pool_id) DO UPDATE SET father = EXCLUDED.father, now = p_pool_id;
        
        -- 为其生成奖品序列
        PERFORM lottery.pool_rebuild(p_pool_id);

    ELSIF v_pool.priority > 0 THEN
        -- 分支 B: 高优先级奖池
        RAISE NOTICE '[pool_init] 检测到高优先级奖池 %', p_pool_id;
        v_main_pool_id := ABS(p_pool_id);
        v_new_next_pool_id := -v_main_pool_id;

        -- 1. 为父奖池和影子奖池创建状态记录
        INSERT INTO lottery.pool_status (pool_id, father, now, next) VALUES (v_main_pool_id, v_main_pool_id, v_main_pool_id, v_new_next_pool_id)
        ON CONFLICT (pool_id) DO UPDATE SET father = EXCLUDED.father, now = v_main_pool_id, next = v_new_next_pool_id;
        
        INSERT INTO lottery.pool_status (pool_id, father) VALUES (v_new_next_pool_id, v_main_pool_id)
        ON CONFLICT (pool_id) DO UPDATE SET father = EXCLUDED.father;

        -- 2. 重建两个奖池的序列
        PERFORM lottery.pool_rebuild(v_main_pool_id);
        PERFORM lottery.pool_rebuild(v_new_next_pool_id);

    ELSIF v_pool.priority = 0 THEN
        -- 分支 C: 公共奖池
        RAISE NOTICE '[pool_init] 检测到公共奖池 %', p_pool_id;
        
        -- 1. 检查并设置 game.main_pool
        SELECT main_pool INTO v_main_pool_id FROM lottery.game WHERE id = v_pool.game_id;
        IF v_main_pool_id IS NULL THEN
            RAISE NOTICE '[pool_init] game % 的 main_pool 未设置, 将 % 设为主奖池', v_pool.game_id, p_pool_id;
            UPDATE lottery.game SET main_pool = p_pool_id WHERE id = v_pool.game_id;
            v_main_pool_id := p_pool_id;
        END IF;

        -- 2. 确保所有公共奖池都在 pool_status 中有记录
        INSERT INTO lottery.pool_status (pool_id, father) VALUES (p_pool_id, v_main_pool_id) ON CONFLICT (pool_id) DO NOTHING;

        -- 3. 获取主奖池的状态,以决定如何操作
        SELECT * INTO v_status FROM lottery.pool_status WHERE pool_id = v_main_pool_id;

        IF v_status IS NULL OR v_status.now IS NULL THEN
            -- 场景 C.1: 主奖池首次初始化
            RAISE NOTICE '[pool_init] ...主奖池 % 首次初始化', v_main_pool_id;
            -- 寻找一个不同的奖池作为 next (如果存在)
            SELECT id INTO v_new_next_pool_id FROM lottery.pool WHERE game_id = v_pool.game_id AND priority = 0 AND is_enabled = TRUE AND id <> p_pool_id ORDER BY random() LIMIT 1;

            -- 创建/更新主奖池的状态,将当前池设为 now
            INSERT INTO lottery.pool_status (pool_id, father, now, next) VALUES (v_main_pool_id, v_main_pool_id, v_main_pool_id, v_new_next_pool_id)
            ON CONFLICT (pool_id) DO UPDATE SET father = EXCLUDED.father, now = EXCLUDED.now, next = EXCLUDED.next;

            -- 重建 now 和 next 奖池
            PERFORM lottery.pool_rebuild(v_main_pool_id);
            IF v_new_next_pool_id IS NOT NULL THEN PERFORM lottery.pool_rebuild(v_new_next_pool_id); END IF;
        ELSE
            -- 场景 C.2: 非主奖池加入,或主奖池的 next 需要补充
            RAISE NOTICE '[pool_init] ...奖池 % 加入,检查是否需要补充主奖池 % 的 next', p_pool_id, v_main_pool_id;
            IF v_status.next IS NULL AND v_status.now <> p_pool_id THEN
                RAISE NOTICE '[pool_init] ...主奖池的 next 为空,将 % 设为 next 并重建', p_pool_id;
                PERFORM lottery.pool_rebuild(p_pool_id);
                UPDATE lottery.pool_status SET next = p_pool_id WHERE pool_id = v_main_pool_id;
            ELSE
                RAISE NOTICE '[pool_init] ...无需操作 (now=%, next=%, p_pool_id=%)', v_status.now, v_status.next, p_pool_id;
            END IF;
        END IF;
    END IF;

    v_elapsed_ms := (EXTRACT(EPOCH FROM clock_timestamp()) - EXTRACT(EPOCH FROM v_start_time)) * 1000;
    RAISE NOTICE '[pool_init] 奖池 % 初始化完成, 耗时 %ms', p_pool_id, round(v_elapsed_ms, 3);

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION '[pool_init] 奖池 % 初始化时发生异常: %', p_pool_id, SQLERRM;
END;
$BODY$;