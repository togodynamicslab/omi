"""Tests for the v2 status-override endpoints in routers/integrations.py.

  - GET  /v1/integrations/jira/status-classifications
  - POST /v1/integrations/jira/status-classifications/override

FastAPI / pydantic / jinja2 are stubbed (same pattern as test_jira_sync_now.py)
so the router loads without pulling the real framework. The classifier module
is also stubbed — the unit-level behavior of apply_status_override /
get_cached_classification lives in test_jira_status_classifier.py; here we
only verify the wiring: request shape -> classifier call -> response shape.
"""

import asyncio
import importlib.util
import logging
import os
import sys
import types
from pathlib import Path
from unittest.mock import MagicMock

import pytest

BACKEND_DIR = Path(__file__).resolve().parent.parent.parent

os.environ.setdefault(
    "ENCRYPTION_SECRET",
    "omi_ZwB2ZNqB2HHpMK6wStk7sTpavJiPTFg7gXUHnc4tFABPU6pZ2c2DKgehtfgi4RZv",
)


def _stub_module(name):
    mod = types.ModuleType(name)
    sys.modules[name] = mod
    return mod


def _stub_package(name):
    mod = types.ModuleType(name)
    mod.__path__ = []
    sys.modules[name] = mod
    return mod


# ---------------------------------------------------------------------------
# FastAPI / pydantic / jinja2 / httpx stubs (copied from test_jira_sync_now.py
# so this file is runnable standalone — pytest sessions can collect either
# file first).
# ---------------------------------------------------------------------------


class _FakeHTTPException(Exception):
    def __init__(self, status_code, detail=None):
        super().__init__(f"HTTP {status_code}: {detail}")
        self.status_code = status_code
        self.detail = detail


class _FakeAPIRouter:
    def __init__(self, *args, **kwargs):
        self.routes = []

    def _identity(self, *args, **kwargs):
        def deco(fn):
            return fn

        return deco

    def get(self, *args, **kwargs):
        return self._identity()

    def post(self, *args, **kwargs):
        return self._identity()

    def put(self, *args, **kwargs):
        return self._identity()

    def patch(self, *args, **kwargs):
        return self._identity()

    def delete(self, *args, **kwargs):
        return self._identity()

    def on_event(self, *args, **kwargs):
        return self._identity()


def _fake_depends(dependency=None):
    return dependency


def _fake_query(default=None, **kwargs):
    return default


class _FakeBaseModel:
    def __init__(self, **kwargs):
        for k, v in kwargs.items():
            setattr(self, k, v)

    def model_dump(self, exclude_none=False):
        out = {}
        for k, v in self.__dict__.items():
            if exclude_none and v is None:
                continue
            out[k] = v
        return out


def _fake_field(default=None, **kwargs):
    return default


if "fastapi" in sys.modules and getattr(sys.modules["fastapi"], "_TEST_STUB", False):
    fastapi_pkg = sys.modules["fastapi"]
    _FakeHTTPException = fastapi_pkg.HTTPException  # noqa: F811 — rebind for local use
    _FakeAPIRouter = fastapi_pkg.APIRouter  # noqa: F811
else:
    fastapi_pkg = _stub_package("fastapi")
    fastapi_pkg.APIRouter = _FakeAPIRouter
    fastapi_pkg.Depends = _fake_depends
    fastapi_pkg.HTTPException = _FakeHTTPException
    fastapi_pkg.Query = _fake_query
    fastapi_pkg.Request = object
    fastapi_pkg._TEST_STUB = True

fastapi_responses = _stub_module("fastapi.responses")


class _FakeHTMLResponse:
    def __init__(self, *args, **kwargs):
        self.args = args
        self.kwargs = kwargs


fastapi_responses.HTMLResponse = _FakeHTMLResponse

fastapi_templating = _stub_module("fastapi.templating")


class _FakeJinja2Templates:
    def __init__(self, *args, **kwargs):
        pass

    def TemplateResponse(self, *args, **kwargs):  # noqa: N802
        return _FakeHTMLResponse()


fastapi_templating.Jinja2Templates = _FakeJinja2Templates

if "pydantic" not in sys.modules:
    pydantic_pkg = _stub_package("pydantic")
    pydantic_pkg.BaseModel = _FakeBaseModel
    pydantic_pkg.Field = _fake_field

    class _FakeValidationError(Exception):
        pass

    pydantic_pkg.ValidationError = _FakeValidationError

# httpx — real one expected to be installed; defensive stub for thin envs.
try:
    import httpx as _httpx_real  # noqa: F401
