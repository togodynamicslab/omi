import asyncio
import json
import logging
import random
import re
from datetime import datetime, timezone

import redis.asyncio as aioredis
from ddgs import DDGS
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

# Qwen3 thinking mode produces <think>...</think> blocks — strip them from responses
_THINK_RE = re.compile(r'<think>.*?</think>', re.DOTALL)


def _strip_think(text: str) -> str:
    """Remove Qwen3 <think> reasoning blocks from LLM output."""
    return _THINK_RE.sub('', text).strip()


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

_ddgs = DDGS()

# Inspired by Claude Code's spinner verbs — localized per language
_THINKING_MESSAGES = {
    'pt': [
        'Opa! Pensando... 🧠', 'Peraí... Calculando... 🧠', 'Hmm, deixa eu ver... 🧠',
        'Calma aí que já vai! 🧠', 'Eita, buscando... 🧠', 'Opa! Já tô ligado... 🧠',
        'Segura firme... 🧠', 'Tô correndo atrás! 🧠', 'Xiiii, deixa comigo... 🧠',
        'Rapidinho, tá? 🧠', 'Ihhh, peraí... 🧠', 'Só um minutinho... 🧠',
        'Tô bolando aqui... 🧠', 'Vixe, deixa eu pesquisar... 🧠', 'Hmm, interessante... 🧠',
        'Boa pergunta! Buscando... 🧠', 'Valeu! Já tô vendo... 🧠', 'Oxe, peraí... 🧠',
        'Tô fuçando aqui... 🧠', 'Opa! Tô nessa... 🧠', 'Pera que eu descubro! 🧠',
        'Uai, deixa eu ver... 🧠', 'Massa! Buscando... 🧠', 'Tô de olho, calma... 🧠',
        'Epa! Processando... 🧠', 'Bora ver isso... 🧠', 'Hmmm, cozinhando a resposta... 🧠',
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


MEMORY_KEY = 'nooto:memory:{session_id}'
MEMORY_TTL = 1800  # 30 min — short-term conversation memory
MAX_MEMORY_PAIRS = 5


async def _get_memory(session_id: str) -> list[dict]:
    key = MEMORY_KEY.format(session_id=session_id)
    raw = await _redis.lrange(key, 0, -1)
    return [json.loads(r) for r in raw]


async def _add_memory(session_id: str, query: str, answer: str) -> None:
    key = MEMORY_KEY.format(session_id=session_id)
    entry = json.dumps({'q': query, 'a': answer})
    pipe = _redis.pipeline()
    pipe.rpush(key, entry)
    pipe.ltrim(key, -MAX_MEMORY_PAIRS, -1)  # keep only last N
    pipe.expire(key, MEMORY_TTL)
    await pipe.execute()
    log.info(f'[memory] session={session_id} stored Q&A (total: {min(await _redis.llen(key), MAX_MEMORY_PAIRS)})')


def _format_memory(memory: list[dict]) -> str:
    if not memory:
        return ''
    lines = []
    for m in memory:
        lines.append(f'Q: {m["q"]}')
        lines.append(f'A: {m["a"]}')
    return '\n'.join(lines)


def _cooldown_key(session_id: str) -> str:
    return f'nooto:cd:{session_id}'


async def _is_on_cooldown(session_id: str) -> bool:
    return await _redis.exists(_cooldown_key(session_id)) > 0


async def _set_cooldown(session_id: str) -> None:
    await _redis.set(_cooldown_key(session_id), '1', ex=NOTIFICATION_COOLDOWN_SECONDS)


async def _detect_question(transcript: str, memory_context: str = '') -> dict:
    """Cheap LLM call to check if transcript contains a question for Opa."""
    user_content = transcript
    if memory_context:
        user_content = f'RECENT CONVERSATION:\n{memory_context}\n\nCURRENT TRANSCRIPT:\n{transcript}'
    messages = [('system', DETECT_PROMPT), ('human', user_content)]

    try:
        response = await _llm_json.ainvoke(messages)
    except Exception as e:
        log.error(f'[detect] LLM call failed: {e}')
        return {'has_question': False, 'query': ''}

    raw = _strip_think(response.content)
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


async def _format_answer(query: str, search_results: str, language: str = 'en', memory_context: str = '') -> str:
    """LLM call to format search results into a short push notification answer."""
    now = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')
    system_prompt = ANSWER_PROMPT.replace('{today}', now)
    user_content = f'TODAY: {now}\nLANGUAGE: {language}\nQUESTION: {query}\n\nSEARCH RESULTS:\n{search_results}'
    if memory_context:
        user_content += f'\n\nRECENT CONVERSATION (for context):\n{memory_context}'
    user_content += '\n\nREMINDER: ONLY use facts from the SEARCH RESULTS above. Do NOT use your own knowledge.'
    messages = [('system', system_prompt), ('human', user_content)]

    try:
        response = await _llm.ainvoke(messages)
    except Exception as e:
        log.error(f'[answer] LLM call failed: {e}')
        return "Sorry, I couldn't find an answer right now."

    return _strip_think(response.content)


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

    # Load conversation memory for context
    memory = await _get_memory(session_id)
    memory_context = _format_memory(memory)

    # Step 1: Detect question (with memory for follow-ups)
    detection = await _detect_question(transcript, memory_context)

    if not detection.get('has_question'):
        log.info(f'[processor] session={session_id} reason=no_question')
        return

    query = detection.get('query', '').strip()
    if not query:
        log.info(f'[processor] session={session_id} reason=empty_query')
        return

    language = detection.get('language', 'en') or 'en'

    # Step 2: Web search (DuckDuckGo with week filter for fresh results)
    log.info(f'[processor] session={session_id} searching: "{query}"')
    try:
        results = await asyncio.to_thread(_ddgs.text, query, max_results=5, timelimit='w')
        search_results = '\n'.join(f"- {r['title']}: {r['body']}" for r in results) if results else ''
    except Exception as e:
        log.error(f'[processor] session={session_id} search failed: {e}')
        search_results = ''

    # Fallback: retry without time filter if weekly results are empty
    if not search_results:
        log.info(f'[processor] session={session_id} no weekly results, retrying without time filter')
        try:
            results = await asyncio.to_thread(_ddgs.text, query, max_results=5)
            search_results = '\n'.join(f"- {r['title']}: {r['body']}" for r in results) if results else ''
        except Exception as e:
            log.error(f'[processor] session={session_id} fallback search failed: {e}')
            search_results = ''

    if not search_results:
        log.info(f'[processor] session={session_id} reason=no_search_results')
        return

    log.info(f'[processor] session={session_id} search_results:\n{search_results[:500]}')

    # Step 3: Format answer (with memory for context)
    answer = await _format_answer(query, search_results, language, memory_context)

    # Step 4: Store Q&A in memory and answer in Redis
    await _add_memory(session_id, query, answer)
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
