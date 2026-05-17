"""Pre-warm Jira workflow status classifications for a freshly-connected user.

When a user finishes the Jira OAuth flow, we want the first sync to find every
workflow status already classified — so the brief is correct from minute one
instead of after one cron cycle's worth of inline LLM calls.

Mechanism (per design doc Day 3):
  1. Set ``jira:prewarm_in_progress:{uid}:{cloudid}`` (TTL = PREWARM_FLAG_TTL).
     The sync-path classifier (:func:`classify_statuses_for_sync`) checks this
     flag and short-circuits to fallback (no LLM call, no cache write) while
     we're in flight, so the cron and the pre-warm cannot race to double-spend
     LLM calls or poison the cache.
  2. HTTP GET the plugin's ``/v1/internal/workflow-statuses`` endpoint — the
     plugin holds the Jira OAuth token and proxies the upstream
     ``/rest/api/3/workflow/search?expand=statuses`` call. Backend does not
     need to know Jira auth (per backend service map: plugin owns tokens).
  3. Build a deduped ``list[StatusInput]`` and call
     :func:`classify_statuses` (the direct entry point, not the sync wrapper —
     we're the one holding the pre-warm flag).
  4. Always clear the flag in a ``finally`` block, even on error.

Cross-reference: design doc "Recommended Approach" decision #4 (post-OAuth
durable-write path) and cross-model tension fix #9 (project-scoped endpoint).
"""

from __future__ import annotations

import logging
from typing import Optional

import httpx

from database.redis_db import r as redis_client
from utils.integrations import jira_status_classifier
from utils.integrations.jira_status_classifier import StatusInput
from utils.log_sanitizer import sanitize, sanitize_pii

logger = logging.getLogger(__name__)

_PREWARM_HTTP_TIMEOUT = 20.0
_WORKFLOW_STATUSES_PATH = "/v1/internal/workflow-statuses"

# Plugin writes this Redis flag in its OAuth callback's durable-write path so
# the backend cron picks up freshly-connected users without a plugin -> backend
# HTTP call. Format: jira:prewarm_pending:{uid}:{cloudid}.
_PREWARM_PENDING_KEY_PATTERN = "jira:prewarm_pending:{uid}:*"
_PREWARM_PENDING_SCAN_PATTERN = "jira:prewarm_pending:*"

# Jira statusCategory keys we recognize. Anything outside this set is coerced
# to "indeterminate" so the StatusInput Pydantic model accepts it; better to
# classify with imperfect context than to drop the row entirely.
_VALID_STATUS_CATEGORIES = {"new", "indeterminate", "done"}


def _normalize_status_category(value: Optional[str]) -> str:
    if not value:
        return "indeterminate"
    lowered = value.strip().lower()
    return lowered if lowered in _VALID_STATUS_CATEGORIES else "indeterminate"


async def _fetch_workflow_statuses(
    uid: str,
    plugin_base_url: str,
    http_client: Optional[httpx.AsyncClient] = None,
) -> list[dict]:
    """GET ``/v1/internal/workflow-statuses`` from the plugin and return its
    ``statuses`` list. Empty list on any non-200 / transport error.
    """
    endpoint = f"{plugin_base_url.rstrip('/')}{_WORKFLOW_STATUSES_PATH}"
    owns_client = http_client is None
    client = http_client or httpx.AsyncClient(timeout=_PREWARM_HTTP_TIMEOUT)
    try:
        try:
            resp = await client.get(endpoint, params={"uid": uid})
        except httpx.RequestError as exc:
            logger.warning(
                "[JiraPrewarm] network error contacting plugin uid=%s err=%s",
                uid,
                sanitize(str(exc)),
            )
            return []
        if resp.status_code != 200:
            logger.warning(
                "[JiraPrewarm] plugin returned %s uid=%s body=%s",
                resp.status_code,
                uid,
                sanitize(resp.text[:500]),
            )
            return []
        body = resp.json() or {}
    finally:
        if owns_client:
            await client.aclose()

    statuses = body.get("statuses") or []
    return statuses if isinstance(statuses, list) else []


def _build_status_inputs(raw_statuses: list[dict]) -> list[StatusInput]:
    """Dedupe by status_name, coerce status_category into the allowed set."""
    seen: dict[str, StatusInput] = {}
    for raw in raw_statuses:
        if not isinstance(raw, dict):
            continue
        name = (raw.get("status_name") or "").strip()
        if not name or name in seen:
            continue
        seen[name] = StatusInput(
            status_name=name,
            status_category=_normalize_status_category(raw.get("status_category")),
            project_key=raw.get("project_key"),
        )
    return list(seen.values())


