import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, Query

from app import buffer, omi_client
from app.models import WebhookRequest
from app.processor import process_and_decide

log = logging.getLogger('uvicorn.error')


@asynccontextmanager
async def lifespan(app: FastAPI):
    yield
    await buffer.close()
    await omi_client.close()


app = FastAPI(title='Grammarly Lite', lifespan=lifespan)


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
    ready, accumulated = await buffer.add_segments(session_id, segments_raw)

    if not ready:
        return {}

    result = await process_and_decide(accumulated, session_id)
    log.info(f'[webhook] uid={session_id} result={result}')
    return result or {}
