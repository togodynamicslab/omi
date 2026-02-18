import asyncio
import logging
import re
from contextlib import asynccontextmanager

from fastapi import FastAPI, Query

from app import buffer, omi_client
from app.models import WebhookRequest
from app.processor import process_and_decide, pop_pending_answer, thinking_message

log = logging.getLogger('uvicorn.error')

# Speech-to-text variations of "Opa" trigger word (common STT garbles)
_TRIGGER_PATTERN = re.compile(
    r'\bopa\b',
    re.IGNORECASE,
)


def _has_trigger(segments) -> bool:
    return any(_TRIGGER_PATTERN.search(s.text) for s in segments)


def _notify_response(message: str) -> dict:
    """Build a webhook response that triggers an Omi notification."""
    return {'message': message}


@asynccontextmanager
async def lifespan(app: FastAPI):
    yield
    await buffer.close()
    await omi_client.close()


app = FastAPI(title='Nooto Assistant', lifespan=lifespan)


@app.get('/health')
async def health():
    return {'status': 'ok'}


@app.post('/webhook/transcript')
async def handle_transcript(payload: WebhookRequest, uid: str = Query(default='')):
    if not payload.segments:
        log.info(f'[webhook] uid={uid} — no segments, skipping')
        return {}

    session_id = uid or payload.session_id
    if not session_id:
        log.info('[webhook] no session_id or uid, skipping')
        return {}

    log.info(f'[webhook] uid={session_id} segments={len(payload.segments)} text="{payload.segments[0].text[:80]}..."')

    segments_raw = [s.model_dump() for s in payload.segments]

    # Check if there's a pending answer from a previous search — deliver it
    pending = await pop_pending_answer(session_id)
    if pending:
        log.info(f'[webhook] uid={session_id} DELIVERING pending answer: "{pending}"')
        return _notify_response(pending)

    # If trigger word detected, flush buffer and start processing in background
    # Return a "thinking" message immediately via webhook response
    if _has_trigger(payload.segments):
        log.info(f'[webhook] uid={session_id} TRIGGER WORD detected — flushing immediately')
        accumulated = await buffer.flush(session_id, segments_raw)
        asyncio.create_task(_process_in_background(accumulated, session_id))
        return _notify_response(thinking_message())

    ready, accumulated = await buffer.add_segments(session_id, segments_raw)

    if not ready:
        return {}

    asyncio.create_task(_process_in_background(accumulated, session_id))
    return {}


async def _process_in_background(segments: list[dict], session_id: str):
    try:
        await process_and_decide(segments, session_id)
    except Exception as e:
        log.error(f'[webhook] uid={session_id} background processing failed: {e}')
