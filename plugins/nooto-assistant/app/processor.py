import asyncio
import json
import logging
import random
from datetime import datetime, timezone

import redis.asyncio as aioredis
from langchain_community.tools import DuckDuckGoSearchRun
from langchain_openai import ChatOpenAI

from app import omi_client
from app.config import (
    OPENROUTER_API_KEY,
    LLM_MODEL,
    REDIS_URL,
    DETECT_PROMPT,
    ANSWER_PROMPT,
    NOTIFICATION_COOLDOWN_SECONDS,
    WEBHOOK_FALLBACK_SECONDS,
)

log = logging.getLogger('uvicorn.error')

_redis = aioredis.from_url(REDIS_URL, decode_responses=True)

_llm = ChatOpenAI(
    base_url='https://openrouter.ai/api/v1',
    api_key=OPENROUTER_API_KEY,
    model=LLM_MODEL,
)

_llm_json = ChatOpenAI(
    base_url='https://openrouter.ai/api/v1',
    api_key=OPENROUTER_API_KEY,
    model=LLM_MODEL,
    model_kwargs={'response_format': {'type': 'json_object'}},
)

_search = DuckDuckGoSearchRun()

# Inspired by Claude Code's spinner verbs — localized per language
_THINKING_MESSAGES = {
    'pt': [
        'Opa! Pensando... 🧠', 'Peraí... Calculando... 🧠', 'Hmm, Processando... 🧠',
        'Deixa eu ver... Cozinhando... 🧠', 'Buscando... 🧠', 'Conjurando... 🧠',
        'Contemplando... 🧠', 'Decifrando... 🧠', 'Imaginando... 🧠',
        'Forjando... 🧠', 'Germinando... 🧠', 'Marinando... 🧠',
        'Ruminando... 🧠', 'Fermentando... 🧠', 'Sintetizando... 🧠',
        'Destrinchando... 🧠', 'Peraí... Maquinando... 🧠', 'Elaborando... 🧠',
        'Desvendando... 🧠', 'Hmm, Bolando... 🧠',
    ],
    'es': [
        '¡Opa! Pensando... 🧠', 'Un momento... Calculando... 🧠', 'Hmm, Procesando... 🧠',
        'Déjame ver... Cocinando... 🧠', 'Buscando... 🧠', 'Conjurando... 🧠',
        'Contemplando... 🧠', 'Descifrando... 🧠', 'Imaginando... 🧠',
        'Forjando... 🧠', 'Germinando... 🧠', 'Marinando... 🧠',
        'Rumiando... 🧠', 'Fermentando... 🧠', 'Sintetizando... 🧠',
        'Maquinando... 🧠', 'Hmm, Tramando... 🧠', 'Elaborando... 🧠',
    ],
    'en': [
        'Opa! Thinking... 🧠', 'Hold on... Calculating... 🧠', 'Hmm, Processing... 🧠',
        'Let me check... Brewing... 🧠', 'Conjuring... 🧠', 'Contemplating... 🧠',
        'Deciphering... 🧠', 'Imagining... 🧠', 'Forging... 🧠',
        'Cooking... 🧠', 'Marinating... 🧠', 'Ruminating... 🧠',
        'Simmering... 🧠', 'Synthesizing... 🧠', 'Wizarding... 🧠',
        'Pondering... 🧠', 'Hmm, Scheming... 🧠', 'Crafting... 🧠',
        'Noodling... 🧠', 'Vibing... 🧠',
    ],
}

# Default thinking message when language isn't known yet (trigger word just detected)
_DEFAULT_THINKING = [
    'Opa! 🧠', 'Hmm... 🧠', '🧠...', 'Opa! Thinking... 🧠', 'Opa! Pensando... 🧠',
]

PENDING_ANSWER_KEY = 'nooto:answer:{session_id}'
PENDING_ANSWER_TTL = 60  # seconds — answer expires if no webhook comes


def thinking_message(language: str | None = None) -> str:
    if not language:
        return random.choice(_DEFAULT_THINKING)
    messages = _THINKING_MESSAGES.get(language, _THINKING_MESSAGES['en'])
    return random.choice(messages)


async def store_pending_answer(session_id: str, answer: str) -> None:
    key = PENDING_ANSWER_KEY.format(session_id=session_id)
    await _redis.set(key, answer, ex=PENDING_ANSWER_TTL)
    log.info(f'[processor] stored pending answer for {session_id} (TTL={PENDING_ANSWER_TTL}s)')


