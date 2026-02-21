import asyncio
import logging
import re
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, Query

from app import buffer, omi_client
from app.config import FLUSH_SILENCE_SECONDS, MIN_COLLECT_SECONDS, MAX_COLLECT_SECONDS
from app.models import WebhookRequest
from app.processor import process_and_decide, thinking_message

log = logging.getLogger('uvicorn.error')

# Speech-to-text variations of "Opa" trigger word (common STT garbles)
_TRIGGER_PATTERN = re.compile(
    r'\bopa\b',
    re.IGNORECASE,
)

# Track pending flush tasks per session so we can cancel on re-trigger
_pending_flush: dict[str, asyncio.Task] = {}

# Per-session collection metadata (set on trigger, cleared on flush)
_collection_meta: dict[str, dict] = {}


def _has_trigger(segments) -> bool:
    return any(_TRIGGER_PATTERN.search(s.text) for s in segments)


def _notify_response(message: str) -> dict:
    """Build a webhook response that triggers an Omi notification."""
    return {
        'notification': {
            'prompt': message,
            'params': ['user_name'],
        },
    }


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Clear stale collecting flags from previous runs (Redis persists across restarts)
    try:
        await buffer.clear_stale_flags()
    except Exception as e:
        log.warning(f'[startup] could not clear stale flags (Redis not ready?): {e}')
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
    is_active = await buffer.is_collecting(session_id)

    has_trigger = _has_trigger(payload.segments)

    # Buffer segments when actively collecting
    if is_active:
        await buffer.add_segments(session_id, segments_raw)
        meta = _collection_meta.get(session_id)
        if meta is not None:
            meta['text_len'] += sum(len(s.text) for s in payload.segments)

    # On trigger word, start or extend collection window
    if has_trigger:
        log.info(f'[webhook] uid={session_id} TRIGGER WORD detected (tz={payload.time_zone})')

        if is_active:
            await buffer.extend_collecting(session_id, MAX_COLLECT_SECONDS)
        else:
            await buffer.start_collecting(session_id, segments_raw, MAX_COLLECT_SECONDS)

        # Ensure meta exists (may be missing after container restart while Redis persisted)
        if session_id not in _collection_meta:
            _collection_meta[session_id] = {
                'trigger_time': time.monotonic(),
                'user_time_zone': payload.time_zone,
                'text_len': sum(len(s.text) for s in payload.segments),
            }

        _reschedule_flush(session_id)
        return {}

    # Non-trigger segment during collection — reset silence timer
    if is_active and session_id in _pending_flush:
        _reschedule_flush(session_id)

    return {}


def _reschedule_flush(session_id: str):
    """Cancel pending flush and schedule a new one (resets silence timer)."""
    old_task = _pending_flush.pop(session_id, None)
    if old_task and not old_task.done():
        old_task.cancel()
    task = asyncio.create_task(_flush_after_silence(session_id))
    _pending_flush[session_id] = task


async def _flush_after_silence(session_id: str):
    """Wait for silence (no new segments), then flush and process."""
    try:
        meta = _collection_meta.get(session_id, {})
        trigger_time = meta.get('trigger_time')
        current_len = meta.get('text_len', 0)

        # Smart silence: shorter if we likely have enough text based on history
        avg_len = await buffer.get_avg_question_length(session_id)
        if avg_len and avg_len > 0 and current_len >= avg_len * 0.7:
            delay = max(2, FLUSH_SILENCE_SECONDS // 2)
            log.info(
                f'[flush] uid={session_id} text={current_len} chars >= 70% of avg={avg_len:.0f}'
                f' — short silence={delay}s'
            )
        else:
            delay = FLUSH_SILENCE_SECONDS

        if trigger_time:
            elapsed = time.monotonic() - trigger_time
            # Enforce minimum collection time — user may pause after "Opa" before asking
            if elapsed < MIN_COLLECT_SECONDS:
                delay = max(delay, MIN_COLLECT_SECONDS - elapsed)
            # Enforce max cap from trigger
            remaining = MAX_COLLECT_SECONDS - elapsed
            delay = min(delay, max(0, remaining))

        if delay > 0:
            await asyncio.sleep(delay)
    except asyncio.CancelledError:
        return
    finally:
        _pending_flush.pop(session_id, None)

    meta = _collection_meta.pop(session_id, None)
    trigger_time = meta.get('trigger_time') if meta else None
    tz = meta.get('user_time_zone') if meta else None

    accumulated = await buffer.flush(session_id)
    if not accumulated:
        log.info(f'[flush] uid={session_id} nothing to process after silence')
        return

    text_len = sum(len(s.get('text', '')) for s in accumulated)
    log.info(f'[flush] uid={session_id} flushing {len(accumulated)} segments ({text_len} chars)')

    # Try to acquire the processing lock
    if await buffer.try_acquire_process_lock(session_id):
        await _drain_queue(session_id, accumulated, tz, trigger_time)
    else:
        # Another question is being processed — queue this one
        await buffer.enqueue_question(session_id, accumulated, tz)


async def _drain_queue(
    session_id: str,
    first_segments: list[dict] | None = None,
    first_tz: str | None = None,
    trigger_time: float | None = None,
) -> None:
    """Process the first payload then drain any queued questions. Releases lock when done."""
    try:
        # Process the initial payload
        if first_segments:
            try:
                await process_and_decide(
                    first_segments, session_id, user_time_zone=first_tz, trigger_time=trigger_time
                )
            except Exception as e:
                log.error(f'[drain] uid={session_id} processing failed: {e}')

        # Drain queued items (no trigger_time — they waited in queue)
        while True:
            item = await buffer.dequeue_question(session_id)
            if item is None:
                break
            segments = item.get('segments', [])
            tz = item.get('user_time_zone')
            log.info(f'[drain] uid={session_id} processing queued question ({len(segments)} segments)')
            try:
                await process_and_decide(segments, session_id, user_time_zone=tz)
            except Exception as e:
                log.error(f'[drain] uid={session_id} queued processing failed: {e}')
    finally:
        await buffer.release_process_lock(session_id)
