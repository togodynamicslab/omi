"""Internal endpoints called by the Nooto backend (private network).

These routes are NOT called from the mobile app — they exist so the backend
can ask the plugin to proxy specific Jira REST calls that need the user's
OAuth token (which only the plugin holds). Per the backend service map in
project CLAUDE.md, plugin and backend run inside the same private network,
so these endpoints intentionally do not enforce auth headers.

Routes:
    GET /v1/internal/workflow-statuses?uid=...
        Proxies Jira's ``/rest/api/3/workflow/search?expand=statuses`` and
        returns a flat, deduped list of status definitions. Used by the
        backend's :mod:`utils.integrations.jira_prewarm` task that fires
        after a user finishes the Jira OAuth flow.
"""

import logging
from typing import Any

from fastapi import APIRouter, HTTPException

import db
from jira_client import JiraAuthError, JiraNotFound, JiraRateLimit, _base, _request

router = APIRouter()
log = logging.getLogger("nooto-jira-app.internal")


def _collect_statuses_from_workflows(workflows_payload: dict[str, Any]) -> list[dict[str, Any]]:
    """Flatten the workflow/search response into a deduped list of statuses.

    Jira's response shape (``/rest/api/3/workflow/search?expand=statuses``):
        {
          "values": [
            {
              "id": {...}, "description": "...",
              "statuses": [
                { "id": "...", "name": "In Progress",
                  "statusCategory": "INDETERMINATE" or {"key": "indeterminate"} }
              ]
            }, ...
          ]
        }

    statusCategory comes back as a string label ("INDETERMINATE") or an
    object with a ``key`` field depending on the workflow API version; we
    normalize both into the lowercase ``"indeterminate"`` shape the backend
    classifier expects.
    """
    seen: dict[str, dict[str, Any]] = {}
    workflows = workflows_payload.get("values") or []
    for wf in workflows:
        statuses = (wf or {}).get("statuses") or []
        for s in statuses:
            name = (s or {}).get("name")
            if not name or name in seen:
                continue
            raw_category = s.get("statusCategory")
            category_key = ""
            if isinstance(raw_category, dict):
                category_key = (raw_category.get("key") or "").lower()
            elif isinstance(raw_category, str):
                category_key = raw_category.lower()
            seen[name] = {
                "status_name": name,
                "status_category": category_key or "indeterminate",
                "project_key": None,  # workflow/search is site-scoped, not project-scoped
            }
    return list(seen.values())


@router.get("/v1/internal/workflow-statuses")
async def list_workflow_statuses(uid: str = "") -> dict[str, Any]:
    """Return the deduped status set for the user's active Jira site.

    Calls Jira REST ``/rest/api/3/workflow/search?expand=statuses`` (which is
    site-scoped — the project filter is implicit in the cloudid) and flattens
    the result into ``{"statuses": [...]}``.
    """
    if not uid:
        raise HTTPException(status_code=400, detail="uid is required")

    active = db.get_active_jira(uid)
    if active is None:
        # No connected Jira / refresh failure. Caller treats empty as a no-op.
        return {"statuses": []}
    token, cloudid, _site_url, _ = active

    url = f"{_base(cloudid)}/workflow/search"
    try:
        resp = _request("GET", url, token, params={"expand": "statuses"})
    except JiraAuthError:
        log.warning("internal/workflow-statuses jira auth failed uid=%s", uid)
        return {"statuses": []}
    except JiraNotFound:
        log.info("internal/workflow-statuses jira 404 uid=%s", uid)
        return {"statuses": []}
    except JiraRateLimit:
        log.warning("internal/workflow-statuses jira rate-limited uid=%s", uid)
        return {"statuses": []}
    except Exception as e:  # pragma: no cover — defensive
        log.exception("internal/workflow-statuses unexpected error uid=%s: %s", uid, e)
        return {"statuses": []}

    payload = resp.json() or {}
    statuses = _collect_statuses_from_workflows(payload)
    log.info("internal/workflow-statuses uid=%s cloudid=%s count=%d", uid, cloudid, len(statuses))
    return {"statuses": statuses}