async def pop_pending_answer(session_id: str) -> str | None:
    key = PENDING_ANSWER_KEY.format(session_id=session_id)
    answer = await _redis.getdel(key)
    if answer:
        log.info(f'[processor] popped pending answer for {session_id}')
    return answer


def _cooldown_key(session_id: str) -> str:
    return f'nooto:cd:{session_id}'


async def _is_on_cooldown(session_id: str) -> bool:
    return await _redis.exists(_cooldown_key(session_id)) > 0


async def _set_cooldown(session_id: str) -> None:
    await _redis.set(_cooldown_key(session_id), '1', ex=NOTIFICATION_COOLDOWN_SECONDS)


async def _detect_question(transcript: str) -> dict:
    """Cheap LLM call to check if transcript contains a question for Opa."""
    messages = [('system', DETECT_PROMPT), ('human', transcript)]

    try:
        response = await _llm_json.ainvoke(messages)
    except Exception as e:
        log.error(f'[detect] LLM call failed: {e}')
        return {'has_question': False, 'query': ''}

    raw = response.content
    log.info(f'[detect] raw_response={raw}')

    try:
        parsed = json.loads(raw)
        # LLM sometimes returns a list (one per segment) — take the last one with a question
        if isinstance(parsed, list):
            with_question = [p for p in parsed if p.get('has_question')]
            parsed = with_question[-1] if with_question else {'has_question': False, 'query': ''}
        return parsed
    except json.JSONDecodeError:
        log.warning(f'[detect] invalid JSON: {raw}')
        return {'has_question': False, 'query': ''}


async def _format_answer(query: str, search_results: str, language: str = 'en') -> str:
    """LLM call to format search results into a short push notification answer."""
    now = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')
    user_content = f'TODAY: {now}\nLANGUAGE: {language}\nQUESTION: {query}\n\nSEARCH RESULTS:\n{search_results}'
    messages = [('system', ANSWER_PROMPT), ('human', user_content)]

    try:
        response = await _llm.ainvoke(messages)
    except Exception as e:
        log.error(f'[answer] LLM call failed: {e}')
        return "Sorry, I couldn't find an answer right now."

    return response.content.strip()


async def process_and_decide(segments: list[dict], session_id: str) -> None:
    """Background processing: detect → search → format → store answer for next webhook."""
    # Check cooldown
    if await _is_on_cooldown(session_id):
        log.info(f'[processor] session={session_id} reason=cooldown — skipping')
        return

    # Build transcript from segments
    transcript = '\n'.join(
        f"{'User' if s.get('is_user') or s.get('speaker_id', 0) == 0 else 'Other'}: {s.get('text', '')}"
        for s in segments
    )

    # Step 1: Detect question
    detection = await _detect_question(transcript)

    if not detection.get('has_question'):
        log.info(f'[processor] session={session_id} reason=no_question')
        return

    query = detection.get('query', '').strip()
    if not query:
        log.info(f'[processor] session={session_id} reason=empty_query')
        return

    language = detection.get('language', 'en') or 'en'

    # Step 2: Web search
    today = datetime.now(timezone.utc).strftime('%B %Y')
    search_query = f'{query} {today}'
    log.info(f'[processor] session={session_id} searching: "{search_query}"')
    try:
        search_results = await asyncio.to_thread(_search.run, search_query)
    except Exception as e:
        log.error(f'[processor] session={session_id} search failed: {e}')
        search_results = ''

    if not search_results:
        log.info(f'[processor] session={session_id} reason=no_search_results')
        return

    # Step 3: Format answer
    answer = await _format_answer(query, search_results, language)

    # Step 4: Store answer in Redis — next webhook call will deliver it
    await _set_cooldown(session_id)
    log.info(f'[processor] session={session_id} reason=READY — answer="{answer}"')
    await store_pending_answer(session_id, answer)

    # Step 5: Hybrid fallback — wait for a webhook to pick up the answer,
    # if nobody picks it up within WEBHOOK_FALLBACK_SECONDS, send via API
    await asyncio.sleep(WEBHOOK_FALLBACK_SECONDS)
    remaining = await pop_pending_answer(session_id)
    if remaining:
        log.info(f'[processor] session={session_id} fallback — no webhook picked up, sending via API')
        await omi_client.send_notification(session_id, remaining)
    else:
        log.info(f'[processor] session={session_id} answer delivered via webhook')
