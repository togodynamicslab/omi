"""Sender resolution for the chat inbox feed.

For a page of N inbox messages, we need to attach a (display_name, avatar_url)
pair to each one. App-authored messages resolve via the apps registry; Brief
(``type='day_summary'``) resolves to a static label.

This module owns:
- A 60s in-process TTL cache keyed by app_id, so a page of N messages with K
  distinct app_ids does at most one Firestore round trip (and zero if every
  app_id was hit in the last 60s).
- ``resolve_senders_for_app_ids``: batch lookup + cache wrapper.
- ``brief_sender_dict``: static sender for day_summary messages.

Module hierarchy: ``database/`` < ``utils/`` < ``routers/``. This file lives at
``utils/`` and depends only on ``database/apps.py``. It is intentionally
isolated from the larger ``utils/apps.py`` so it can be unit tested without
dragging in the entire app registry surface (Redis, Firebase, Stripe).
"""

from __future__ import annotations

import threading
import time as _time
from typing import Any, Dict, Iterable, List, Optional, Tuple

from database.apps import get_apps_by_ids_db

# 60s TTL LRU-ish cache keyed by app_id. TTL is the primary eviction;
# ``_MAX_ENTRIES`` is a safety valve so a misbehaving caller can't grow this
# unbounded inside a long-lived process.
_TTL_SECONDS = 60
_MAX_ENTRIES = 1024
_LOCK = threading.Lock()
# Maps app_id -> (expires_at_monotonic, (display_name, avatar_url))
_CACHE: Dict[str, Tuple[float, Tuple[Optional[str], Optional[str]]]] = {}


def _cache_get(app_id: str) -> Optional[Tuple[Optional[str], Optional[str]]]:
    now = _time.monotonic()
    with _LOCK:
        entry = _CACHE.get(app_id)
        if not entry:
            return None
        expires_at, value = entry
        if expires_at < now:
            _CACHE.pop(app_id, None)
            return None
        return value


def _cache_put(app_id: str, value: Tuple[Optional[str], Optional[str]]) -> None:
    now = _time.monotonic()
    with _LOCK:
        if len(_CACHE) >= _MAX_ENTRIES:
            for k in list(_CACHE.keys())[: max(1, _MAX_ENTRIES // 8)]:
                _CACHE.pop(k, None)
        _CACHE[app_id] = (now + _TTL_SECONDS, value)


def cache_clear() -> None:
    """Test hook — clears the in-process cache."""
    with _LOCK:
        _CACHE.clear()


def resolve_senders_for_app_ids(app_ids: Iterable[Optional[str]]) -> Dict[str, Dict[str, Optional[str]]]:
    """Batch-resolve sender identity for a set of app_ids.

    For each unique non-None app_id in ``app_ids``:
      - Resolves ``display_name`` from app.name (falls back to "App" if null).
      - Resolves ``avatar_url`` from app.image (may be None).

    Performs at most ONE ``get_apps_by_ids_db`` call per request for cache
    misses; cache hits are served in-process under a 60s TTL.

    Returns a dict keyed by app_id.
    """
    distinct_ids: List[str] = []
    seen: set = set()
    for raw in app_ids or []:
        if not raw or not isinstance(raw, str):
            continue
        if raw in seen:
            continue
        seen.add(raw)
        distinct_ids.append(raw)

    out: Dict[str, Dict[str, Optional[str]]] = {}
    to_fetch: List[str] = []
    for app_id in distinct_ids:
        cached = _cache_get(app_id)
        if cached is not None:
            display_name, avatar_url = cached
            out[app_id] = {'display_name': display_name or 'App', 'avatar_url': avatar_url}
        else:
            to_fetch.append(app_id)

    if to_fetch:
        # Single batch round trip for all cache misses on this page.
        fetched = get_apps_by_ids_db(to_fetch)
        by_id = {a.get('id'): a for a in fetched if a and a.get('id')}
        for app_id in to_fetch:
            app_doc = by_id.get(app_id)
            display_name = (app_doc or {}).get('name') if app_doc else None
            avatar_url = (app_doc or {}).get('image') if app_doc else None
            _cache_put(app_id, (display_name, avatar_url))
            out[app_id] = {'display_name': display_name or 'App', 'avatar_url': avatar_url}

    # Free working sets we don't need to keep alive.
    distinct_ids.clear()
    seen.clear()
    to_fetch.clear()

    return out


def brief_sender_dict() -> Dict[str, Any]:
    """Static sender for ``type='day_summary'`` messages."""
    return {'display_name': 'Brief', 'avatar_url': None}
