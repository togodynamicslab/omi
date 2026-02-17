import json
import logging
from pathlib import Path

import redis.asyncio as aioredis
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.cron import CronTrigger
from openai import AsyncOpenAI

from app.config import (
    OPENROUTER_API_KEY,
    LLM_MODEL,
    REDIS_URL,
    DAILY_VERSE_HOUR,
    USER_TIMEZONE,
    DAILY_VERSE_CONVERSATIONS_LIMIT,
)
from app import omi_client

log = logging.getLogger('uvicorn.error')

_redis = aioredis.from_url(REDIS_URL, decode_responses=True)
_client = AsyncOpenAI(base_url='https://openrouter.ai/api/v1', api_key=OPENROUTER_API_KEY)

USERS_SET_KEY = 'sandbox:daily_verse:users'
DAILY_VERSE_HISTORY_KEY = 'sandbox:daily_verse_history:{uid}'
DAILY_VERSE_HISTORY_MAX = 30  # remember last 30 daily verses
DAILY_VERSE_HISTORY_TTL = 60 * 60 * 24 * 30  # 30 days

_root = Path(__file__).resolve().parent.parent


def _build_daily_prompt() -> str:
    """Build the daily verse system prompt from template + soul files."""
    template_path = _root / 'prompts' / 'daily_verse.md'
    template = template_path.read_text().strip()

    custom_rules_path = _root / 'soul' / 'custom_rules.md'
    custom_rules = custom_rules_path.read_text().strip() if custom_rules_path.exists() else ''

    personality_path = _root / 'soul' / 'personality.md'
    personality = personality_path.read_text().strip() if personality_path.exists() else ''

    return template.format(custom_rules=custom_rules, personality=personality)


DAILY_SYSTEM_PROMPT = _build_daily_prompt()


async def register_user(uid: str):
    """Track a user for daily verse delivery."""
    await _redis.sadd(USERS_SET_KEY, uid)


async def _get_tracked_users() -> set[str]:
    return await _redis.smembers(USERS_SET_KEY)


async def _get_daily_verse_history(uid: str) -> list[str]:
    key = DAILY_VERSE_HISTORY_KEY.format(uid=uid)
    return await _redis.lrange(key, 0, -1)


async def _record_daily_verse(uid: str, verse_ref: str):
    key = DAILY_VERSE_HISTORY_KEY.format(uid=uid)
    await _redis.lpush(key, verse_ref)
    await _redis.ltrim(key, 0, DAILY_VERSE_HISTORY_MAX - 1)
    await _redis.expire(key, DAILY_VERSE_HISTORY_TTL)


def _extract_conversation_summary(conversation: dict) -> str:
    """Extract a readable summary from a conversation object."""
    structured = conversation.get('structured', {})
    title = structured.get('title', 'Untitled')
    overview = structured.get('overview', '')
    emoji = structured.get('emoji', '')

    action_items = structured.get('action_items', [])
    actions_text = ', '.join(item.get('description', '') for item in action_items[:3]) if action_items else ''

    parts = [f'{emoji} {title}']
    if overview:
        parts.append(overview)
    if actions_text:
        parts.append(f'Action items: {actions_text}')

    return '\n'.join(parts)


async def _generate_daily_verse(uid: str) -> str | None:
    """Fetch conversations and generate a daily verse for a user."""
    conversations = await omi_client.get_conversations(uid, limit=DAILY_VERSE_CONVERSATIONS_LIMIT)
    if not conversations:
        log.info(f'No conversations found for {uid}, skipping daily verse')
        return None

    summaries = []
    for conv in conversations:
        summary = _extract_conversation_summary(conv)
        if summary.strip():
            summaries.append(summary)

    if not summaries:
        log.info(f'No conversation summaries for {uid}, skipping daily verse')
        return None

    recent_verses = await _get_daily_verse_history(uid)

    user_content_parts = ['[Recent conversations]']
    for i, s in enumerate(summaries, 1):
        user_content_parts.append(f'{i}. {s}')
    if recent_verses:
        user_content_parts.append(f'\n[Already sent recently — do NOT repeat: {", ".join(recent_verses)}]')

    user_content = '\n'.join(user_content_parts)

    messages = [
        {'role': 'system', 'content': DAILY_SYSTEM_PROMPT},
        {'role': 'user', 'content': user_content},
    ]

    try:
        response = await _client.chat.completions.create(
            model=LLM_MODEL,
            messages=messages,
            response_format={'type': 'json_object'},
        )
    except Exception as e:
        log.error(f'Daily verse LLM call failed for {uid}: {e}')
        return None

    raw = response.choices[0].message.content
    try:
        result = json.loads(raw)
    except json.JSONDecodeError:
        log.warning(f'Daily verse LLM returned invalid JSON for {uid}: {raw}')
        return None

    message = result.get('message', '').strip()
    theme = result.get('theme', '')
    reason = result.get('reason', '')
    log.info(f'Daily verse for {uid}: theme={theme!r}, reason={reason!r}, message={message!r}')

    if message:
        verse_ref = message.split('—')[0].strip() if '—' in message else message[:30]
        await _record_daily_verse(uid, verse_ref)

    return message


async def send_daily_verses():
    """Main cron job: send a daily verse to all tracked users."""
    users = await _get_tracked_users()
    if not users:
        log.info('Daily verse cron: no tracked users')
        return

    log.info(f'Daily verse cron: processing {len(users)} users')
    for uid in users:
        try:
            message = await _generate_daily_verse(uid)
            if message:
                await omi_client.send_notification(uid, message)
        except Exception as e:
            log.error(f'Daily verse failed for {uid}: {e}')


def start_scheduler() -> AsyncIOScheduler:
    """Start the APScheduler with the daily verse cron job."""
    scheduler = AsyncIOScheduler()
    trigger = CronTrigger(hour=DAILY_VERSE_HOUR, minute=0, timezone=USER_TIMEZONE)
    scheduler.add_job(send_daily_verses, trigger, id='daily_verse', replace_existing=True)
    scheduler.start()
    log.info(f'Daily verse scheduler started: {DAILY_VERSE_HOUR}:00 {USER_TIMEZONE}')
    return scheduler