async def prewarm_user_workflow_classifications(
    uid: str,
    cloudid: str,
    plugin_base_url: str,
    http_client: Optional[httpx.AsyncClient] = None,
) -> dict:
    """Fetch the workflow statuses for the user's accessible projects, classify
    them in a single batch LLM call, and populate the per-status cache.

    Sets and clears ``jira:prewarm_in_progress:{uid}:{cloudid}`` to prevent the
    inline sync classifier from racing.

    Returns ``{"classified": int, "errors": int, "skipped": bool}``.
        - ``classified``: count of statuses we obtained a non-fallback
          classification for (i.e. that the cache now holds).
        - ``errors``: 1 if any step (flag set, HTTP fetch, classify) raised
          or returned an empty/error result; 0 otherwise.
        - ``skipped``: True when there were no statuses to classify (empty
          workflow list); ``classified`` will also be 0.
    """  # noqa: D205
    flag_key = jira_status_classifier._prewarm_flag_key(uid, cloudid)

    # Set the flag BEFORE fetching, so any cron tick that overlaps with the
    # fetch-then-classify window also short-circuits.
    try:
        redis_client.setex(flag_key, jira_status_classifier.PREWARM_FLAG_TTL, "1")
    except Exception as exc:
        logger.warning(
            "[JiraPrewarm] failed to set prewarm flag uid=%s cloudid=%s err=%s",
            uid,
            cloudid,
            sanitize(str(exc)),
        )
        return {"classified": 0, "errors": 1, "skipped": False}

    try:
        raw_statuses = await _fetch_workflow_statuses(uid, plugin_base_url, http_client=http_client)
        if not raw_statuses:
            logger.info(
                "[JiraPrewarm] no workflow statuses returned, skipping classify uid=%s cloudid=%s",
                uid,
                cloudid,
            )
            return {"classified": 0, "errors": 1, "skipped": True}

        status_inputs = _build_status_inputs(raw_statuses)
        if not status_inputs:
            logger.info(
                "[JiraPrewarm] zero distinct status names after dedupe uid=%s cloudid=%s",
                uid,
                cloudid,
            )
            return {"classified": 0, "errors": 0, "skipped": True}

        try:
            results = await jira_status_classifier.classify_statuses(cloudid, status_inputs)
        except Exception as exc:
            logger.warning(
                "[JiraPrewarm] classify_statuses raised uid=%s cloudid=%s err=%s",
                uid,
                cloudid,
                sanitize(str(exc)),
            )
            return {"classified": 0, "errors": 1, "skipped": False}

        classified = sum(1 for cached in results.values() if cached.source != "fallback")
        # Count fallback entries (LLM didn't fill in) as a soft error signal —
        # the cache wasn't poisoned (fallback never writes) but the metric is
        # incomplete and the next sync will retry inline.
        had_fallback = any(cached.source == "fallback" for cached in results.values())
        for name, cached in results.items():
            logger.info(
                "[JiraPrewarm] result uid=%s cloudid=%s status=%s actionability=%s source=%s",
                uid,
                cloudid,
                sanitize_pii(name),
                cached.actionability,
                cached.source,
            )

        return {
            "classified": classified,
            "errors": 1 if had_fallback else 0,
            "skipped": False,
        }
    finally:
        try:
            redis_client.delete(flag_key)
        except Exception as exc:
            logger.warning(
                "[JiraPrewarm] failed to clear prewarm flag uid=%s cloudid=%s err=%s",
                uid,
                cloudid,
                sanitize(str(exc)),
            )


def _iter_pending_cloudids(uid: str) -> list[str]:
    """Return cloudids that have a ``jira:prewarm_pending:{uid}:{cloudid}`` flag.

    Reads-and-collects via SCAN so we don't load the full keyspace; one tick
    of the cron is expected to find 0 or 1 pending entries per user.
    """
    pattern = _PREWARM_PENDING_KEY_PATTERN.format(uid=uid)
    pending: list[str] = []
    try:
        for raw_key in redis_client.scan_iter(pattern, count=100):
            key = raw_key.decode() if isinstance(raw_key, (bytes, bytearray)) else str(raw_key)
            # key = "jira:prewarm_pending:{uid}:{cloudid}"
            parts = key.split(":")
            if len(parts) < 4:
                continue
            cloudid = parts[-1]
            if cloudid:
                pending.append(cloudid)
    except Exception as exc:
        logger.warning(
            "[JiraPrewarm] scan pending failed uid=%s err=%s",
            uid,
            sanitize(str(exc)),
        )
    return pending


