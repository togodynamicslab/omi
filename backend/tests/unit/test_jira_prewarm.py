"""Tests for jira_prewarm — post-OAuth workflow status pre-warm task.

Covers the contract in the design doc Day 3 spec:
  - sets prewarm-in-progress flag before fetching
  - clears the flag in finally{} on success AND on error
  - happy path: fetches statuses, calls classifier, returns shape
  - HTTP timeout / network error -> errors=1, flag still cleared
  - empty statuses payload -> skipped=True
  - dedup of duplicate status names in plugin response
"""

import asyncio
import importlib.util
import os
import sys
import types
from pathlib import Path

import httpx
import pytest

BACKEND_DIR = Path(__file__).resolve().parent.parent.parent

os.environ.setdefault(
    "ENCRYPTION_SECRET",
    "omi_ZwB2ZNqB2HHpMK6wStk7sTpavJiPTFg7gXUHnc4tFABPU6pZ2c2DKgehtfgi4RZv",
)


# ---------------------------------------------------------------------------
# Stub the same lower-level modules the classifier tests stub. We reuse the
# Fake Redis + Fake LLM fixtures so the classifier under test runs against an
# in-process Redis double, no fakeredis dep needed.
# ---------------------------------------------------------------------------


def _stub_module(name):
    mod = types.ModuleType(name)
    sys.modules[name] = mod
    return mod


def _stub_package(name):
    mod = types.ModuleType(name)
    mod.__path__ = []
    sys.modules[name] = mod
    return mod


if "database" not in sys.modules:
    _stub_package("database")
    sys.modules["database"].__path__ = [str(BACKEND_DIR / "database")]


class _FakeRedis:
    def __init__(self):
        self.store: dict[str, bytes] = {}
        self.setex_calls = []
        self.delete_calls = []
        self.raise_on_setex = None
        self.raise_on_delete = None

    def get(self, key):
        return self.store.get(key)

    def set(self, key, value, *args, **kwargs):
        if isinstance(value, str):
            value = value.encode("utf-8")
        self.store[key] = value
        return True

    def setex(self, key, ttl, value):
        self.setex_calls.append((key, ttl, value))
        if self.raise_on_setex is not None:
            raise self.raise_on_setex
        return self.set(key, value)

    def mget(self, keys):
        return [self.store.get(k) for k in keys]

    def delete(self, key):
        self.delete_calls.append(key)
        if self.raise_on_delete is not None:
            raise self.raise_on_delete
        return self.store.pop(key, None) is not None

    def scan_iter(self, pattern, count=100):
        # Minimal glob match against the keys for the SCAN-style helpers.
        prefix = pattern.rstrip("*")
        for k in list(self.store.keys()):
            if k.startswith(prefix):
                yield k

    def reset(self):
        self.store.clear()
        self.setex_calls.clear()
        self.delete_calls.clear()
        self.raise_on_setex = None
        self.raise_on_delete = None


fake_redis = _FakeRedis()
redis_mod = _stub_module("database.redis_db")
redis_mod.r = fake_redis


# Firestore stub (only needed because classifier imports it at module load).
class _FakeFirestoreDB:
    def collection(self, name):
        raise AssertionError("prewarm should not touch Firestore")

    def batch(self):
        raise AssertionError("prewarm should not touch Firestore")


client_mod = _stub_module("database._client")
client_mod.db = _FakeFirestoreDB()

if "google" not in sys.modules:
    _stub_package("google")
if "google.cloud" not in sys.modules:
    _stub_package("google.cloud")
if "google.cloud.firestore_v1" not in sys.modules:
    _stub_module("google.cloud.firestore_v1")
firestore_v1_mod = sys.modules["google.cloud.firestore_v1"]


class _FakeFieldFilter:
    def __init__(self, *args, **kwargs):
        self.args = args


firestore_v1_mod.FieldFilter = _FakeFieldFilter


