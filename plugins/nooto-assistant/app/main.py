import asyncio
import logging
import re
from contextlib import asynccontextmanager

from fastapi import FastAPI, Query

from app import buffer, omi_client
from app.config import TRIGGER_COLLECT_SECONDS
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
    return {
        'message': message,
        'notification': {
            'prompt': message,
            'params': ['user_name'],
        },
    }


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

    # Always buffer incoming segments
    await buffer.add_segments(session_id, segments_raw)

    # On trigger word, return thinking message and schedule delayed flush
    # Delay lets subsequent segments (with the actual question) arrive first
    if _has_trigger(payload.segments):
        log.info(f'[webhook] uid={session_id} TRIGGER WORD detected — collecting for {TRIGGER_COLLECT_SECONDS}s')
        asyncio.create_task(_delayed_flush_and_process(session_id))
        return _notify_response(thinking_message())

    return {}


async def _delayed_flush_and_process(session_id: str):
    """Wait for more segments to arrive (question may follow trigger), then flush and process."""
    await asyncio.sleep(TRIGGER_COLLECT_SECONDS)
    accumulated = await buffer.flush(session_id)
    if not accumulated:
        log.info(f'[webhook] uid={session_id} nothing to process after trigger')
        return
    log.info(f'[webhook] uid={session_id} flushing {len(accumulated)} segments after {TRIGGER_COLLECT_SECONDS}s collect')
    try:
        await process_and_decide(accumulated, session_id)
    except Exception as e:
        log.error(f'[webhook] uid={session_id} background processing failed: {e}')