async def consume_pending_prewarms(
    uid: str,
    plugin_base_url: str,
    http_client: Optional[httpx.AsyncClient] = None,
) -> int:
    """Run pre-warm for every pending (uid, cloudid) flag, then delete each.

    Called at the start of every per-user sync iteration in the Jira cron.
    Returns the number of pre-warms executed (usually 0).
    """
    cloudids = _iter_pending_cloudids(uid)
    if not cloudids:
        return 0
    ran = 0
    for cloudid in cloudids:
        try:
            await prewarm_user_workflow_classifications(
                uid=uid,
                cloudid=cloudid,
                plugin_base_url=plugin_base_url,
                http_client=http_client,
            )
        except Exception as exc:
            logger.warning(
                "[JiraPrewarm] prewarm raised uid=%s cloudid=%s err=%s",
                uid,
                cloudid,
                sanitize(str(exc)),
            )
        finally:
            try:
                redis_client.delete(
                    f"jira:prewarm_pending:{uid}:{cloudid}",
                )
            except Exception as exc:
                logger.warning(
                    "[JiraPrewarm] failed to clear pending flag uid=%s cloudid=%s err=%s",
                    uid,
                    cloudid,
                    sanitize(str(exc)),
                )
        ran += 1
    return ran


async def run_pending_prewarms_all_users(
    plugin_base_url: str,
    http_client: Optional[httpx.AsyncClient] = None,
) -> dict:
    """Scan the keyspace once and run pre-warm for every pending (uid, cloudid).

    Called from the Jira cron BEFORE ``sync_all_users_jira`` so the first
    sync after OAuth connect already finds the cache populated. Keeps the
    pre-warm logic out of the sync hot path so this lane stays disjoint
    from the sync-wiring lane.

    Returns ``{"users": N, "prewarmed": K}``.
    """
    pending_by_uid: dict[str, list[str]] = {}
    try:
        for raw_key in redis_client.scan_iter(_PREWARM_PENDING_SCAN_PATTERN, count=500):
            key = raw_key.decode() if isinstance(raw_key, (bytes, bytearray)) else str(raw_key)
            # key = "jira:prewarm_pending:{uid}:{cloudid}"
            parts = key.split(":")
            if len(parts) < 4:
                continue
            uid = parts[2]
            cloudid = parts[3]
            if not uid or not cloudid:
                continue
            pending_by_uid.setdefault(uid, []).append(cloudid)
    except Exception as exc:
        logger.warning("[JiraPrewarm] global scan pending failed err=%s", sanitize(str(exc)))
        return {"users": 0, "prewarmed": 0}

    if not pending_by_uid:
        return {"users": 0, "prewarmed": 0}

    owns_client = http_client is None
    client = http_client or httpx.AsyncClient(timeout=_PREWARM_HTTP_TIMEOUT)
    try:
        total_prewarmed = 0
        for uid, cloudids in pending_by_uid.items():
            for cloudid in cloudids:
                try:
                    await prewarm_user_workflow_classifications(
                        uid=uid,
                        cloudid=cloudid,
                        plugin_base_url=plugin_base_url,
                        http_client=client,
                    )
                except Exception as exc:
                    logger.warning(
                        "[JiraPrewarm] prewarm raised uid=%s cloudid=%s err=%s",
                        uid,
                        cloudid,
                        sanitize(str(exc)),
                    )
                finally:
                    try:
                        redis_client.delete(f"jira:prewarm_pending:{uid}:{cloudid}")
                    except Exception as exc:
                        logger.warning(
                            "[JiraPrewarm] failed to clear pending flag uid=%s cloudid=%s err=%s",
                            uid,
                            cloudid,
                            sanitize(str(exc)),
                        )
                total_prewarmed += 1
        summary = {"users": len(pending_by_uid), "prewarmed": total_prewarmed}
        logger.info("[JiraPrewarm] cron pre-warm pass complete %s", summary)
        return summary
    finally:
        if owns_client:
            await client.aclose()