except ImportError:  # pragma: no cover
    httpx_pkg = _stub_module("httpx")
    httpx_pkg.AsyncClient = MagicMock
    httpx_pkg.RequestError = Exception


# ---------------------------------------------------------------------------
# database / utils stubs
# ---------------------------------------------------------------------------

if "database" not in sys.modules:
    _stub_package("database")
    sys.modules["database"].__path__ = [str(BACKEND_DIR / "database")]

users_db = sys.modules.get("database.users") or _stub_module("database.users")
users_db.get_integration = MagicMock(return_value=None)
users_db.set_integration = MagicMock()
users_db.delete_integration = MagicMock(return_value=True)


class _FakeRedisClient:
    def __init__(self):
        self.kv = {}

    def get(self, k):
        return self.kv.get(k)

    def setex(self, k, ttl, v):
        self.kv[k] = v

    def delete(self, k):
        self.kv.pop(k, None)


if "database.redis_db" not in sys.modules:
    redis_db_mod = _stub_module("database.redis_db")
    redis_db_mod.r = _FakeRedisClient()
    redis_db_mod.is_app_enabled = MagicMock(return_value=True)
else:
    redis_db_mod = sys.modules["database.redis_db"]
    if not hasattr(redis_db_mod, "is_app_enabled"):
        redis_db_mod.is_app_enabled = MagicMock(return_value=True)

# action_items: this router test exercises list_jira_status_pairs.
action_items_db = _stub_module("database.action_items")
action_items_db.upsert_external_action_item = MagicMock(return_value="item-1")
action_items_db._find_by_external_source = MagicMock(return_value=None)
action_items_db.list_jira_status_pairs = MagicMock(return_value=[])

apps_db = sys.modules.get("database.apps") or _stub_module("database.apps")
apps_db.get_app_by_id_db = MagicMock(return_value=None)

integration_prefs_db = sys.modules.get("database.integration_prefs") or _stub_module("database.integration_prefs")
integration_prefs_db.set_integration_pref = MagicMock(return_value={})
integration_prefs_db.get_integration_pref = MagicMock(return_value=None)

if "utils" not in sys.modules:
    _stub_package("utils")
    sys.modules["utils"].__path__ = [str(BACKEND_DIR / "utils")]
if "utils.integrations" not in sys.modules:
    _stub_package("utils.integrations")
    sys.modules["utils.integrations"].__path__ = [str(BACKEND_DIR / "utils" / "integrations")]
if "utils.other" not in sys.modules:
    _stub_package("utils.other")
    sys.modules["utils.other"].__path__ = []

log_san = sys.modules.get("utils.log_sanitizer") or _stub_module("utils.log_sanitizer")
log_san.sanitize = lambda v: str(v)
log_san.sanitize_pii = lambda v: str(v)

endpoints_mod = sys.modules.get("utils.other.endpoints") or _stub_module("utils.other.endpoints")
endpoints_mod.get_current_user_uid = MagicMock(return_value="uid-test")

# jira_status_classifier: stub the public surface the router calls so we can
# script per-test responses without touching real Redis/Firestore.
classifier_stub = _stub_module("utils.integrations.jira_status_classifier")


class _StubCachedClassification:
    """Mirrors the fields the router reads off CachedClassification."""

    def __init__(
        self,
        actionability="self",
        certainty="high",
        source="llm",
        classified_at="2026-05-17T00:00:00+00:00",
        status_category="indeterminate",
    ):
        self.actionability = actionability
        self.certainty = certainty
        self.source = source
        self.classified_at = classified_at
        self.status_category = status_category


classifier_stub.CachedClassification = _StubCachedClassification
classifier_stub.get_cached_classification = MagicMock(return_value=None)
classifier_stub.derive_bucket = MagicMock(side_effect=lambda c: "self")
classifier_stub.apply_status_override = MagicMock(return_value={"redis_written": True, "items_updated": 0})


# jira_actions / jira_sync — router imports these at module load.
jira_actions_stub = _stub_module("utils.integrations.jira_actions")


class _JiraActionNotFound(Exception):
    pass


class _JiraActionPluginError(Exception):
    pass


jira_actions_stub.JiraActionNotFound = _JiraActionNotFound
jira_actions_stub.JiraActionPluginError = _JiraActionPluginError
jira_actions_stub.transition_action_item = MagicMock()
jira_actions_stub.fetch_issue_details = MagicMock()
jira_actions_stub.snooze_action_item = MagicMock()

