"""Unit tests for `_normalize_jira_issue` — covers the Lane A1 contract
extension from the Jira terminal-states design.

These tests stub the plugin's heavier runtime deps (fastapi, db,
jira_client, models, httpx) before importing `routes.tools` so they can
run in a barebones interpreter without the plugin's full venv. The
function under test is pure-Python and dict-shaped, so the stubs only
need to satisfy the import.
"""

import os
import sys
import types

# Make `import routes.tools` resolve to this plugin.
_PLUGIN_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir))
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)


def _install_stubs() -> None:
    """Inject minimal stub modules for `routes.tools`'s top-level imports.

    Idempotent — safe to call from each test or once at import time.
    """
    if "fastapi" not in sys.modules:
        fastapi = types.ModuleType("fastapi")

        class _APIRouter:
            def __init__(self, *a, **k):
                pass

            def post(self, *a, **k):
                def deco(fn):
                    return fn

                return deco

            def get(self, *a, **k):
                def deco(fn):
                    return fn

                return deco

        fastapi.APIRouter = _APIRouter
        sys.modules["fastapi"] = fastapi

    if "httpx" not in sys.modules:
        httpx = types.ModuleType("httpx")

        class _HTTPStatusError(Exception):
            pass

        httpx.HTTPStatusError = _HTTPStatusError
        sys.modules["httpx"] = httpx

    if "db" not in sys.modules:
        db = types.ModuleType("db")
        db.get_active_jira = lambda uid: None
        db.get_jira_tokens = lambda uid: None
        sys.modules["db"] = db

    if "jira_client" not in sys.modules:
        jira_client = types.ModuleType("jira_client")

        class _Err(Exception):
            pass

        jira_client.JiraAuthError = _Err
        jira_client.JiraNotFound = _Err
        jira_client.JiraRateLimit = _Err
        sys.modules["jira_client"] = jira_client

    if "models" not in sys.modules:
        models = types.ModuleType("models")

        class _Base:
            def __init__(self, **kw):
                for k, v in kw.items():
                    setattr(self, k, v)

        for name in (
            "ChatToolResponse",
            "JiraAddCommentRequest",
            "JiraCreateIssueRequest",
            "JiraGetIssueRequest",
            "JiraIssueDetailsResponse",
            "JiraListMyIssuesRequest",
            "JiraListProjectsRequest",
            "JiraListReleasesRequest",
            "JiraSearchIssuesRequest",
            "JiraUpdateDueDateRequest",
            "JiraUpdateStatusRequest",
        ):
            setattr(models, name, type(name, (_Base,), {}))
        sys.modules["models"] = models


_install_stubs()

from routes.tools import _normalize_jira_issue  # noqa: E402


def _base_issue(**field_overrides):
    """Minimum-viable Jira REST issue payload; tests override `fields.*`."""
    fields = {
        "summary": "Ship the thing",
        "status": {"name": "In Progress", "statusCategory": {"key": "indeterminate"}},
        "priority": {"name": "Medium"},
        "assignee": {"displayName": "Matheus"},
        "updated": "2026-05-17T10:00:00.000+0000",
        "duedate": None,
        "description": None,
        "statuscategorychangedate": "2026-05-15T10:00:00.000+0000",
    }
    fields.update(field_overrides)
    return {"key": "PROJ-123", "fields": fields}


def test_cloudid_threaded_through_into_payload():
    out = _normalize_jira_issue(_base_issue(), site_url="https://acme.atlassian.net", cloudid="abc")
    assert out["cloudid"] == "abc"


def test_resolution_name_populated_when_resolved():
    out = _normalize_jira_issue(
        _base_issue(resolution={"name": "Done", "id": "10000"}),
        site_url="https://acme.atlassian.net",
        cloudid="abc",
    )
    assert out["resolution_name"] == "Done"


def test_resolution_name_none_when_unresolved():
    out = _normalize_jira_issue(
        _base_issue(resolution=None),
        site_url="https://acme.atlassian.net",
        cloudid="abc",
    )
    assert out["resolution_name"] is None


def test_resolution_name_none_when_resolution_field_missing():
    """Open issues commonly omit `resolution` entirely rather than nulling it."""
    issue = _base_issue()
    issue["fields"].pop("resolution", None)
    out = _normalize_jira_issue(issue, site_url="https://acme.atlassian.net", cloudid="abc")
    assert out["resolution_name"] is None


def test_existing_fields_preserved():
    """Lane A1 must be additive: every pre-existing key still emitted."""
    out = _normalize_jira_issue(_base_issue(), site_url="https://acme.atlassian.net", cloudid="abc")
    for key in (
        "external_id",
        "title",
        "description",
        "status",
        "status_type",
        "due_at",
        "priority",
        "url",
        "project",
        "project_key",
        "assignee",
        "updated_at",
        "status_changed_at",
    ):
        assert key in out, f"missing pre-existing key {key!r}"


if __name__ == "__main__":
    test_cloudid_threaded_through_into_payload()
    test_resolution_name_populated_when_resolved()
    test_resolution_name_none_when_unresolved()
    test_resolution_name_none_when_resolution_field_missing()
    test_existing_fields_preserved()
    print("OK: all 5 tests passed")
