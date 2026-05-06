"""
Plan-guidance router.

`POST /v2/plan/guidance` — stream a short "what to do next, and why" line for
the Plan tab, grounded on the user's `today_context` (same shape the brief
uses). Wire-compatible with the brief stream so the Flutter `ChatService` SSE
parser handles both with no special-casing.
"""

import logging
from typing import Any, Dict, Optional

from fastapi import APIRouter, Depends
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from utils.llm.plan_guidance import stream_plan_guidance
from utils.other import endpoints as auth

logger = logging.getLogger(__name__)
router = APIRouter()


class PlanGuidanceRequest(BaseModel):
    today_context: Dict[str, Any]
    now_iso: Optional[str] = None


@router.post("/v2/plan/guidance", tags=["plan"])
async def plan_guidance(
    body: PlanGuidanceRequest,
    uid: str = Depends(auth.with_rate_limit(auth.get_current_user_uid, "plan:guidance")),
) -> StreamingResponse:
    logger.info("plan/guidance uid=%s remaining=%s", uid, body.today_context.get("plan_remaining_count"))

    async def stream():
        async for chunk in stream_plan_guidance(body.today_context, body.now_iso):
            # Match the brief's SSE shape: text/event-stream with `data: <chunk>`
            # lines and `__CRLF__` placeholder for embedded newlines so the
            # Flutter parser can rejoin them.
            payload = chunk.replace("\n", "__CRLF__")
            yield f"data: {payload}\n\n"

    return StreamingResponse(stream(), media_type="text/event-stream")
