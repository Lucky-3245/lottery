CREATE SCHEMA IF NOT EXISTS lottery;

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

CREATE TYPE lottery.broadcast_enum AS ENUM
    ('NONE', 'LOG', 'GLOBAL', 'BOTH');
COMMENT ON TYPE lottery.broadcast_enum IS '广播级别枚举:NONE=0 不通知, LOG=1 中奖记录展示, GLOBAL=2 全服通知, BOTH=3 全服+记录';

CREATE TYPE lottery.draw_mode_enum AS ENUM
    ('COIN', 'PRIZE');
COMMENT ON TYPE lottery.draw_mode_enum IS '开奖模式';

CREATE TYPE lottery.prize_type_enum AS ENUM
    ('NORMAL', 'TICKET', 'COIN');
COMMENT ON TYPE lottery.prize_type_enum IS '奖品类型枚举: NORMAL 普通礼物, TICKET 特殊入场券, COIN 金币';

CREATE SEQUENCE lottery.game_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    MAXVALUE 2147483647
    CACHE 1;
	
CREATE TABLE lottery.game (
    id integer DEFAULT nextval('lottery.game_seq'::regclass) NOT NULL,
    game_name character varying(255) NOT NULL,
    draw_price numeric(12,2),
    required_prize_id integer,
    draw_mode lottery.draw_mode_enum DEFAULT 'COIN'::lottery.draw_mode_enum NOT NULL,
    gift_multiplier integer DEFAULT 1 NOT NULL,
    is_separately boolean DEFAULT false NOT NULL,
    main_pool integer,
    ticket_ids jsonb,
    is_enabled boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT game_gift_multiplier_check CHECK ((gift_multiplier > 0))
);
COMMENT ON TABLE lottery.game IS '抽奖游戏主配置表';
COMMENT ON COLUMN lottery.game.id IS '游戏唯一标识';
COMMENT ON COLUMN lottery.game.game_name IS '游戏名称';
COMMENT ON COLUMN lottery.game.draw_price IS '单次抽奖价格(付费模式时必填)';
COMMENT ON COLUMN lottery.game.required_prize_id IS '进入该游戏所需的特殊奖品 ID(门票模式时必填)';
COMMENT ON COLUMN lottery.game.draw_mode IS '开奖模式枚举';
COMMENT ON COLUMN lottery.game.gift_multiplier IS '一次抽奖可获得同种礼物的倍数(默认为 1)';
COMMENT ON COLUMN lottery.game.is_enabled IS '游戏是否对外开放';
COMMENT ON COLUMN lottery.game.created_at IS '创建时间';
COMMENT ON COLUMN lottery.game.updated_at IS '更新时间';
COMMENT ON COLUMN lottery.game.is_separately IS '单独计算准入条件';

CREATE SEQUENCE lottery.pool_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    MAXVALUE 2147483647
    CACHE 1;
	
CREATE TABLE lottery.pool (
    id integer DEFAULT nextval('lottery.pool_seq'::regclass) NOT NULL,
    game_id integer NOT NULL,
    pool_note character varying(255),
    auto_create boolean DEFAULT true NOT NULL,
    priority integer DEFAULT 0 NOT NULL,
    conditions jsonb,
    is_enabled boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);
COMMENT ON TABLE lottery.pool IS '奖池定义表';
COMMENT ON COLUMN lottery.pool.id IS '奖池唯一标识';
COMMENT ON COLUMN lottery.pool.game_id IS '所属游戏 ID';
COMMENT ON COLUMN lottery.pool.pool_note IS '奖池备注,后台管理可见';
COMMENT ON COLUMN lottery.pool.is_enabled IS '是否启用';
COMMENT ON COLUMN lottery.pool.auto_create IS '为 true 时,奖池被切换后自动生成新的序列；为 false 时切换后禁用该奖池';
COMMENT ON COLUMN lottery.pool.created_at IS '创建时间';
COMMENT ON COLUMN lottery.pool.updated_at IS '更新时间';
COMMENT ON COLUMN lottery.pool.priority IS '奖池优先级(priority=0时,conditions无效)';
COMMENT ON COLUMN lottery.pool.conditions IS 'JSONB 格式的进入条件,例如：{"type":"LEVEL","min":5,"max":100} {"type":"PROFIT","min":-1000,"max":1000} {"type":"WHITELIST","users":[123,456]}';


