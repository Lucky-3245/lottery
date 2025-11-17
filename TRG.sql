

CREATE OR REPLACE FUNCTION lottery.check_pool_config()
    RETURNS trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF
AS $BODY$
BEGIN
   IF NEW.is_enabled AND (TG_OP = 'INSERT' OR OLD.is_enabled = FALSE) THEN 
        IF NOT EXISTS (SELECT 1 FROM lottery.pool_prize WHERE pool_id = NEW.id) THEN 
            RAISE EXCEPTION '奖池 % :没有配置礼物，无法启用', NEW.id;
        END IF;
         IF NEW.priority = 0 THEN
            IF NEW.auto_create = false THEN
                RAISE EXCEPTION '普通奖池(priority=0) % 的 auto_create 必须为 true', NEW.id;
            END IF;
        END IF;
    END IF;
    IF NOT NEW.is_enabled AND TG_OP = 'UPDATE' AND OLD.is_enabled = TRUE THEN
        RAISE NOTICE '奖池 % 被禁用, 正在清理相关数据...', NEW.id;
        DELETE FROM lottery.pool_status WHERE pool_id = NEW.id;
        DELETE FROM lottery.pool_status WHERE pool_id = -NEW.id;
        DELETE FROM lottery.pool_sequence WHERE pool_id = NEW.id;
        DELETE FROM lottery.pool_sequence WHERE pool_id = -NEW.id;
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END;
$BODY$;
COMMENT ON FUNCTION lottery.check_pool_config()
    IS '启用奖池前检查是否已配置奖品，防止空奖池被启用';

CREATE OR REPLACE FUNCTION lottery.disable_pools_on_game_disable()
    RETURNS trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF
AS $BODY$
BEGIN
    IF TG_OP = 'UPDATE' AND OLD.is_enabled = TRUE AND NEW.is_enabled = FALSE THEN
        UPDATE lottery.pool SET is_enabled = FALSE WHERE game_id = NEW.id;
    END IF;
    RETURN NEW;
END;
$BODY$;

CREATE OR REPLACE FUNCTION lottery.refresh_pool_cache_after_change()
    RETURNS trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF
AS $BODY$
BEGIN
    IF (TG_OP = 'INSERT' OR TG_OP = 'UPDATE') THEN
        IF NEW.is_enabled AND (TG_OP = 'INSERT' OR OLD.is_enabled = FALSE) THEN
            PERFORM lottery.pool_init(NEW.id);
        END IF;
    END IF;
    IF (TG_OP = 'DELETE') OR (TG_OP = 'UPDATE' AND NOT NEW.is_enabled AND OLD.is_enabled) THEN
        UPDATE lottery.game SET main_pool = NULL WHERE main_pool = OLD.id;
        UPDATE lottery.pool_status SET now = NULL WHERE now = OLD.id;
        UPDATE lottery.pool_status SET next = NULL WHERE next = OLD.id;
    END IF;
    REFRESH MATERIALIZED VIEW CONCURRENTLY lottery.pool_cache;
    RETURN NULL; 
END;
$BODY$;

CREATE OR REPLACE FUNCTION lottery.refresh_pool_cache_on_game_change()
    RETURNS trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF
AS $BODY$
BEGIN
    IF OLD.is_enabled = true THEN
        REFRESH MATERIALIZED VIEW CONCURRENTLY lottery.pool_cache;
    END IF;
    RETURN NEW;
END;
$BODY$;

CREATE OR REPLACE FUNCTION lottery.set_updated_at()
    RETURNS trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF
AS $BODY$
BEGIN NEW.updated_at := now(); RETURN NEW;END 
$BODY$;
COMMENT ON FUNCTION lottery.set_updated_at()
    IS '通用触发器函数，自动更新 updated_at 字段';

CREATE OR REPLACE FUNCTION lottery.trg_pool_status_log()
    RETURNS trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF
AS $BODY$
DECLARE
    v_pool INTEGER;
    v_note VARCHAR(1000);
    v_max_id INTEGER;
