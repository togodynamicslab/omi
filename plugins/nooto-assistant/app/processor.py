import asyncio
import json
import logging
import random
import re
import time
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

import httpx
import redis.asyncio as aioredis
from ddgs import DDGS
from langchain_openai import ChatOpenAI

from app import buffer, omi_client
from app.config import (
    OPENROUTER_API_KEY,
    LLM_MODEL,
    DETECT_MODEL,
    REDIS_URL,
    DETECT_PROMPT,
    ANSWER_PROMPT,
    DIRECT_ANSWER_PROMPT,
    NOTIFICATION_COOLDOWN_SECONDS,
)

log = logging.getLogger('uvicorn.error')

_redis = aioredis.from_url(REDIS_URL, decode_responses=True)

# Qwen3 thinking mode produces <think>...</think> blocks — strip them from responses
_THINK_RE = re.compile(r'<think>.*?</think>', re.DOTALL)

# Refusal phrases — detect model sometimes says "I don't know" instead of answering
_REFUSAL_PHRASES = [
    'não tenho', 'no tengo', "i don't have", "i don't know",
    'não sei', 'no sé', 'not sure',
    'banco de dados', 'database', 'base de datos',
    'não consigo', 'no puedo', "i can't",
]

# Timezone cruft the detect model keeps adding to queries despite prompt instructions
_TZ_CRUFT_RE = re.compile(
    r'\s*\b(?:in\s+)?(?:'
    r'florida\s+time|'
    r'[a-z]+\s+time\s*zone?|'
    r'horário\s+d[aeo]\s+\w+|'
    r'hora\s+d[aeo]\s+\w+'
    r')\b',
    re.IGNORECASE,
)


def _strip_think(text: str) -> str:
    """Remove Qwen3 <think> reasoning blocks from LLM output."""
    return _THINK_RE.sub('', text).strip()


def _clean_query(query: str) -> str:
    """Strip timezone references from search queries — handled via USER_TIMEZONE instead."""
    cleaned = _TZ_CRUFT_RE.sub('', query).strip()
    # Remove trailing prepositions left after stripping
    cleaned = re.sub(r'\s+(?:in|at|for|de|da|do|em|no|na)\s*$', '', cleaned, flags=re.IGNORECASE).strip()
    return cleaned or query


_llm = ChatOpenAI(
    base_url='https://openrouter.ai/api/v1',
    api_key=OPENROUTER_API_KEY,
    model=LLM_MODEL,
)

# Fast model for detection + inline answers — no thinking overhead
_llm_detect = ChatOpenAI(
    base_url='https://openrouter.ai/api/v1',
    api_key=OPENROUTER_API_KEY,
    model=DETECT_MODEL,
    model_kwargs={'response_format': {'type': 'json_object'}},
)

_ddgs = DDGS()

# Jina Reader — fetches full page content from URLs (free, no API key)
_JINA_URL = 'https://r.jina.ai/'
_JINA_TIMEOUT = 8
_JINA_MAX_CHARS = 4000
_jina = httpx.AsyncClient(timeout=_JINA_TIMEOUT, follow_redirects=True)


async def _fetch_page(url: str) -> str | None:
    """Fetch full page content via Jina Reader. Returns markdown text or None."""
    try:
        resp = await _jina.get(f'{_JINA_URL}{url}')
        if resp.status_code == 200 and len(resp.text) > 100:
            return resp.text[:_JINA_MAX_CHARS]
        log.warning(f'[jina] status={resp.status_code} len={len(resp.text)} url={url}')
    except Exception as e:
        log.warning(f'[jina] error fetching {url}: {e}')
    return None