# log_sanitizer stub
if "utils" not in sys.modules:
    _stub_package("utils")
    sys.modules["utils"].__path__ = [str(BACKEND_DIR / "utils")]
if "utils.integrations" not in sys.modules:
    _stub_package("utils.integrations")
    sys.modules["utils.integrations"].__path__ = [str(BACKEND_DIR / "utils" / "integrations")]

log_san = _stub_module("utils.log_sanitizer")
log_san.sanitize = lambda v: str(v)
log_san.sanitize_pii = lambda v: str(v)


# llm_mini stub (mirrors the pattern from test_jira_status_classifier).
if "utils.llm" not in sys.modules:
    _stub_package("utils.llm")
    sys.modules["utils.llm"].__path__ = [str(BACKEND_DIR / "utils" / "llm")]
llm_clients_mod = _stub_module("utils.llm.clients")


class _FakeStructuredLLM:
    def __init__(self):
        self.ainvoke_calls = []
        self.ainvoke_side_effect = None

    async def ainvoke(self, messages):
        self.ainvoke_calls.append(messages)
        side = self.ainvoke_side_effect
        if isinstance(side, list):
            if not side:
                raise RuntimeError("ainvoke_side_effect list exhausted")
            value = side.pop(0)
        else:
            value = side
        if isinstance(value, Exception):
            raise value
        return value


class _FakeLLMMini:
    def __init__(self):
        self.structured_by_model: dict = {}

    def for_model(self, model_cls) -> _FakeStructuredLLM:
        if model_cls not in self.structured_by_model:
            self.structured_by_model[model_cls] = _FakeStructuredLLM()
        return self.structured_by_model[model_cls]

    def with_structured_output(self, model_cls):
        return self.for_model(model_cls)

    def reset(self):
        self.structured_by_model.clear()


fake_llm_mini = _FakeLLMMini()
llm_clients_mod.llm_mini = fake_llm_mini


# ---------------------------------------------------------------------------
# Load the modules under test
# ---------------------------------------------------------------------------


def _load(name, relpath):
    spec = importlib.util.spec_from_file_location(name, str(BACKEND_DIR / relpath))
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