CREATE TABLE lottery.pool_prize (
    pool_id integer NOT NULL,
    prize_id integer NOT NULL,
    quantity integer NOT NULL,
    position integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT pool_prize_check CHECK ((("position" = 0) OR (quantity = 1))),
    CONSTRAINT pool_prize_quantity_check CHECK ((quantity > 0))
);
COMMENT ON TABLE lottery.pool_prize IS '奖池内奖品配置明细';
COMMENT ON COLUMN lottery.pool_prize.pool_id IS '奖池 ID';
COMMENT ON COLUMN lottery.pool_prize.prize_id IS '奖品 ID';
COMMENT ON COLUMN lottery.pool_prize.quantity IS '该奖品在本奖池中的数量';
COMMENT ON COLUMN lottery.pool_prize."position" IS '奖品在序列中的固定位置：0=随机,正数=顺序第 N,负数=倒数第 N；固定位置时 quantity 必须为 1';
COMMENT ON COLUMN lottery.pool_prize.created_at IS '创建时间';
COMMENT ON COLUMN lottery.pool_prize.updated_at IS '更新时间';


CREATE UNLOGGED TABLE lottery.pool_sequence (
    pool_id integer NOT NULL,
    sequence_order integer NOT NULL,
    prize_id integer NOT NULL,
    claimed_user_id bigint,
    claimed_at timestamp with time zone
)
WITH (fillfactor='90');
COMMENT ON TABLE lottery.pool_sequence IS '预生成并打乱的固定奖品序列(每个奖池一份)';
COMMENT ON COLUMN lottery.pool_sequence.pool_id IS '所属奖池 ID';
COMMENT ON COLUMN lottery.pool_sequence.sequence_order IS '奖品在序列中的固定顺序(从 1 开始)';
COMMENT ON COLUMN lottery.pool_sequence.prize_id IS '对应奖品 ID';
COMMENT ON COLUMN lottery.pool_sequence.claimed_user_id IS '抽中该奖品的用户 ID；NULL 表示尚未被抽取';
COMMENT ON COLUMN lottery.pool_sequence.claimed_at IS '奖品被抽中的确切时间';


CREATE UNLOGGED TABLE lottery.pool_status (
    pool_id integer NOT NULL,
    seq integer DEFAULT 0,
    total_count integer DEFAULT 0 NOT NULL,
    update_count integer DEFAULT 0 NOT NULL,
    total_input numeric(12,2) DEFAULT 0,
    total_output numeric(12,2) DEFAULT 0,
    next integer,
    now integer,
    father integer NOT NULL
);


CREATE TABLE lottery.pool_status_log (
    pool integer NOT NULL,
    id bigint NOT NULL,
    note character varying(1000),
    input numeric NOT NULL,
    output numeric NOT NULL,
    update_at timestamp with time zone DEFAULT now() NOT NULL
);


CREATE SEQUENCE lottery.pool_status_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

ALTER SEQUENCE lottery.pool_status_log_id_seq OWNED BY lottery.pool_status_log.id;

CREATE SEQUENCE lottery.prize_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    MAXVALUE 2147483647
    CACHE 1;
	
CREATE TABLE lottery.prize (
    id integer DEFAULT nextval('lottery.prize_seq'::regclass) NOT NULL,
    name character varying(255) NOT NULL,
    value numeric(12,2) DEFAULT 0 NOT NULL,
    type lottery.prize_type_enum DEFAULT 'NORMAL'::lottery.prize_type_enum NOT NULL,
    display_id integer[],
    parent_id integer,
    game_type integer,
    broadcast lottery.broadcast_enum DEFAULT 'NONE'::lottery.broadcast_enum NOT NULL,
    is_enabled boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);
COMMENT ON TABLE lottery.prize IS '奖品(礼物)字典表';
COMMENT ON COLUMN lottery.prize.id IS '奖品唯一标识';
COMMENT ON COLUMN lottery.prize.name IS '奖品名称';
COMMENT ON COLUMN lottery.prize.value IS '奖品价值(单位：平台币)';
COMMENT ON COLUMN lottery.prize.type IS '奖品类型枚举,见 prize_type_enum';
COMMENT ON COLUMN lottery.prize.broadcast IS '中奖后广播级别枚举';
COMMENT ON COLUMN lottery.prize.is_enabled IS '是否启用,false 时不可再被配置进奖池';
COMMENT ON COLUMN lottery.prize.created_at IS '创建时间';
COMMENT ON COLUMN lottery.prize.updated_at IS '更新时间';


CREATE TABLE lottery.user_backpack (
    user_id bigint NOT NULL,
    prize_id integer NOT NULL,
    quantity integer NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT user_backpack_quantity_check CHECK ((quantity >= 0))
);
COMMENT ON TABLE lottery.user_backpack IS '用户背包：持有奖品及数量';
COMMENT ON COLUMN lottery.user_backpack.user_id IS '用户 ID';
COMMENT ON COLUMN lottery.user_backpack.prize_id IS '奖品 ID';
COMMENT ON COLUMN lottery.user_backpack.quantity IS '剩余数量';
COMMENT ON COLUMN lottery.user_backpack.created_at IS '首次获得时间';
COMMENT ON COLUMN lottery.user_backpack.updated_at IS '最后更新时间';


