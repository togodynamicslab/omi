import json
import logging

import redis.asyncio as aioredis
from openai import AsyncOpenAI

from app.config import (
    OPENROUTER_API_KEY,
    LLM_MODEL,
    SYSTEM_PROMPT,
    REDIS_URL,
    NOTIFY_CONFIDENCE_THRESHOLD,
    TASK_CONFIDENCE_THRESHOLD,
    MEMORY_CONFIDENCE_THRESHOLD,
    NOTIFICATION_COOLDOWN_SECONDS,
    MEMORY_COOLDOWN_SECONDS,
)
from app import omi_client

log = logging.getLogger('uvicorn.error')
VERSE_HISTORY_TTL = 3600  # remember sent verses for 1 hour
VERSE_HISTORY_MAX = 10  # track last 10 verses
CONTEXT_TTL = 600  # rolling conversation context expires after 10 minutes
CONTEXT_MAX_LINES = 50  # keep last 50 transcript lines for context

_redis = aioredis.from_url(REDIS_URL, decode_responses=True)


_client = AsyncOpenAI(
    base_url='https://openrouter.ai/api/v1',
    api_key=OPENROUTER_API_KEY,
)

# Static system message — identical across all calls, enabling prompt caching.
# Providers like DeepSeek and Gemini cache matching prefixes automatically.
# Anthropic models on OpenRouter use cache_control breakpoints.
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


async def _get_recent_verses(session_id: str) -> list[str]:
    key = f'sandbox:verse_history:{session_id}'
    return await _redis.lrange(key, 0, -1)


async def _record_verse(session_id: str, verse_ref: str):
    key = f'sandbox:verse_history:{session_id}'
    await _redis.lpush(key, verse_ref)
    await _redis.ltrim(key, 0, VERSE_HISTORY_MAX - 1)
    await _redis.expire(key, VERSE_HISTORY_TTL)


async def _get_conversation_context(session_id: str) -> str:
    """Get rolling conversation context from Redis."""
    key = f'sandbox:conv_context:{session_id}'
    lines = await _redis.lrange(key, 0, -1)
    return '\n'.join(lines) if lines else ''


async def _append_conversation_context(session_id: str, transcript: str):
    """Append new transcript lines to rolling context, trim to max."""
    key = f'sandbox:conv_context:{session_id}'
    lines = transcript.strip().split('\n')
    for line in lines:
        if line.strip():
            await _redis.rpush(key, line.strip())
    await _redis.ltrim(key, -CONTEXT_MAX_LINES, -1)
    await _redis.expire(key, CONTEXT_TTL)


async def process_and_decide(segments: list[dict], session_id: str) -> dict | None:
    # Check notification cooldown BEFORE calling LLM
    noti_key = f'sandbox:noti_cooldown:{session_id}'
    on_cooldown = await _redis.exists(noti_key)
    if on_cooldown:
        log.info(f'Skipping LLM call — notification on cooldown for session {session_id}')
        return None

    # The Omi device's primary speaker (speaker_id 0) is the wearer (user).
    # is_user defaults to False in the model, so also check speaker_id.
    transcript = '\n'.join(
        f"{'User' if s.get('is_user') or s.get('speaker_id', 0) == 0 else 'Other'}: {s.get('text', '')}"
        for s in segments
    )
    log.info(f'Processing transcript for session {session_id}:\n{transcript}')

    # Build context: previous conversation + current segment
    prior_context = await _get_conversation_context(session_id)
    await _append_conversation_context(session_id, transcript)

    # Include recently sent verses so the LLM avoids repeats
    recent_verses = await _get_recent_verses(session_id)

    # Assemble user message with full context
    parts = []
    if prior_context:
        parts.append(f'[Earlier in the conversation]\n{prior_context}')
        parts.append(f'\n[Latest]\n{transcript}')
    else:
        parts.append(transcript)
    if recent_verses:
        parts.append(f'\n[Already sent recently — do NOT repeat these: {", ".join(recent_verses)}]')
    user_content = '\n'.join(parts)

    # Dynamic part — only this changes per call
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
    try:
        result = json.loads(raw)
    except json.JSONDecodeError:
        log.warning(f'LLM returned invalid JSON: {raw}')
        return None

    log.info(
        f'LLM result for session {session_id}: '
        f'should_notify={result.get("should_notify")}, '
        f'notify_confidence={result.get("notify_confidence")}, '
        f'reason={result.get("notify_reason", "")!r}, '
        f'tasks={len(result.get("tasks", []))}, '
        f'memories={len(result.get("memories", []))}, '
        f'message={result.get("message", "")!r}'
    )

    # --- Tasks ---
    for task in result.get('tasks', []):
        desc = task.get('description', '').strip()
        confidence = float(task.get('confidence', 0))
        if not desc:
            continue
        if confidence < TASK_CONFIDENCE_THRESHOLD:
            log.info(f'Task skipped (confidence {confidence:.2f} < {TASK_CONFIDENCE_THRESHOLD}): {desc}')
            continue
        await omi_client.create_task(session_id, desc, task.get('due_at'))

    # --- Memories (with cooldown) ---
    mem_key = f'sandbox:mem_cooldown:{session_id}'
    mem_on_cooldown = await _redis.exists(mem_key)
    for mem in result.get('memories', []):
        content = mem.get('content', '').strip()
        confidence = float(mem.get('confidence', 0))
        if not content:
            continue
        if confidence < MEMORY_CONFIDENCE_THRESHOLD:
            log.info(f'Memory skipped (confidence {confidence:.2f} < {MEMORY_CONFIDENCE_THRESHOLD}): {content}')
            continue
        if mem_on_cooldown:
            log.info(f'Memory skipped (cooldown): {content}')
            continue
        await omi_client.create_memory(session_id, content, mem.get('tags', []))
        await _redis.set(mem_key, '1', ex=MEMORY_COOLDOWN_SECONDS)
        mem_on_cooldown = True

    # --- Notification ---
    notify_confidence = float(result.get('notify_confidence', 0))
    should_notify = result.get('should_notify', False)

    if not should_notify:
        log.info(f'[notify] session={session_id} reason=llm_said_no — LLM did not find a relevant verse')
        return None

    if notify_confidence < NOTIFY_CONFIDENCE_THRESHOLD:
        log.info(
            f'[notify] session={session_id} reason=low_confidence — '
            f'{notify_confidence:.2f} < {NOTIFY_CONFIDENCE_THRESHOLD} — message="{result.get("message", "")}"'
        )
        return None

    message = result.get('message', '')
    # Set cooldown and record verse
    await _redis.set(noti_key, '1', ex=NOTIFICATION_COOLDOWN_SECONDS)
    # Extract verse reference (e.g. "John 3:16") from the message
    verse_ref = message.split('—')[0].strip() if '—' in message else message[:30]
    await _record_verse(session_id, verse_ref)

    log.info(f'[notify] session={session_id} reason=SENDING — message="{message}"')
    await omi_client.send_notification(session_id, message)
    return {'message': message}
