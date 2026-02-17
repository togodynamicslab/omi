import json
import logging

import redis.asyncio as aioredis
from openai import AsyncOpenAI

from app.config import (
    OPENROUTER_API_KEY,
    LLM_MODEL,
    REDIS_URL,
    SYSTEM_PROMPT,
    NOTIFY_CONFIDENCE_THRESHOLD,
    MEMORY_CONFIDENCE_THRESHOLD,
    NOTIFICATION_COOLDOWN_SECONDS,
    MEMORY_COOLDOWN_SECONDS,
    CORRECTION_HISTORY_MAX,
    CORRECTION_HISTORY_TTL,
    ROLLING_CONTEXT_MAX_LINES,
    ROLLING_CONTEXT_TTL,
)
from app import omi_client

log = logging.getLogger('uvicorn.error')

_redis = aioredis.from_url(REDIS_URL, decode_responses=True)

_client = AsyncOpenAI(
    base_url='https://openrouter.ai/api/v1',
    api_key=OPENROUTER_API_KEY,
)

# Static system message — identical across all calls, enabling prompt caching.
_system_messages = [
    {
        'role': 'system',
        'content': [
            {
                'type': 'text',
                'text': SYSTEM_PROMPT,
                'cache_control': {'type': 'ephemeral'},
            }
        ],
    }
]


def _cooldown_key(session_id: str, kind: str) -> str:
    return f'grammarly:cd:{kind}:{session_id}'


def _history_key(session_id: str) -> str:
    return f'grammarly:history:{session_id}'


def _context_key(session_id: str) -> str:
    return f'grammarly:ctx:{session_id}'


async def _is_on_cooldown(session_id: str, kind: str) -> bool:
    return await _redis.exists(_cooldown_key(session_id, kind)) > 0


async def _set_cooldown(session_id: str, kind: str, ttl: int) -> None:
    await _redis.set(_cooldown_key(session_id, kind), '1', ex=ttl)


async def _get_correction_history(session_id: str) -> list[str]:
    raw = await _redis.lrange(_history_key(session_id), 0, -1)
    return raw


async def _add_to_correction_history(session_id: str, mistake: str) -> None:
    key = _history_key(session_id)
    pipe = _redis.pipeline()
    pipe.lpush(key, mistake.lower().strip())
    pipe.ltrim(key, 0, CORRECTION_HISTORY_MAX - 1)
    pipe.expire(key, CORRECTION_HISTORY_TTL)
    await pipe.execute()


async def _is_duplicate_correction(session_id: str, mistake: str) -> bool:
    history = await _get_correction_history(session_id)
    return mistake.lower().strip() in history


async def _append_rolling_context(session_id: str, lines: list[str]) -> str:
    key = _context_key(session_id)
    pipe = _redis.pipeline()
    for line in lines:
        pipe.rpush(key, line)
    pipe.expire(key, ROLLING_CONTEXT_TTL)
    await pipe.execute()

    # Trim to max lines
    length = await _redis.llen(key)
    if length > ROLLING_CONTEXT_MAX_LINES:
        await _redis.ltrim(key, length - ROLLING_CONTEXT_MAX_LINES, -1)

    all_lines = await _redis.lrange(key, 0, -1)
    return '\n'.join(all_lines)


async def process_and_decide(segments: list[dict], session_id: str) -> dict | None:
    # Only skip LLM if notification cooldown is active (the main output).
    # Memory cooldown only skips memory creation, not the whole LLM call.
    notify_cd = await _is_on_cooldown(session_id, 'notify')
    memory_cd = await _is_on_cooldown(session_id, 'memory')
    if notify_cd:
        log.info(f'Notification cooldown active for {session_id}, skipping LLM call')
        return None

    # Build transcript from new segments.
    # The Omi device's primary speaker (speaker_id 0) is the wearer (user).
    # is_user defaults to False in the model, so also check speaker_id.
    new_lines = [
        f"{'User' if s.get('is_user') or s.get('speaker_id', 0) == 0 else 'Other'}: {s.get('text', '')}"
        for s in segments
    ]

    # Append to rolling context for broader awareness
    full_context = await _append_rolling_context(session_id, new_lines)

    # Get correction history for pattern detection
    correction_history = await _get_correction_history(session_id)

    # Build user message with context and history
    user_content = f'TRANSCRIPT:\n{full_context}'
    if correction_history:
        user_content += (
            f'\n\nALREADY CORRECTED (if these appear again, it is a PATTERN — flag with is_pattern=true):\n- '
            + '\n- '.join(correction_history)
        )

    messages = _system_messages + [{'role': 'user', 'content': user_content}]

    try:
        response = await _client.chat.completions.create(
            model=LLM_MODEL,
            messages=messages,
            response_format={'type': 'json_object'},
        )
    except Exception as e:
        log.error(f'LLM call failed: {e}')
        return None

    raw = response.choices[0].message.content
    log.info(f'[llm] session={session_id} raw_response={raw}')
    try:
        result = json.loads(raw)
    except json.JSONDecodeError:
        log.warning(f'LLM returned invalid JSON: {raw}')
        return None

    is_pattern = result.get('is_pattern', False)
    pattern_count = result.get('pattern_count', 0)
    log.info(
        f'[llm] session={session_id} should_notify={result.get("should_notify")} '
        f'confidence={result.get("notify_confidence")} is_pattern={is_pattern} '
        f'pattern_count={pattern_count} message="{result.get("message", "")}"'
    )

    # --- Memories ---
    if not memory_cd:
        for mem in result.get('memories', []):
            content = mem.get('content', '').strip()
            confidence = float(mem.get('confidence', 0))
            if not content:
                continue
            if confidence < MEMORY_CONFIDENCE_THRESHOLD:
                log.info(f'Memory skipped (confidence {confidence:.2f} < {MEMORY_CONFIDENCE_THRESHOLD}): {content}')
                continue
            await omi_client.create_memory(session_id, content, mem.get('tags', []))
            await _set_cooldown(session_id, 'memory', MEMORY_COOLDOWN_SECONDS)

    # --- Notification ---
    notify_confidence = float(result.get('notify_confidence', 0))
    mistake_detected = result.get('mistake_detected', '').strip()
    should_notify = result.get('should_notify', False)

    if not should_notify:
        log.info(f'[notify] session={session_id} reason=llm_said_no — LLM did not detect a mistake worth notifying')
        return None

    if notify_confidence < NOTIFY_CONFIDENCE_THRESHOLD:
        log.info(
            f'[notify] session={session_id} reason=low_confidence — '
            f'{notify_confidence:.2f} < {NOTIFY_CONFIDENCE_THRESHOLD} — message="{result.get("message", "")}"'
        )
        return None

    if notify_cd and not is_pattern:
        log.info(f'[notify] session={session_id} reason=cooldown — notification cooldown active, not a pattern')
        return None

    # Patterns bypass dedup — the whole point is the user keeps repeating
    if not is_pattern and mistake_detected and await _is_duplicate_correction(session_id, mistake_detected):
        log.info(f'[notify] session={session_id} reason=duplicate — already corrected: "{mistake_detected}"')
        return None

    # Record correction in history
    if mistake_detected:
        await _add_to_correction_history(session_id, mistake_detected)

    await _set_cooldown(session_id, 'notify', NOTIFICATION_COOLDOWN_SECONDS)

    message = result.get('message', '')
    log.info(f'[notify] session={session_id} reason=SENDING — message="{message}"')
    await omi_client.send_notification(session_id, message)
    return {'message': message}