jira_sync_stub = _stub_module("utils.integrations.jira_sync")


async def _noop_sync_wrapper(*args, **kwargs):
    return {"synced": 0, "errors": 0, "last_synced_at": ""}


jira_sync_stub.sync_user_jira_issues_with_timestamp = _noop_sync_wrapper


# ---------------------------------------------------------------------------
# Load the router under test
# ---------------------------------------------------------------------------


def _load_module(dotted_name, file_path):
    spec = importlib.util.spec_from_file_location(dotted_name, str(file_path))
    mod = importlib.util.module_from_spec(spec)
    sys.modules[dotted_name] = mod
    spec.loader.exec_module(mod)
    return mod


integrations_router = _load_module("routers.integrations", BACKEND_DIR / "routers" / "integrations.py")


def _run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


@pytest.fixture(autouse=True)
def _reset():
    action_items_db.list_jira_status_pairs.reset_mock()
    action_items_db.list_jira_status_pairs.return_value = []
    classifier_stub.get_cached_classification.reset_mock()
    classifier_stub.get_cached_classification.return_value = None
    classifier_stub.get_cached_classification.side_effect = None
    classifier_stub.derive_bucket.reset_mock()
    classifier_stub.derive_bucket.side_effect = lambda c: "self"
    classifier_stub.apply_status_override.reset_mock()
    classifier_stub.apply_status_override.return_value = {"redis_written": True, "items_updated": 0}
    classifier_stub.apply_status_override.side_effect = None
    yield


# ---------------------------------------------------------------------------
# GET /v1/integrations/jira/status-classifications
# ---------------------------------------------------------------------------


class TestStatusClassificationsGet:
    def test_returns_items_with_cached_classification(self):
        action_items_db.list_jira_status_pairs.return_value = [
            {"cloudid": "cloud-A", "status_name": "In Review", "matching_item_count": 3},
            {"cloudid": "cloud-A", "status_name": "Blocked", "matching_item_count": 1},
        ]

        def _fake_get(cloudid, status_name):
            if status_name == "In Review":
                return _StubCachedClassification(
                    actionability="waiting",
                    certainty="high",
                    source="llm",
                    status_category="indeterminate",
                )
            return _StubCachedClassification(
                actionability="blocked",
                certainty="medium",
                source="override",
                status_category="indeterminate",
            )

        classifier_stub.get_cached_classification.side_effect = _fake_get
        classifier_stub.derive_bucket.side_effect = lambda c: c.actionability

        resp = _run(integrations_router.jira_status_classifications(uid="uid-1"))
        items = resp.items

        # Sorted by matching_item_count desc.
        assert [i.status_name for i in items] == ["In Review", "Blocked"]
        assert [i.matching_item_count for i in items] == [3, 1]

        in_review = items[0]
        assert in_review.cloudid == "cloud-A"
        assert in_review.bucket == "waiting"
        assert in_review.actionability == "waiting"
        assert in_review.source == "llm"
        assert in_review.certainty == "high"
        assert in_review.status_category == "indeterminate"
        assert in_review.classified_at == "2026-05-17T00:00:00+00:00"

        blocked = items[1]
        assert blocked.bucket == "blocked"
        assert blocked.source == "override"

        action_items_db.list_jira_status_pairs.assert_called_once_with("uid-1")

    def test_uncached_status_emits_null_bucket_and_source(self):
        action_items_db.list_jira_status_pairs.return_value = [
            {"cloudid": "cloud-A", "status_name": "Brand New Status", "matching_item_count": 2},
        ]
        classifier_stub.get_cached_classification.return_value = None  # cache miss

        resp = _run(integrations_router.jira_status_classifications(uid="uid-1"))
        items = resp.items
        assert len(items) == 1
        item = items[0]
        assert item.cloudid == "cloud-A"
        assert item.status_name == "Brand New Status"
        assert item.bucket is None
        assert item.source is None
        assert item.actionability is None
        assert item.status_category is None
        assert item.matching_item_count == 2

    def test_no_jira_items_returns_empty_list(self):
        action_items_db.list_jira_status_pairs.return_value = []
        resp = _run(integrations_router.jira_status_classifications(uid="uid-1"))
        assert resp.items == []

    def test_sort_order_matching_item_count_descending(self):
        # Mix of high/low counts + a cache miss in the middle — sort still
        # holds regardless of cached vs uncached.
        action_items_db.list_jira_status_pairs.return_value = [
            {"cloudid": "c", "status_name": "Low", "matching_item_count": 1},
            {"cloudid": "c", "status_name": "Mid", "matching_item_count": 5},
            {"cloudid": "c", "status_name": "High", "matching_item_count": 12},
        ]
        classifier_stub.get_cached_classification.return_value = None
        resp = _run(integrations_router.jira_status_classifications(uid="uid-1"))
        assert [i.status_name for i in resp.items] == ["High", "Mid", "Low"]