# Inspired by Claude Code's spinner verbs — localized per language
_THINKING_MESSAGES = {
    'pt': [
        'Opa! Pensando... 🧠',
        'Peraí... Calculando... 🧠',
        'Hmm, deixa eu ver... 🧠',
        'Calma aí que já vai! 🧠',
        'Eita, buscando... 🧠',
        'Opa! Já tô ligado... 🧠',
        'Segura firme... 🧠',
        'Tô correndo atrás! 🧠',
        'Xiiii, deixa comigo... 🧠',
        'Rapidinho, tá? 🧠',
        'Ihhh, peraí... 🧠',
        'Só um minutinho... 🧠',
        'Tô bolando aqui... 🧠',
        'Vixe, deixa eu pesquisar... 🧠',
        'Hmm, interessante... 🧠',
        'Boa pergunta! Buscando... 🧠',
        'Valeu! Já tô vendo... 🧠',
        'Oxe, peraí... 🧠',
        'Tô fuçando aqui... 🧠',
        'Opa! Tô nessa... 🧠',
        'Pera que eu descubro! 🧠',
        'Uai, deixa eu ver... 🧠',
        'Massa! Buscando... 🧠',
        'Tô de olho, calma... 🧠',
        'Epa! Processando... 🧠',
        'Bora ver isso... 🧠',
        'Hmmm, cozinhando a resposta... 🧠',
    ],
    'es': [
        '¡Opa! Pensando... 🧠',
        'Un momento... Calculando... 🧠',
        'Hmm, Procesando... 🧠',
        'Déjame ver... Cocinando... 🧠',
        'Buscando... 🧠',
        'Conjurando... 🧠',
        'Contemplando... 🧠',
        'Descifrando... 🧠',
        'Imaginando... 🧠',
        'Forjando... 🧠',
        'Germinando... 🧠',
        'Marinando... 🧠',
        'Rumiando... 🧠',
        'Fermentando... 🧠',
        'Sintetizando... 🧠',
        'Maquinando... 🧠',
        'Hmm, Tramando... 🧠',
        'Elaborando... 🧠',
    ],
    'en': [
        'Opa! Thinking... 🧠',
        'Hold on... Calculating... 🧠',
        'Hmm, Processing... 🧠',
        'Let me check... Brewing... 🧠',
        'Conjuring... 🧠',
        'Contemplating... 🧠',
        'Deciphering... 🧠',
        'Imagining... 🧠',
        'Forging... 🧠',
        'Cooking... 🧠',
        'Marinating... 🧠',
        'Ruminating... 🧠',
        'Simmering... 🧠',
        'Synthesizing... 🧠',
        'Wizarding... 🧠',
        'Pondering... 🧠',
        'Hmm, Scheming... 🧠',
        'Crafting... 🧠',
        'Noodling... 🧠',
        'Vibing... 🧠',
    ],
}

# Default thinking message when language isn't known yet (trigger word just detected)
_DEFAULT_THINKING = [
    'Opa! 🧠',
    'Hmm... 🧠',
    '🧠...',
    'Opa! Thinking... 🧠',
    'Opa! Pensando... 🧠',
]

PENDING_ANSWER_KEY = 'nooto:answer:{session_id}'
PENDING_ANSWER_TTL = 15  # seconds — answer expires if no webhook comes


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


async def is_on_cooldown(session_id: str) -> bool:
    return await _redis.exists(_cooldown_key(session_id)) > 0


async def _set_cooldown(session_id: str) -> None:
    await _redis.set(_cooldown_key(session_id), '1', ex=NOTIFICATION_COOLDOWN_SECONDS)


async def _detect_question(transcript: str, memory_context: str = '', user_time_zone: str | None = None) -> dict:
    """Cheap LLM call to check if transcript contains a question for Opa."""
    user_content = transcript
    if memory_context:
        user_content = f'RECENT CONVERSATION:\n{memory_context}\n\nCURRENT TRANSCRIPT:\n{transcript}'
    if user_time_zone:
        user_content += f'\n\nUSER_TIMEZONE: {user_time_zone}'
    messages = [('system', DETECT_PROMPT), ('human', user_content)]

    try:
        response = await _llm_detect.ainvoke(messages)
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