CREATE TABLE lottery.user_data (
    id bigint NOT NULL,
    game_id integer DEFAULT 0 NOT NULL,
    balance numeric(12,2) DEFAULT 0 NOT NULL,
    profit_loss numeric(12,2) DEFAULT 0 NOT NULL,
    turnover numeric(12,2) DEFAULT 0 NOT NULL,
    level integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);
COMMENT ON TABLE lottery.user_data IS '用户账户表';
COMMENT ON COLUMN lottery.user_data.id IS '用户ID';
COMMENT ON COLUMN lottery.user_data.game_id IS '游戏ID,0表示全局账户';
COMMENT ON COLUMN lottery.user_data.balance IS '账户余额(平台币)';
COMMENT ON COLUMN lottery.user_data.profit_loss IS '累计盈亏(平台币)';
COMMENT ON COLUMN lottery.user_data.turnover IS '累计流水(平台币)';
COMMENT ON COLUMN lottery.user_data.created_at IS '创建时间';
COMMENT ON COLUMN lottery.user_data.updated_at IS '更新时间';
COMMENT ON COLUMN lottery.user_data.level IS '用户等级';

CREATE SEQUENCE lottery.user_record_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
	
CREATE TABLE lottery.user_draw_log (
    id bigint DEFAULT nextval('lottery.user_record_id_seq'::regclass) NOT NULL,
    user_id bigint NOT NULL,
    game_id integer NOT NULL,
    pool_id integer,
    prize_id integer NOT NULL,
    quantity_won integer NOT NULL,
    draw_time timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
)
PARTITION BY RANGE (draw_time);

ALTER TABLE ONLY lottery.pool_status_log ALTER COLUMN id SET DEFAULT nextval('lottery.pool_status_log_id_seq'::regclass);

CREATE MATERIALIZED VIEW lottery.game_info AS
 SELECT id,
    game_name,
    draw_price,
    draw_mode,
        CASE
            WHEN (ticket_ids ? 'multiplier'::text) THEN (ticket_ids - 'multiplier'::text)
            ELSE ticket_ids
        END AS ticket_ids
   FROM lottery.game
  WHERE (is_enabled = true)
  ORDER BY id
  WITH NO DATA;



CREATE MATERIALIZED VIEW lottery.pool_cache AS
 SELECT p.game_id,
    p.id AS pool_id,
    p.priority,
    (((p.conditions -> 'level'::text) ->> 'min'::text))::integer AS level_min,
    (((p.conditions -> 'level'::text) ->> 'max'::text))::integer AS level_max,
    (((p.conditions -> 'consumption'::text) ->> 'min'::text))::numeric AS consumption_min,
    (((p.conditions -> 'consumption'::text) ->> 'max'::text))::numeric AS consumption_max,
    (((p.conditions -> 'profit'::text) ->> 'min'::text))::numeric AS profit_min,
    (((p.conditions -> 'profit'::text) ->> 'max'::text))::numeric AS profit_max,
    (((p.conditions -> 'count'::text) ->> 'min'::text))::integer AS count_min,
    (((p.conditions -> 'count'::text) ->> 'max'::text))::integer AS count_max,
        CASE
            WHEN (((p.conditions -> 'whitelist'::text) IS NOT NULL) AND (jsonb_typeof((p.conditions -> 'whitelist'::text)) = 'array'::text)) THEN ARRAY( SELECT (jsonb_array_elements_text((p.conditions -> 'whitelist'::text)))::bigint AS jsonb_array_elements_text)
            ELSE ARRAY[]::bigint[]
        END AS whitelist_users,
    g.draw_price,
    g.draw_mode,
    g.gift_multiplier,
    g.is_separately,
    g.ticket_ids,
    p.auto_create
   FROM (lottery.pool p
     JOIN lottery.game g ON ((p.game_id = g.id)))
  WHERE ((p.is_enabled = true) AND (g.is_enabled = true) AND ((p.id = g.main_pool) OR (p.priority > 0)))
  WITH NO DATA;

CREATE UNIQUE INDEX idx_pool_cache_game_pool_unique ON lottery.pool_cache USING btree (game_id, pool_id);

REFRESH MATERIALIZED VIEW lottery.game_info;
REFRESH MATERIALIZED VIEW lottery.pool_cache;