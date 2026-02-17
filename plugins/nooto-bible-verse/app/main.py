import asyncio
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, Query

from app import buffer, omi_client
from app.config import DAILY_VERSE_ENABLED
from app.cron import register_user, start_scheduler
from app.models import WebhookRequest
from app.processor import process_and_decide

log = logging.getLogger('uvicorn.error')

_scheduler = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _scheduler
    if DAILY_VERSE_ENABLED:
        _scheduler = start_scheduler()
    yield
    if _scheduler:
        _scheduler.shutdown(wait=False)
    await buffer.close()
    await omi_client.close()


app = FastAPI(title='Omi Sandbox Plugin', lifespan=lifespan)


@app.get('/health')
async def health():
    return {'status': 'ok'}


@app.post('/webhook/transcript')
async def handle_transcript(payload: WebhookRequest, uid: str = Query(default='')):
    if not payload.segments:
        return {}

    # Omi backend sends uid as query param; body session_id is the same value
    session_id = uid or payload.session_id
    if not session_id:
        return {}

    # Track user for daily verse delivery
    if DAILY_VERSE_ENABLED and uid:
        await register_user(uid)

    segments_raw = [s.model_dump() for s in payload.segments]
    ready, accumulated = await buffer.add_segments(session_id, segments_raw)

    if not ready:
        return {}

    # Fire LLM processing in the background so the webhook returns immediately.
    # The Omi backend has a 10s timeout — LLM calls can exceed that.
    # Notifications are sent directly via the Omi API from the background task.
    asyncio.create_task(_process_in_background(accumulated, session_id))
    return {}


async def _process_in_background(segments: list[dict], session_id: str):
    try:
        result = await process_and_decide(segments, session_id)
        log.info(f'[webhook] uid={session_id} result={result}')
    except Exception as e:
        log.error(f'[webhook] uid={session_id} background processing failed: {e}')