async def _format_answer(
    query: str, search_results: str, language: str = 'en', memory_context: str = '', user_time_zone: str | None = None
) -> str:
    """LLM call to format search results into a short push notification answer."""
    if user_time_zone:
        try:
            tz = ZoneInfo(user_time_zone)
            now = datetime.now(tz).strftime(f'%Y-%m-%d %H:%M ({user_time_zone})')
        except KeyError:
            now = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')
    else:
        now = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')
    log.info(f'[answer] TODAY={now} language={language} query="{query}"')
    system_prompt = ANSWER_PROMPT.replace('{today}', now)
    tz_line = f'\nUSER_TIMEZONE: {user_time_zone}' if user_time_zone else ''
    user_content = f'TODAY: {now}\nLANGUAGE: {language}{tz_line}\nQUESTION: {query}\n\nSEARCH RESULTS:\n{search_results}'
    if memory_context:
        user_content += f'\n\nRECENT CONVERSATION (for context):\n{memory_context}'
    user_content += '\n\nREMINDER: Every fact in your answer MUST appear literally in the SEARCH RESULTS above. If the specific answer is not there, say "not found". Do NOT fill in from your own knowledge — that is hallucination.'
    messages = [('system', system_prompt), ('human', user_content)]

    try:
        response = await _llm.ainvoke(messages)
    except Exception as e:
        log.error(f'[answer] LLM call failed: {e}')
        return "Sorry, I couldn't find an answer right now."

    raw = response.content
    log.info(f'[answer] raw_response={raw[:500]}')
    return _strip_think(raw)


async def _format_direct_answer(
    query: str, language: str = 'en', memory_context: str = '', user_time_zone: str | None = None
) -> str:
    """LLM call to answer a factual question directly from model knowledge (no search)."""
    user_content = f'LANGUAGE: {language}\nQUESTION: {query}'
    if memory_context:
        user_content += f'\n\nRECENT CONVERSATION (for context):\n{memory_context}'
    messages = [('system', DIRECT_ANSWER_PROMPT), ('human', user_content)]

    try:
        response = await _llm.ainvoke(messages)
    except Exception as e:
        log.error(f'[direct] LLM call failed: {e}')
        return "Sorry, I couldn't answer that right now."

    raw = response.content
    log.info(f'[direct] raw_response={raw[:500]}')
    return _strip_think(raw)