BEGIN
    IF (OLD.total_input != 0 AND NEW.total_input = 0) OR 
       (OLD.total_output != 0 AND NEW.total_output = 0) THEN
        SELECT 
            ABS(ps.pool_id),
            CONCAT('游戏 ',g.id, ':', g.game_name, '; 奖池 ', ps.pool_id, ':', p.pool_note)
        INTO v_pool, v_note
        FROM lottery.pool_status AS ps
        LEFT JOIN lottery.pool AS p ON ps.father = p.id
        LEFT JOIN lottery.game AS g ON p.game_id = g.id
        WHERE ps.pool_id = NEW.pool_id;
        SELECT COALESCE(MAX(id), 0) + 1
        INTO v_max_id
        FROM lottery.pool_status_log
        WHERE pool = v_pool;
        INSERT INTO lottery.pool_status_log (
            pool,
            id,
            note,
            input,
            output,
            update_at
        ) VALUES (
            v_pool,
            v_max_id,
            v_note,
            OLD.total_input,
            OLD.total_output,
            NOW()
        );
    END IF;
    RETURN NEW;
END;
$BODY$;


CREATE OR REPLACE FUNCTION lottery.trg_remove_zero_quantity_items()
    RETURNS trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF
AS $BODY$
BEGIN IF NEW.quantity = 0 THEN DELETE FROM lottery.user_backpack WHERE user_id = NEW.user_id AND prize_id = NEW.prize_id;END IF;RETURN NULL;END;
$BODY$;

CREATE TRIGGER REMOVE_ZERO_QUANTITY_ITEMS_TRIGGER
AFTER
UPDATE ON LOTTERY.USER_BACKPACK FOR EACH ROW
EXECUTE FUNCTION LOTTERY.TRG_REMOVE_ZERO_QUANTITY_ITEMS ();

CREATE TRIGGER TRG_DISABLE_POOLS_ON_GAME_DISABLE
AFTER
UPDATE OF IS_ENABLED ON LOTTERY.GAME FOR EACH ROW
EXECUTE FUNCTION LOTTERY.DISABLE_POOLS_ON_GAME_DISABLE ();

CREATE TRIGGER TRG_POOL_CHECK BEFORE INSERT
OR
UPDATE ON LOTTERY.POOL FOR EACH ROW
EXECUTE FUNCTION LOTTERY.CHECK_POOL_CONFIG ();

COMMENT ON TRIGGER TRG_POOL_CHECK ON LOTTERY.POOL IS '启用奖池前做配置完整性检查';

CREATE TRIGGER TRG_POOL_STATUS_LOG BEFORE
UPDATE ON LOTTERY.POOL_STATUS FOR EACH ROW
EXECUTE FUNCTION LOTTERY.TRG_POOL_STATUS_LOG ();

CREATE TRIGGER TRG_REFRESH_POOL_CACHE_AFTER_CHANGE
AFTER INSERT
OR DELETE
OR
UPDATE ON LOTTERY.POOL FOR EACH ROW
EXECUTE FUNCTION LOTTERY.REFRESH_POOL_CACHE_AFTER_CHANGE ();

CREATE TRIGGER TRG_REFRESH_POOL_CACHE_ON_GAME_CHANGE
AFTER
UPDATE ON LOTTERY.GAME FOR EACH ROW
EXECUTE FUNCTION LOTTERY.REFRESH_POOL_CACHE_ON_GAME_CHANGE ();

CREATE TRIGGER TRG_GAME_UPDATED BEFORE
UPDATE ON LOTTERY.GAME FOR EACH ROW
EXECUTE FUNCTION LOTTERY.SET_UPDATED_AT ();

CREATE TRIGGER TRG_PRIZE_UPDATED BEFORE
UPDATE ON LOTTERY.PRIZE FOR EACH ROW
EXECUTE FUNCTION LOTTERY.SET_UPDATED_AT ();

CREATE TRIGGER TRG_POOL_UPDATED BEFORE
UPDATE ON LOTTERY.POOL FOR EACH ROW
EXECUTE FUNCTION LOTTERY.SET_UPDATED_AT ();

CREATE TRIGGER TRG_POOL_PRIZE_UPDATED BEFORE
UPDATE ON LOTTERY.POOL_PRIZE FOR EACH ROW
EXECUTE FUNCTION LOTTERY.SET_UPDATED_AT ();