# ---------------------------------------------------------------------------
# POST /v1/integrations/jira/status-classifications/override
# ---------------------------------------------------------------------------


def _make_payload(cloudid="cloud-A", status_name="In Review", bucket="self"):
    payload = _FakeBaseModel(cloudid=cloudid, status_name=status_name, bucket=bucket)
    return payload


class TestStatusClassificationOverridePost:
    @pytest.mark.parametrize("bucket", ["self", "waiting", "blocked", "completed", "dropped"])
    def test_happy_path_each_bucket(self, bucket):
        classifier_stub.apply_status_override.return_value = {"redis_written": True, "items_updated": 7}
        resp = integrations_router.jira_status_classification_override(
            payload=_make_payload(bucket=bucket), uid="uid-1"
        )
        assert resp.redis_written is True
        assert resp.items_updated == 7
        assert resp.bucket == bucket
        classifier_stub.apply_status_override.assert_called_once_with(
            uid="uid-1", cloudid="cloud-A", status_name="In Review", bucket=bucket
        )

    def test_invalid_bucket_returns_400(self):
        with pytest.raises(_FakeHTTPException) as excinfo:
            integrations_router.jira_status_classification_override(
                payload=_make_payload(bucket="not-a-bucket"), uid="uid-1"
            )
        assert excinfo.value.status_code == 400
        assert excinfo.value.detail == "invalid_bucket"
        classifier_stub.apply_status_override.assert_not_called()

    def test_missing_cloudid_returns_400(self):
        with pytest.raises(_FakeHTTPException) as excinfo:
            integrations_router.jira_status_classification_override(payload=_make_payload(cloudid="   "), uid="uid-1")
        assert excinfo.value.status_code == 400
        assert excinfo.value.detail == "cloudid_required"

    def test_missing_status_name_returns_400(self):
        with pytest.raises(_FakeHTTPException) as excinfo:
            integrations_router.jira_status_classification_override(payload=_make_payload(status_name=""), uid="uid-1")
        assert excinfo.value.status_code == 400
        assert excinfo.value.detail == "status_name_required"

    def test_unknown_cloudid_still_completes(self):
        # Classifier returns items_updated=0 when no action items match —
        # the override still gets persisted to Redis and the response
        # reports 0 affected items rather than an error.
        classifier_stub.apply_status_override.return_value = {"redis_written": True, "items_updated": 0}
        resp = integrations_router.jira_status_classification_override(
            payload=_make_payload(cloudid="unknown-cloud", bucket="waiting"), uid="uid-1"
        )
        assert resp.items_updated == 0
        assert resp.bucket == "waiting"
        assert resp.redis_written is True

    def test_classifier_exception_returns_500_with_sanitized_log(self, caplog):
        classifier_stub.apply_status_override.side_effect = RuntimeError("firestore down token=ABCDEFGH12345")
        with caplog.at_level(logging.ERROR, logger=integrations_router.logger.name):
            with pytest.raises(_FakeHTTPException) as excinfo:
                integrations_router.jira_status_classification_override(payload=_make_payload(), uid="uid-1")
        assert excinfo.value.status_code == 500
        assert excinfo.value.detail == "override_failed"
        # UID + bucket visible in logs for support triage.
        assert any("uid=uid-1" in rec.message for rec in caplog.records)


# ---------------------------------------------------------------------------
# Auth wiring — same shape as test_jira_sync_now.TestAuthDependency.
# ---------------------------------------------------------------------------


class TestAuthDependency:
    def test_get_uses_auth_dependency(self):
        import inspect

        sig = inspect.signature(integrations_router.jira_status_classifications)
        params = list(sig.parameters.values())
        assert any(p.name == "uid" for p in params)
        assert sig.parameters["uid"].default is endpoints_mod.get_current_user_uid

    def test_post_uses_auth_dependency(self):
        import inspect

        sig = inspect.signature(integrations_router.jira_status_classification_override)
        params = list(sig.parameters.values())
        assert any(p.name == "uid" for p in params)
        assert sig.parameters["uid"].default is endpoints_mod.get_current_user_uid
