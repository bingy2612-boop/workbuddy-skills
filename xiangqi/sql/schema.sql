-- 中国象棋 · 联机后端
-- 适用于 PostgreSQL 14+（或兼容的云数据库）
-- 在已开启 RLS 的 public schema 下执行一遍即可

-- ---------------------------------------------------------------------------
-- 表
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS chess_rooms (
  code          TEXT PRIMARY KEY,                       -- 6 位房间号
  board         TEXT NOT NULL,                          -- 90 字符局面串，小写黑 / 大写红
  turn          TEXT NOT NULL DEFAULT 'r',              -- 'r' | 'b'
  moves         JSONB NOT NULL DEFAULT '[]'::jsonb,     -- 棋谱 [{n,f,t}]
  move_count    INTEGER NOT NULL DEFAULT 0,             -- 已走步数，用于防重复提交
  status        TEXT NOT NULL DEFAULT 'waiting',        -- waiting | playing | over
  winner        TEXT,                                   -- 'r' | 'b'
  over_reason   TEXT,
  last_move     JSONB,                                  -- {from,to}
  host_name     TEXT,
  guest_name    TEXT,
  host_seen     TIMESTAMPTZ NOT NULL DEFAULT now(),     -- 心跳
  guest_seen    TIMESTAMPTZ,
  restart_host  BOOLEAN NOT NULL DEFAULT false,         -- 双方同意才重开
  restart_guest BOOLEAN NOT NULL DEFAULT false,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 座位令牌。前端完全读不到这张表，写权限只存在于下面的函数里。
CREATE TABLE IF NOT EXISTS chess_seats (
  code      TEXT NOT NULL REFERENCES chess_rooms(code) ON DELETE CASCADE,
  side      TEXT NOT NULL,                              -- 'r' | 'b'
  token     TEXT NOT NULL,
  joined_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (code, side)
);

-- ---------------------------------------------------------------------------
-- 权限：房间公开只读，座位表一律不开放，写入全部走函数
-- ---------------------------------------------------------------------------

ALTER TABLE chess_rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE chess_seats ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON TABLE public.chess_rooms TO authenticated, anon;

DROP POLICY IF EXISTS chess_rooms_read ON chess_rooms;
CREATE POLICY chess_rooms_read ON chess_rooms
  FOR SELECT TO authenticated, anon USING (true);

-- ---------------------------------------------------------------------------
-- chess_create：建房，建房者执红
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION chess_create(p_code text, p_token text, p_name text, p_board text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE r chess_rooms;
BEGIN
  INSERT INTO chess_rooms (code, board, host_name)
  VALUES (p_code, p_board, p_name) RETURNING * INTO r;

  INSERT INTO chess_seats (code, side, token) VALUES (p_code, 'r', p_token);

  RETURN to_jsonb(r) || jsonb_build_object('side', 'r');
END
$fn$;

-- ---------------------------------------------------------------------------
-- chess_join：加入房间。同一个令牌再次进来视为重连，坐回原位。
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION chess_join(p_code text, p_token text, p_name text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE r chess_rooms; my_side text;
BEGIN
  SELECT * INTO r FROM chess_rooms WHERE code = p_code FOR UPDATE;
  IF r.code IS NULL THEN RAISE EXCEPTION 'room_not_found'; END IF;

  -- 老玩家回来：只更新心跳
  SELECT side INTO my_side FROM chess_seats WHERE code = p_code AND token = p_token;
  IF my_side IS NOT NULL THEN
    UPDATE chess_rooms SET
      host_seen  = CASE WHEN my_side = 'r' THEN now() ELSE host_seen END,
      guest_seen = CASE WHEN my_side = 'b' THEN now() ELSE guest_seen END
    WHERE code = p_code RETURNING * INTO r;
    RETURN to_jsonb(r) || jsonb_build_object('side', my_side);
  END IF;

  IF EXISTS (SELECT 1 FROM chess_seats WHERE code = p_code AND side = 'b') THEN
    RAISE EXCEPTION 'room_full';
  END IF;

  INSERT INTO chess_seats (code, side, token) VALUES (p_code, 'b', p_token);
  UPDATE chess_rooms SET
    guest_name = p_name,
    guest_seen = now(),
    status = CASE WHEN status = 'waiting' THEN 'playing' ELSE status END,
    updated_at = now()
  WHERE code = p_code RETURNING * INTO r;

  RETURN to_jsonb(r) || jsonb_build_object('side', 'b');
END
$fn$;

-- ---------------------------------------------------------------------------
-- chess_move：落子。三重校验——在座 / 该你走 / 步数连续。
-- p_count 是「走后」的总步数，服务端要求它等于当前 move_count + 1，
-- 这样同一方连点两次第二次会被 stale_move 拦掉。
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION chess_move(
  p_code text, p_token text, p_board text, p_turn text,
  p_moves jsonb, p_count integer, p_last jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE r chess_rooms; my_side text;
BEGIN
  SELECT * INTO r FROM chess_rooms WHERE code = p_code FOR UPDATE;
  IF r.code IS NULL THEN RAISE EXCEPTION 'room_not_found'; END IF;

  SELECT side INTO my_side FROM chess_seats WHERE code = p_code AND token = p_token;
  IF my_side IS NULL THEN RAISE EXCEPTION 'not_in_room'; END IF;

  IF r.status <> 'playing' THEN RAISE EXCEPTION 'not_playing'; END IF;
  IF r.turn <> my_side THEN RAISE EXCEPTION 'not_your_turn'; END IF;
  IF r.move_count <> p_count - 1 THEN RAISE EXCEPTION 'stale_move'; END IF;

  UPDATE chess_rooms SET
    board = p_board,
    turn = p_turn,
    moves = p_moves,
    move_count = p_count,
    last_move = p_last,
    restart_host = false,
    restart_guest = false,
    updated_at = now()
  WHERE code = p_code RETURNING * INTO r;

  RETURN to_jsonb(r) || jsonb_build_object('side', my_side);
END
$fn$;

-- ---------------------------------------------------------------------------
-- chess_finish：终局。重复调用只返回当前状态，不报错。
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION chess_finish(p_code text, p_token text, p_winner text, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE r chess_rooms; my_side text;
BEGIN
  SELECT * INTO r FROM chess_rooms WHERE code = p_code FOR UPDATE;
  IF r.code IS NULL THEN RAISE EXCEPTION 'room_not_found'; END IF;

  SELECT side INTO my_side FROM chess_seats WHERE code = p_code AND token = p_token;
  IF my_side IS NULL THEN RAISE EXCEPTION 'not_in_room'; END IF;

  IF r.status = 'over' THEN
    RETURN to_jsonb(r) || jsonb_build_object('side', my_side);
  END IF;

  UPDATE chess_rooms SET
    status = 'over', winner = p_winner, over_reason = p_reason, updated_at = now()
  WHERE code = p_code RETURNING * INTO r;

  RETURN to_jsonb(r) || jsonb_build_object('side', my_side);
END
$fn$;

-- ---------------------------------------------------------------------------
-- chess_restart：双方都点了同意才真正重开，否则只记录自己这一票。
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION chess_restart(p_code text, p_token text, p_board text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE r chess_rooms; my_side text;
BEGIN
  SELECT * INTO r FROM chess_rooms WHERE code = p_code FOR UPDATE;
  IF r.code IS NULL THEN RAISE EXCEPTION 'room_not_found'; END IF;

  SELECT side INTO my_side FROM chess_seats WHERE code = p_code AND token = p_token;
  IF my_side IS NULL THEN RAISE EXCEPTION 'not_in_room'; END IF;

  UPDATE chess_rooms SET
    restart_host  = CASE WHEN my_side = 'r' THEN true ELSE restart_host END,
    restart_guest = CASE WHEN my_side = 'b' THEN true ELSE restart_guest END,
    host_seen  = CASE WHEN my_side = 'r' THEN now() ELSE host_seen END,
    guest_seen = CASE WHEN my_side = 'b' THEN now() ELSE guest_seen END
  WHERE code = p_code RETURNING * INTO r;

  IF r.restart_host AND r.restart_guest THEN
    UPDATE chess_rooms SET
      board = p_board, turn = 'r', moves = '[]'::jsonb, move_count = 0,
      status = 'playing', winner = NULL, over_reason = NULL, last_move = NULL,
      restart_host = false, restart_guest = false, updated_at = now()
    WHERE code = p_code RETURNING * INTO r;
  END IF;

  RETURN to_jsonb(r) || jsonb_build_object('side', my_side);
END
$fn$;

-- ---------------------------------------------------------------------------
-- chess_ping：心跳，用来判断对手是否还在看棋盘
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION chess_ping(p_code text, p_token text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE my_side text;
BEGIN
  SELECT side INTO my_side FROM chess_seats WHERE code = p_code AND token = p_token;
  IF my_side IS NULL THEN RETURN; END IF;

  UPDATE chess_rooms SET
    host_seen  = CASE WHEN my_side = 'r' THEN now() ELSE host_seen END,
    guest_seen = CASE WHEN my_side = 'b' THEN now() ELSE guest_seen END
  WHERE code = p_code;
END
$fn$;

-- ---------------------------------------------------------------------------
-- 函数执行权限
-- ---------------------------------------------------------------------------

GRANT EXECUTE ON FUNCTION
  chess_create(text, text, text, text),
  chess_join(text, text, text),
  chess_move(text, text, text, text, jsonb, integer, jsonb),
  chess_finish(text, text, text, text),
  chess_restart(text, text, text),
  chess_ping(text, text)
TO anon, authenticated;
