import json
import logging
import time

import redis.asyncio as aioredis

from app.config import REDIS_URL, CHUNK_THRESHOLD, TIME_THRESHOLD_SECONDS

log = logging.getLogger('uvicorn.error')

_redis = aioredis.from_url(REDIS_URL, decode_responses=True)

BUFFER_TTL = 300  # 5 min expiry for stale buffers


async def add_segments(session_id: str, segments: list[dict]) -> tuple[bool, list[dict]]:
    buf_key = f'grammarly:buf:{session_id}'
    meta_key = f'grammarly:meta:{session_id}'

    log.info(f'[buffer] session={session_id} incoming_segments={len(segments)}')

    pipe = _redis.pipeline()
    for seg in segments:
        pipe.rpush(buf_key, json.dumps(seg))
    pipe.expire(buf_key, BUFFER_TTL)
    await pipe.execute()

    now = time.time()
    started = await _redis.hget(meta_key, 'started_at')
    if not started:
        await _redis.hset(meta_key, mapping={'started_at': str(now)})
        await _redis.expire(meta_key, BUFFER_TTL)
        started = now
    else:
        started = float(started)

    count = await _redis.llen(buf_key)
    elapsed = now - started

    log.info(f'[buffer] session={session_id} count={count}/{CHUNK_THRESHOLD} elapsed={elapsed:.1f}s/{TIME_THRESHOLD_SECONDS}s')

    if count >= CHUNK_THRESHOLD or elapsed >= TIME_THRESHOLD_SECONDS:
        raw = await _redis.lrange(buf_key, 0, -1)
        await _redis.delete(buf_key, meta_key)
        log.info(f'[buffer] session={session_id} TRIGGERED — flushing {len(raw)} segments')
        return True, [json.loads(r) for r in raw]

    log.info(f'[buffer] session={session_id} buffering...')
    return False, []


async def close():
    await _redis.aclose()
