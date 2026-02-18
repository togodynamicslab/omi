import json
import logging

import redis.asyncio as aioredis

from app.config import REDIS_URL

log = logging.getLogger('uvicorn.error')

_redis = aioredis.from_url(REDIS_URL, decode_responses=True)

BUFFER_TTL = 300  # 5 min expiry for stale buffers


async def add_segments(session_id: str, segments: list[dict]) -> None:
    """Append segments to the buffer. No auto-flush — only trigger word flushes."""
    buf_key = f'nooto:buf:{session_id}'

    pipe = _redis.pipeline()
    for seg in segments:
        pipe.rpush(buf_key, json.dumps(seg))
    pipe.expire(buf_key, BUFFER_TTL)
    await pipe.execute()

    count = await _redis.llen(buf_key)
    log.info(f'[buffer] session={session_id} buffered — {count} segments total')


async def flush(session_id: str, new_segments: list[dict] | None = None) -> list[dict]:
    """Flush all buffered segments immediately, optionally adding new ones first."""
    buf_key = f'nooto:buf:{session_id}'

    if new_segments:
        pipe = _redis.pipeline()
        for seg in new_segments:
            pipe.rpush(buf_key, json.dumps(seg))
        await pipe.execute()

    raw = await _redis.lrange(buf_key, 0, -1)
    await _redis.delete(buf_key)
    segments = [json.loads(r) for r in raw]
    log.info(f'[buffer] session={session_id} FLUSHED — {len(segments)} segments')
    return segments


async def close():
    await _redis.aclose()