classifier = _load(
    "utils.integrations.jira_status_classifier",
    "utils/integrations/jira_status_classifier.py",
)
prewarm = _load(
    "utils.integrations.jira_prewarm",
    "utils/integrations/jira_prewarm.py",
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
def _reset_state():
    fake_redis.reset()
    fake_llm_mini.reset()
    yield


def _run(coro):
    loop = asyncio.new_event_loop()
    try:
        return loop.run_until_complete(coro)
    finally:
        loop.close()


class _StubAsyncClient:
    """Minimal async-context-manager substitute for httpx.AsyncClient.

    Tests pass an instance of this directly to ``prewarm_user_workflow_classifications``
    via the ``http_client`` kwarg so we don't need the real httpx network stack.
    """

    def __init__(self, *, response=None, raise_on_get=None):
        self._response = response
        self._raise = raise_on_get
        self.get_calls = []

    async def get(self, url, params=None):
        self.get_calls.append((url, params))
        if self._raise is not None:
            raise self._raise
        return self._response

    async def aclose(self):
        pass


class _StubResponse:
    def __init__(self, status_code, json_body=None, text=""):
        self.status_code = status_code
        self._json = json_body or {}
        self.text = text

    def json(self):
        return self._json


def _batch_response(entries):
    return classifier.BatchStatusClassification(
        classifications=[
            classifier._ClassificationEntry(status_name=name, actionability=act, certainty=cert)
            for (name, act, cert) in entries
        ]
    )


# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------


class TestPrewarmHappyPath:
    def test_classifies_and_returns_count_and_clears_flag(self):
        # Plugin response: 3 distinct + 1 duplicate status name.
        body = {
            "statuses": [
                {"status_name": "To Do", "status_category": "new"},
                {"status_name": "In Progress", "status_category": "indeterminate"},
                {"status_name": "In Review", "status_category": "indeterminate"},
                {"status_name": "In Review", "status_category": "indeterminate"},  # dup
            ]
        }
        client = _StubAsyncClient(response=_StubResponse(200, body))

        batch_llm = fake_llm_mini.for_model(classifier.BatchStatusClassification)
        batch_llm.ainvoke_side_effect = _batch_response(
            [
                ("To Do", "self", "high"),
                ("In Progress", "self", "high"),
                ("In Review", "waiting", "high"),
            ]
        )

        result = _run(
            prewarm.prewarm_user_workflow_classifications(
                uid="uid-1",
                cloudid="cloud-1",
                plugin_base_url="http://plugin",
                http_client=client,
            )
        )

        assert result == {"classified": 3, "errors": 0, "skipped": False}
        # All three statuses are now cached.
        for name in ("To Do", "In Progress", "In Review"):
            assert classifier._status_cache_key("cloud-1", name) in fake_redis.store
        # Pre-warm flag set then cleared.
        flag_key = classifier._prewarm_flag_key("uid-1", "cloud-1")
        assert any(c[0] == flag_key for c in fake_redis.setex_calls)
        assert flag_key in fake_redis.delete_calls
        # Plugin endpoint called with the expected URL + uid query.
        assert client.get_calls == [("http://plugin/v1/internal/workflow-statuses", {"uid": "uid-1"})]

    def test_invalid_status_category_coerced_to_indeterminate(self):
        body = {"statuses": [{"status_name": "Custom", "status_category": "WEIRD"}]}
        client = _StubAsyncClient(response=_StubResponse(200, body))
        batch_llm = fake_llm_mini.for_model(classifier.BatchStatusClassification)
        batch_llm.ainvoke_side_effect = _batch_response([("Custom", "self", "low")])

        result = _run(
            prewarm.prewarm_user_workflow_classifications(
                uid="uid-1", cloudid="cloud-1", plugin_base_url="http://plugin", http_client=client
            )
        )
        assert result["classified"] == 1
        cached_raw = fake_redis.store[classifier._status_cache_key("cloud-1", "Custom")]
        assert b'"status_category":"indeterminate"' in cached_raw


# ---------------------------------------------------------------------------
# Empty / skip paths
# ---------------------------------------------------------------------------


class TestPrewarmSkipPaths:
    def test_empty_statuses_returns_skipped(self):
        client = _StubAsyncClient(response=_StubResponse(200, {"statuses": []}))
        result = _run(
            prewarm.prewarm_user_workflow_classifications(
                uid="uid-1", cloudid="cloud-1", plugin_base_url="http://plugin", http_client=client
            )
        )
        # Empty list from plugin counts as errors=1 (something is off — either
        # not connected or no workflows) + skipped=True.
        assert result == {"classified": 0, "errors": 1, "skipped": True}
        # Flag still cleared.
        assert classifier._prewarm_flag_key("uid-1", "cloud-1") in fake_redis.delete_calls

    def test_only_blank_names_yields_zero_inputs_and_skips(self):
        body = {"statuses": [{"status_name": "  ", "status_category": "new"}]}
        client = _StubAsyncClient(response=_StubResponse(200, body))
        result = _run(
            prewarm.prewarm_user_workflow_classifications(
                uid="uid-1", cloudid="cloud-1", plugin_base_url="http://plugin", http_client=client
            )
        )
        assert result == {"classified": 0, "errors": 0, "skipped": True}
        assert classifier._prewarm_flag_key("uid-1", "cloud-1") in fake_redis.delete_calls


# ---------------------------------------------------------------------------
# Error / flag-cleared invariant
# ---------------------------------------------------------------------------


class TestPrewarmErrorPaths:
    def test_http_timeout_returns_errors_one_and_clears_flag(self):
        client = _StubAsyncClient(raise_on_get=httpx.ReadTimeout("timeout"))
        result = _run(
            prewarm.prewarm_user_workflow_classifications(
                uid="uid-1", cloudid="cloud-1", plugin_base_url="http://plugin", http_client=client
            )
        )
        assert result == {"classified": 0, "errors": 1, "skipped": True}
        # Flag was set and then cleared even though the fetch threw.
        flag_key = classifier._prewarm_flag_key("uid-1", "cloud-1")
        assert any(c[0] == flag_key for c in fake_redis.setex_calls)
        assert flag_key in fake_redis.delete_calls

    def test_plugin_non_200_returns_errors_one_and_clears_flag(self):
        client = _StubAsyncClient(response=_StubResponse(502, {}, text="bad gateway"))
        result = _run(
            prewarm.prewarm_user_workflow_classifications(
                uid="uid-1", cloudid="cloud-1", plugin_base_url="http://plugin", http_client=client
            )
        )
        assert result == {"classified": 0, "errors": 1, "skipped": True}
        assert classifier._prewarm_flag_key("uid-1", "cloud-1") in fake_redis.delete_calls

    def test_llm_exception_returns_errors_and_clears_flag(self):
        body = {"statuses": [{"status_name": "To Do", "status_category": "new"}]}
        client = _StubAsyncClient(response=_StubResponse(200, body))
        batch_llm = fake_llm_mini.for_model(classifier.BatchStatusClassification)
        # Both initial and retry must fail so the classifier returns fallback.
        batch_llm.ainvoke_side_effect = [RuntimeError("openai down")]

        result = _run(
            prewarm.prewarm_user_workflow_classifications(
                uid="uid-1", cloudid="cloud-1", plugin_base_url="http://plugin", http_client=client
            )
        )
        # classifier returned fallback for the one input -> classified=0, errors=1.
        assert result["classified"] == 0
        assert result["errors"] == 1
        assert result["skipped"] is False
        assert classifier._prewarm_flag_key("uid-1", "cloud-1") in fake_redis.delete_calls
        # Nothing cached (fallback never writes).
        assert classifier._status_cache_key("cloud-1", "To Do") not in fake_redis.store

    def test_flag_set_failure_short_circuits_with_errors(self):
        fake_redis.raise_on_setex = RuntimeError("redis down")
        client = _StubAsyncClient(response=_StubResponse(200, {"statuses": []}))
        result = _run(
            prewarm.prewarm_user_workflow_classifications(
                uid="uid-1", cloudid="cloud-1", plugin_base_url="http://plugin", http_client=client
            )
        )
        assert result == {"classified": 0, "errors": 1, "skipped": False}
        # Flag was never set successfully, so the plugin endpoint was not called.
        assert client.get_calls == []


# ---------------------------------------------------------------------------
# Cron consumer: run_pending_prewarms_all_users
# ---------------------------------------------------------------------------


class TestRunPendingPrewarmsAllUsers:
    def test_no_pending_returns_zero(self):
        result = _run(prewarm.run_pending_prewarms_all_users("http://plugin"))
        assert result == {"users": 0, "prewarmed": 0}

    def test_pending_flag_triggers_prewarm_and_clears(self):
        # Seed a pending flag for one (uid, cloudid).
        fake_redis.store["jira:prewarm_pending:uid-1:cloud-1"] = b"1"

        body = {"statuses": [{"status_name": "Open", "status_category": "new"}]}
        client = _StubAsyncClient(response=_StubResponse(200, body))
        batch_llm = fake_llm_mini.for_model(classifier.BatchStatusClassification)
        batch_llm.ainvoke_side_effect = _batch_response([("Open", "self", "high")])

        result = _run(prewarm.run_pending_prewarms_all_users("http://plugin", http_client=client))
        assert result == {"users": 1, "prewarmed": 1}
        # Pending flag is gone.
        assert "jira:prewarm_pending:uid-1:cloud-1" not in fake_redis.store
        # Pre-warm in-flight flag was cleared too.
        assert classifier._prewarm_flag_key("uid-1", "cloud-1") not in fake_redis.store
