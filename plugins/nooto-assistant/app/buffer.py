import json
import logging

import redis.asyncio as aioredis

from app.config import REDIS_URL, PROCESS_LOCK_TTL, MAX_QUEUE_SIZE, QUEUE_ITEM_TTL

log = logging.getLogger('uvicorn.error')

_redis = aioredis.from_url(REDIS_URL, decode_responses=True)

COLLECT_KEY = 'nooto:collecting:{session_id}'


async def is_collecting(session_id: str) -> bool:
    """Check if we're in the collection window after a trigger."""
    return await _redis.exists(COLLECT_KEY.format(session_id=session_id)) > 0


async def start_collecting(session_id: str, trigger_segments: list[dict], collect_seconds: int) -> None:
    """Clear old buffer, store trigger segments, and mark collection window open."""
    buf_key = f'nooto:buf:{session_id}'
    flag_key = COLLECT_KEY.format(session_id=session_id)

    # Clear any old buffered segments
    await _redis.delete(buf_key)

    # Buffer the trigger segments
    pipe = _redis.pipeline()
    for seg in trigger_segments:
        pipe.rpush(buf_key, json.dumps(seg))
    pipe.expire(buf_key, collect_seconds + 5)
    # Set collecting flag with TTL matching the collect window
    pipe.set(flag_key, '1', ex=collect_seconds + 5)
    await pipe.execute()

    log.info(f'[buffer] session={session_id} started collecting ({len(trigger_segments)} trigger segments)')


async def extend_collecting(session_id: str, collect_seconds: int) -> None:
    """Extend the collection window without clearing buffered segments."""
    buf_key = f'nooto:buf:{session_id}'
    flag_key = COLLECT_KEY.format(session_id=session_id)

    pipe = _redis.pipeline()
    pipe.expire(buf_key, collect_seconds + 5)
    pipe.expire(flag_key, collect_seconds + 5)
    await pipe.execute()

    log.info(f'[buffer] session={session_id} extended collection window by {collect_seconds}s')


async def add_segments(session_id: str, segments: list[dict]) -> None:
    """Append segments to the buffer during collection window."""
    buf_key = f'nooto:buf:{session_id}'

    pipe = _redis.pipeline()
    for seg in segments:
        pipe.rpush(buf_key, json.dumps(seg))
    await pipe.execute()

    count = await _redis.llen(buf_key)
    log.info(f'[buffer] session={session_id} buffered — {count} segments total')


async def flush(session_id: str) -> list[dict]:
    """Flush all buffered segments and stop collecting."""
    buf_key = f'nooto:buf:{session_id}'
    flag_key = COLLECT_KEY.format(session_id=session_id)

    raw = await _redis.lrange(buf_key, 0, -1)
    await _redis.delete(buf_key, flag_key)
    segments = [json.loads(r) for r in raw]
    log.info(f'[buffer] session={session_id} FLUSHED — {len(segments)} segments')
    return segments


LOCK_KEY = 'nooto:lock:{session_id}'
QUEUE_KEY = 'nooto:queue:{session_id}'


async def try_acquire_process_lock(session_id: str) -> bool:
    """Atomically acquire the processing lock (SET NX EX). Returns True if acquired."""
    key = LOCK_KEY.format(session_id=session_id)
    acquired = await _redis.set(key, '1', nx=True, ex=PROCESS_LOCK_TTL)
    if acquired:
        log.info(f'[lock] session={session_id} ACQUIRED process lock (TTL={PROCESS_LOCK_TTL}s)')
    return bool(acquired)


async def release_process_lock(session_id: str) -> None:
    """Release the processing lock."""
    key = LOCK_KEY.format(session_id=session_id)
    await _redis.delete(key)
    log.info(f'[lock] session={session_id} RELEASED process lock')


async def enqueue_question(session_id: str, segments: list[dict], user_time_zone: str | None) -> bool:
    """RPUSH a question payload onto the FIFO queue. Returns False if queue is full."""
    key = QUEUE_KEY.format(session_id=session_id)
    length = await _redis.llen(key)
    if length >= MAX_QUEUE_SIZE:
        log.warning(f'[queue] session={session_id} FULL ({length}/{MAX_QUEUE_SIZE}) — dropping question')
        return False
    item = json.dumps({'segments': segments, 'user_time_zone': user_time_zone})
    pipe = _redis.pipeline()
    pipe.rpush(key, item)
    pipe.expire(key, QUEUE_ITEM_TTL)
    await pipe.execute()
    log.info(f'[queue] session={session_id} ENQUEUED question (queue_len={length + 1})')
    return True


async def dequeue_question(session_id: str) -> dict | None:
    """LPOP the next queued question. Returns parsed dict or None."""
    key = QUEUE_KEY.format(session_id=session_id)
    raw = await _redis.lpop(key)
    if raw is None:
        return None
    return json.loads(raw)


async def queue_length(session_id: str) -> int:
    """Return current queue depth."""
    key = QUEUE_KEY.format(session_id=session_id)
    return await _redis.llen(key)


AVG_QLEN_KEY = 'nooto:avg_qlen:{session_id}'
AVG_QLEN_TTL = 86400  # 24h


async def store_question_length(session_id: str, char_count: int) -> None:
    """Track question text length for adaptive flush timing."""
    key = AVG_QLEN_KEY.format(session_id=session_id)
    pipe = _redis.pipeline()
    pipe.hincrby(key, 'sum', char_count)
    pipe.hincrby(key, 'count', 1)
    pipe.expire(key, AVG_QLEN_TTL)
    await pipe.execute()


async def get_avg_question_length(session_id: str) -> float | None:
    """Running average of question text length. Returns None if no data yet."""
    key = AVG_QLEN_KEY.format(session_id=session_id)
    data = await _redis.hgetall(key)
    if not data or int(data.get('count', 0)) == 0:
        return None
    return int(data['sum']) / int(data['count'])


async def clear_stale_flags():
    """Clear collecting flags and buffers left from a previous container run."""
    cursor = '0'
    cleared = 0
    while True:
        cursor, keys = await _redis.scan(cursor=cursor, match='nooto:collecting:*', count=100)
        if keys:
            # Also clear corresponding buffers and locks
            buf_keys = [k.replace('collecting', 'buf') for k in keys]
            lock_keys = [k.replace('collecting', 'lock') for k in keys]
            queue_keys = [k.replace('collecting', 'queue') for k in keys]
            await _redis.delete(*keys, *buf_keys, *lock_keys, *queue_keys)
            cleared += len(keys)
        if cursor == '0' or cursor == 0:
            break
    if cleared:
        log.info(f'[buffer] cleared stale flags for {cleared} sessions on startup')


async def close():
    await _redis.aclose()
