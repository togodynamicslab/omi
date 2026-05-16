"""On-device intent parsing for the app-v2 chat composer.

Separate from the conversational `/v2/messages` agent on purpose: that path uses
Sonnet + the full tool registry (Jira, etc.) and is right for chat-tab Q&A.
This endpoint is a one-shot structured-output JSON extraction — gpt-4.1-mini
with `response_format={"type": "json_object"}`. ~20-40× cheaper, ~3-5× faster.

The app-v2 client (`lib/services/intents/cloud_intent_parser.dart`) calls
this when the on-device Apple Foundation Models bridge isn't available
(iOS < 26, or Apple Intelligence-incompatible hardware). The result is the
same schema the native bridge produces (`LLMIntentDraft`), so the downstream
dispatcher (EventKit) handles both paths uniformly.
"""

import json
import logging
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from utils.llm.clients import llm_mini
from utils.other import endpoints as auth

logger = logging.getLogger(__name__)
router = APIRouter()


class IntentParseRequest(BaseModel):
    text: str
    # Optional ISO 8601 "now" anchor from the caller. Lets us resolve
    # relative phrases ("tomorrow", "Friday", "this afternoon") in the
    # caller's timezone without trusting server clock. When omitted we
    # don't supply an anchor and the model will best-effort.
    now_iso: Optional[str] = None
    now_weekday: Optional[str] = None  # e.g. "Saturday" — for prompt clarity


# System prompt is kept identical in shape to the on-device Foundation Models
# instructions so both parsers produce the same draft schema.
_SYSTEM_PROMPT = """You are Nooto's intent parser. Read the user's text and produce a JSON object describing the intent. RESPOND WITH JSON ONLY.

Schema (only the fields applicable to the chosen kind; leave others absent):
{
  "kind": "set_alarm" | "start_timer" | "add_event" | "make_reminder" | "unknown",
  "time": "HH:MM",                       // set_alarm only, 24-hour
  "recurrence": "once" | "daily" | "weekdays",  // set_alarm only
  "seconds": <int>,                      // start_timer only, total seconds
  "title": "...",                        // add_event and make_reminder
  "start": "YYYY-MM-DDTHH:MM:SS",        // add_event, ISO 8601 local
  "durationMinutes": <int>,              // add_event, defaults to 60
  "due": "YYYY-MM-DDTHH:MM:SS",          // make_reminder, optional ISO 8601 local
  "location": "...",                     // add_event, only if explicitly stated
  "notes": "...",                        // add_event, only if explicitly stated
  "label": "...",                        // set_alarm / start_timer, only if user named it
  "reason": "..."                        // unknown only
}

Rules:
- Choose set_alarm for clock-time wake/alarm requests.
- Choose start_timer for countdown ("X minute timer", "pomodoro").
- Choose add_event for meetings, appointments, scheduling, "block N hours".
- Choose make_reminder for "remind me to X", "todo X", "don't forget to X".
- Choose unknown for questions, phone calls, anything else.
- For relative dates, anchor on the "Now:" line in the user message.
- Convert minutes to seconds for start_timer (25 minutes → 1500).
- Strip "remind me to" / "todo" / "don't forget to" prefixes from reminder titles.
- Do NOT invent location or notes. Only set them if the user explicitly said them.
"""


@router.post('/v2/intents/parse', tags=['intents'])
async def parse_intent(
    req: IntentParseRequest,
    uid: str = Depends(auth.get_current_user_uid),
):
    """Parse natural-language text into a structured Nooto intent.

    Cheap structured-output call. Used by the app-v2 cloud-fallback path
    when Apple Foundation Models isn't available. Returns the parsed
    draft directly as JSON; the caller dispatches via its native
    EventKit bridge.
    """
    anchor_lines = []
    if req.now_iso:
        if req.now_weekday:
            anchor_lines.append(f"Now: {req.now_weekday} {req.now_iso}")
        else:
            anchor_lines.append(f"Now: {req.now_iso}")
    anchor_lines.append(f"Input: {req.text}")
    user_content = "\n".join(anchor_lines)

    # response_format = json_object guarantees a parseable JSON string.
    # No tool calls, no streaming — straight extraction.
    bound = llm_mini.bind(response_format={"type": "json_object"})
    try:
        response = await bound.ainvoke(
            [
                {"role": "system", "content": _SYSTEM_PROMPT},
                {"role": "user", "content": user_content},
            ]
        )
    except Exception as e:
        logger.error(f"intents.parse LLM call failed for uid={uid}: {type(e).__name__}: {e}")
        raise HTTPException(status_code=502, detail=f"LLM call failed: {type(e).__name__}")

    content = response.content if hasattr(response, 'content') else str(response)
    if not isinstance(content, str):
        content = str(content)

    try:
        parsed = json.loads(content)
    except json.JSONDecodeError as e:
        logger.error(f"intents.parse JSON decode failed for uid={uid}: {e}; raw={content[:200]}")
        raise HTTPException(status_code=502, detail="LLM returned invalid JSON")

    if not isinstance(parsed, dict):
        raise HTTPException(status_code=502, detail="LLM returned a non-object JSON value")

    # Ensure `kind` is present; default to unknown so the client always
    # gets a valid draft shape even when the model misbehaves.
    if 'kind' not in parsed:
        parsed['kind'] = 'unknown'
        parsed.setdefault('reason', 'model omitted kind field')

    return parsed