async def process_and_decide(
    segments: list[dict], session_id: str, user_time_zone: str | None = None, trigger_time: float | None = None
) -> None:
    """Background processing: detect → search → format → store answer for next webhook."""
    t_start = time.monotonic()

    # Build transcript from segments
    transcript = '\n'.join(
        f"{'User' if s.get('is_user') or s.get('speaker_id', 0) == 0 else 'Other'}: {s.get('text', '')}"
        for s in segments
    )

    # Load conversation memory for context
    memory = await _get_memory(session_id)
    memory_context = _format_memory(memory)

    # Step 1: Detect question (with memory for follow-ups)
    t_detect = time.monotonic()
    detection = await _detect_question(transcript, memory_context, user_time_zone=user_time_zone)
    dt_detect = time.monotonic() - t_detect

    if not detection.get('has_question'):
        log.info(f'[processor] session={session_id} reason=no_question detect={dt_detect:.2f}s')
        return

    raw_query = detection.get('query', '').strip()
    if not raw_query:
        log.info(f'[processor] session={session_id} reason=empty_query detect={dt_detect:.2f}s')
        return

    language = detection.get('language', 'en') or 'en'
    needs_search = detection.get('needs_search', True)
    query = _clean_query(raw_query) if needs_search else raw_query
    inline_answer = detection.get('answer', '').strip() if not needs_search else ''

    # Reject inline answers that are refusals — fall through to the main LLM instead
    if inline_answer and any(p in inline_answer.lower() for p in _REFUSAL_PHRASES):
        log.info(f'[processor] session={session_id} inline answer looks like refusal, falling through to direct')
        inline_answer = ''

    # Determine route: inline (answered in detect call), direct (separate call), or search
    if inline_answer:
        route = 'inline'
    elif needs_search:
        route = 'search'
    else:
        route = 'direct'

    log.info(f'[processor] session={session_id} route={route} query="{query}" tz={user_time_zone} detect={dt_detect:.2f}s')

    # Step 2: Get answer
    dt_search = 0.0
    dt_answer = 0.0
    if route == 'inline':
        # Answer already came from the detect call — zero extra latency
        answer = inline_answer
    elif route == 'search':
        t_search = time.monotonic()
        # Add current month/year for time-sensitive searches
        now = datetime.now(timezone.utc)
        search_query = f'{query} {now.strftime("%B %Y")}'
        log.info(f'[processor] session={session_id} searching: "{search_query}"')
        results = []
        try:
            results = await asyncio.to_thread(_ddgs.text, search_query, max_results=5, timelimit='w') or []
        except Exception as e:
            log.error(f'[processor] session={session_id} search failed: {e}')

        # Fallback: retry without time filter if weekly results are empty
        if not results:
            log.info(f'[processor] session={session_id} no weekly results, retrying without time filter')
            try:
                results = await asyncio.to_thread(_ddgs.text, search_query, max_results=5) or []
            except Exception as e:
                log.error(f'[processor] session={session_id} fallback search failed: {e}')

        if not results:
            dt_search = time.monotonic() - t_search
            log.info(f'[processor] session={session_id} reason=no_search_results search={dt_search:.2f}s')
            return

        snippets = '\n'.join(f"- {r['title']}: {r['body']}" for r in results)
        dt_search = time.monotonic() - t_search
        log.info(f'[processor] session={session_id} search_results ({dt_search:.2f}s):\n{snippets[:500]}')

        # Fetch full page content from top result via Jina Reader
        urls = [r['href'] for r in results if r.get('href')]
        page_content = None
        dt_jina = 0.0
        if urls:
            t_jina = time.monotonic()
            page_content = await _fetch_page(urls[0])
            dt_jina = time.monotonic() - t_jina
            if page_content:
                log.info(f'[jina] fetched {len(page_content)} chars from {urls[0]} ({dt_jina:.2f}s)')

        # Use full page content if available, otherwise fall back to snippets
        if page_content:
            search_results = f'Page content from {urls[0]}:\n{page_content}'
        else:
            search_results = snippets

        t_answer = time.monotonic()
        answer = await _format_answer(query, search_results, language, memory_context, user_time_zone=user_time_zone)
        dt_answer = time.monotonic() - t_answer
    else:
        # Direct fallback — detect model didn't include answer
        log.info(f'[processor] session={session_id} direct answer: "{query}"')
        t_answer = time.monotonic()
        answer = await _format_direct_answer(query, language, memory_context, user_time_zone=user_time_zone)
        dt_answer = time.monotonic() - t_answer

    # Step 3: Track question length, store Q&A in memory, and send via API
    text_len = sum(len(s.get('text', '')) for s in segments)
    await buffer.store_question_length(session_id, text_len)
    await _add_memory(session_id, query, answer)
    await _set_cooldown(session_id)

    dt_total = time.monotonic() - t_start
    parts = [f'detect={dt_detect:.2f}s']
    if route == 'search':
        parts.append(f'search={dt_search:.2f}s')
        if dt_jina > 0:
            parts.append(f'jina={dt_jina:.2f}s')
    if dt_answer > 0:
        parts.append(f'answer={dt_answer:.2f}s')
    parts.append(f'total={dt_total:.2f}s')
    parts.append(f'qlen={text_len}')
    if trigger_time is not None:
        dt_e2e = time.monotonic() - trigger_time
        parts.append(f'e2e={dt_e2e:.2f}s')
    perf = ' '.join(parts)

    log.info(f'[processor] session={session_id} READY route={route} {perf} — answer="{answer}"')
    await omi_client.send_notification(session_id, answer)
