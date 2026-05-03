"""
Simple per-UID rate limiting config.

Each policy defines (max_requests, window_seconds). One window per policy —
no multi-tier caps. Fair use already handles budget enforcement; this layer
prevents abuse and protects backend resources.

Tuning knobs:
    RATE_LIMIT_BOOST: float multiplier on all limits (default 1.0).
        Set > 1.0 during events to relax limits, < 1.0 to tighten.
        Applied to RATE_POLICIES base values; bypassed when an override
        for the same policy is present in RATE_LIMIT_OVERRIDES.

    RATE_LIMIT_OVERRIDES: comma-separated per-policy absolute overrides.
        Format: "policy_name=max:window_seconds,policy_name=max:window".
        Example:
            RATE_LIMIT_OVERRIDES="conversations:reprocess=30:3600,conversations:merge=8:3600"
        When a policy is overridden, the base value AND boost are both
        ignored — the env value is the effective limit. This is the knob
        for per-environment tuning (loosen on staging dogfood, tighten in
        prod) without code changes or redeploys.

    RATE_LIMIT_SHADOW: defaults OFF (enforcement/429 rejections). Set env var
        RATE_LIMIT_SHADOW_MODE=true to revert to shadow/log-only mode.

Redis efficiency:
    Each check = 1 Lua script call (atomic INCR + TTL check).
    Multi-instance safe — all state in Redis, no in-process caching.
"""

import logging
import os

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Global knobs (read at import time from env vars)
# ---------------------------------------------------------------------------

RATE_LIMIT_BOOST: float = float(os.getenv("RATE_LIMIT_BOOST", "1.0"))
RATE_LIMIT_SHADOW: bool = os.getenv("RATE_LIMIT_SHADOW_MODE", "false").lower() != "false"


def parse_overrides(env_value: str) -> dict[str, tuple[int, int]]:
    """Parse the RATE_LIMIT_OVERRIDES env value into a per-policy override map.

    Format: ``policy_name=max:window,policy_name=max:window``. Whitespace
    around entries is tolerated. Malformed entries (missing ``=``, non-int
    max/window, missing ``:`` in spec) are skipped with a warning so a
    single typo can't take the whole config offline.

    Returns an empty dict for empty/whitespace-only input.
    """
    overrides: dict[str, tuple[int, int]] = {}
    if not env_value or not env_value.strip():
        return overrides
    for entry in env_value.split(","):
        entry = entry.strip()
        if not entry:
            continue
        if "=" not in entry:
            logger.warning("RATE_LIMIT_OVERRIDES: skipping entry without '=': %r", entry)
            continue
        name, _, spec = entry.partition("=")
        name = name.strip()
        spec = spec.strip()
        if not name or ":" not in spec:
            logger.warning("RATE_LIMIT_OVERRIDES: skipping malformed entry: %r", entry)
            continue
        try:
            max_str, _, window_str = spec.partition(":")
            max_req = int(max_str)
            window = int(window_str)
            if max_req < 1 or window < 1:
                logger.warning("RATE_LIMIT_OVERRIDES: skipping non-positive entry: %r", entry)
                continue
            overrides[name] = (max_req, window)
        except ValueError:
            logger.warning("RATE_LIMIT_OVERRIDES: skipping non-numeric entry: %r", entry)
            continue
    return overrides


RATE_LIMIT_OVERRIDES: dict[str, tuple[int, int]] = parse_overrides(
    os.getenv("RATE_LIMIT_OVERRIDES", "")
)

# ---------------------------------------------------------------------------
# Policies: "name" -> (max_requests, window_seconds)
#
# max_requests is the BASE limit before boost is applied.
# Effective limit = int(max_requests * boost).
# ---------------------------------------------------------------------------

RATE_POLICIES: dict[str, tuple[int, int]] = {
    # Conversations — each triggers ~22 OpenAI calls
    "conversations:create": (10, 3600),
    # Reprocess: bumped from upstream's 3/hour. App-picker dogfooding
    # hits the lower cap immediately — try 4 apps in a row and you're
    # blocked for 44 minutes. 10/hour matches conversations:create
    # (same ~22 OpenAI calls per request) and matches the natural
    # rhythm of swapping summary apps a few times per conversation.
    "conversations:reprocess": (10, 3600),
    "conversations:merge": (5, 3600),
    # Chat — 2-6 LLM calls per message
    "chat:send_message": (120, 3600),
    "chat:initial": (60, 3600),
    # Voice — Deepgram + LLM
    "voice:transcribe": (60, 3600),
    "voice:message": (60, 3600),
    "file:upload": (40, 3600),
    # Agent/MCP — bursty tool calls
    "agent:execute_tool": (120, 3600),
    "mcp:sse": (200, 3600),
    # Memories — single LLM call each
    "memories:create": (60, 3600),
    # Goals — single LLM call
    "goals:suggest": (30, 3600),
    "goals:advice": (30, 3600),
    "goals:extract": (30, 3600),
    # Search
    "conversations:search": (60, 3600),
    # Expensive background ops
    "knowledge_graph:rebuild": (2, 3600),
    "wrapped:generate": (2, 86400),
    # Integration (key = app_id:uid)
    "integration:conversations": (10, 3600),
    "integration:memories": (60, 3600),
    # Phone verification uses IP-based rate_limit_dependency (pre-auth, no UID).
    # Not migrated to per-UID Lua limiter intentionally.
    # Dev API
    "dev:conversations": (25, 3600),
    "dev:memories": (120, 3600),
    "dev:memories_batch": (15, 3600),
    # Test
    "test:prompt": (30, 3600),
    # Apps
    "apps:generate_prompts": (30, 3600),
}


def get_effective_limit(policy_name: str, boost: float | None = None) -> tuple[int, int]:
    """Return ``(effective_max_requests, window_seconds)`` for ``policy_name``.

    Resolution order:

    1. ``RATE_LIMIT_OVERRIDES`` env var — if the policy is present, the
       override is returned as-is. Boost is ignored. Window from the env
       value, NOT from RATE_POLICIES, so an override can change both
       dimensions in one knob.
    2. ``RATE_POLICIES`` base — multiplied by ``boost`` (or
       ``RATE_LIMIT_BOOST`` when boost is None). Floor of 1 so a tiny
       boost can't fully zero a limit.
    """
    if policy_name in RATE_LIMIT_OVERRIDES:
        return RATE_LIMIT_OVERRIDES[policy_name]
    base_max, window = RATE_POLICIES[policy_name]
    b = boost if boost is not None else RATE_LIMIT_BOOST
    return max(1, int(base_max * b)), window
