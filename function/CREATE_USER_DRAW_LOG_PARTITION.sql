CREATE FUNCTION LOTTERY.CREATE_USER_DRAW_LOG_PARTITION (FOR_DATE DATE) RETURNS TEXT LANGUAGE PLPGSQL AS $_$DECLARE partition_name TEXT;

start_ts TIMESTAMP WITH TIME ZONE;
end_ts TIMESTAMP WITH TIME ZONE;
create_sql TEXT;
BEGIN partition_name := 'user_draw_log_' || to_char(for_date, 'YYYYMMDD');
start_ts := for_date::TIMESTAMP AT TIME ZONE 'Asia/Shanghai';
end_ts := (for_date + INTERVAL '1 day')::TIMESTAMP AT TIME ZONE 'Asia/Shanghai';
IF EXISTS (SELECT 1 FROM pg_inherits i JOIN pg_class cp ON (i.inhparent = 'lottery.user_draw_log'::regclass AND i.inhrelid = cp.oid) JOIN pg_class cc ON (cp.relname = partition_name AND cc.oid = 'lottery.user_draw_log'::regclass)) THEN RETURN 'Partition ' || partition_name || ' already exists.';
END IF;
create_sql := format($$ CREATE TABLE IF NOT EXISTS lottery.%I PARTITION OF lottery.user_draw_log FOR VALUES FROM ('%s') TO ('%s');
$$, partition_name, start_ts, end_ts);
EXECUTE create_sql;
RETURN 'Partition ' || partition_name || ' created successfully.';
EXCEPTION WHEN OTHERS THEN RETURN 'Error creating partition ' || partition_name || ': ' || SQLERRM;
END;
$_$;