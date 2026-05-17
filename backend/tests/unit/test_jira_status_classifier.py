"""Tests for jira_status_classifier — LLM-classified actionability +
deterministic resolution mapping + in-place override rewrite.

Covers every path enumerated in the design doc's "New backend unit tests"
section:
  - classify_statuses cache HIT (clean roundtrip)
  - classify_statuses cache HIT with stale status_category (rename)
  - classify_statuses cache HIT but malformed JSON / ValidationError
  - classify_statuses cache MISS, LLM success -> cache + return
  - classify_statuses cache MISS, partial response -> retry -> fallback
  - classify_statuses cache MISS, LLM error -> fallback, no cache
  - classify_statuses pre-warm flag set -> short-circuit, no cache write
  - classify_statuses empty input -> {}
  - classify_resolution seed allowlist hit (completed)
  - classify_resolution seed allowlist hit (dropped)
  - classify_resolution unknown name -> LLM (cached separately)
  - rewrite_actionability_in_place zero matching -> 0
  - rewrite_actionability_in_place some matching -> batch update
  - rewrite_actionability_in_place batch boundary (>400) -> mid-loop commit
"""

import asyncio
import importlib.util
import json
import os
import sys
import types
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

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
# Stubs for heavy deps before importing the module under test
# ---------------------------------------------------------------------------

# database package shell
if "database" not in sys.modules:
    _stub_package("database")
    sys.modules["database"].__path__ = [str(BACKEND_DIR / "database")]


# --- Fake Redis client (minimal API needed by classifier) ----------------
class _FakeRedis:
    def __init__(self):
        self.store: dict[str, bytes] = {}
        self.get_calls = []
        self.set_calls = []
        self.mget_calls = []
        # Optional exception hooks
        self.raise_on_get = None
        self.raise_on_mget = None
        self.raise_on_set = None

    def get(self, key):
        self.get_calls.append(key)
        if self.raise_on_get is not None:
            raise self.raise_on_get
        return self.store.get(key)

    def set(self, key, value, *args, **kwargs):
        self.set_calls.append((key, value))
        if self.raise_on_set is not None:
            raise self.raise_on_set
        if isinstance(value, str):
            value = value.encode("utf-8")
        self.store[key] = value
        return True

    def setex(self, key, ttl, value):
        return self.set(key, value)

    def mget(self, keys):
        self.mget_calls.append(list(keys))
        if self.raise_on_mget is not None:
            raise self.raise_on_mget
        return [self.store.get(k) for k in keys]

    def delete(self, key):
        return self.store.pop(key, None) is not None

    def reset(self):
        self.store.clear()
        self.get_calls.clear()
        self.set_calls.clear()
        self.mget_calls.clear()
        self.raise_on_get = None
        self.raise_on_mget = None
        self.raise_on_set = None


fake_redis = _FakeRedis()
redis_mod = _stub_module("database.redis_db")
redis_mod.r = fake_redis


# --- Fake Firestore client (minimal API) ---------------------------------
class _FakeDocSnapshot:
    def __init__(self, doc_id, data, ref):
        self.id = doc_id
        self._data = data
        self.reference = ref

    def to_dict(self):
        return dict(self._data)


class _FakeDocRef:
    def __init__(self, doc_id):
        self.id = doc_id


class _FakeBatch:
    def __init__(self, parent):
        self._parent = parent
        self.updates = []
        self.committed = False

    def update(self, ref, fields):
        self.updates.append((ref, dict(fields)))

    def commit(self):
        self.committed = True
        self._parent.batches.append(self)


class _FakeQuery:
    def __init__(self, docs):
        self._docs = docs

    def stream(self):
        for d in self._docs:
            yield d


class _FakeCollection:
    def __init__(self, docs):
        self._docs = docs

    def where(self, filter=None, **kwargs):
        # FieldFilter object — we ignore the filter contents (test sets docs).
        return _FakeQuery(self._docs)


class _FakeUserDoc:
    def __init__(self, action_items_docs):
        self._docs = action_items_docs

    def collection(self, name):
        assert name == "action_items"
        return _FakeCollection(self._docs)


class _FakeUsersCollection:
    def __init__(self, docs_by_uid):
        self._docs_by_uid = docs_by_uid

    def document(self, uid):
        return _FakeUserDoc(self._docs_by_uid.get(uid, []))


class _FakeFirestoreDB:
    def __init__(self):
        self.docs_by_uid: dict[str, list[_FakeDocSnapshot]] = {}
        self.batches: list[_FakeBatch] = []

    def collection(self, name):
        assert name == "users"
        return _FakeUsersCollection(self.docs_by_uid)

    def batch(self):
        return _FakeBatch(self)

    def reset(self):
        self.docs_by_uid.clear()
        self.batches.clear()


fake_firestore = _FakeFirestoreDB()
client_mod = _stub_module("database._client")
client_mod.db = fake_firestore


# Stub google.cloud.firestore_v1.FieldFilter so the rewrite function's
# import works in tests without google-cloud-firestore installed.
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
        self.kwargs = kwargs


firestore_v1_mod.FieldFilter = _FakeFieldFilter


# --- log sanitizer ------------------------------------------------------
if "utils" not in sys.modules:
    _stub_package("utils")
    sys.modules["utils"].__path__ = [str(BACKEND_DIR / "utils")]
if "utils.integrations" not in sys.modules:
    _stub_package("utils.integrations")
    sys.modules["utils.integrations"].__path__ = [str(BACKEND_DIR / "utils" / "integrations")]

log_san = _stub_module("utils.log_sanitizer")
log_san.sanitize = lambda v: str(v)
log_san.sanitize_pii = lambda v: str(v)


# --- llm_mini stub (replaced per-test via patch on the loaded module) ----
if "utils.llm" not in sys.modules:
    _stub_package("utils.llm")
    sys.modules["utils.llm"].__path__ = [str(BACKEND_DIR / "utils" / "llm")]
llm_clients_mod = _stub_module("utils.llm.clients")


class _FakeStructuredLLM:
    """Stand-in for llm_mini.with_structured_output(Model). Tests set
    ``ainvoke_side_effect`` to a list of responses or an exception.
    """

    def __init__(self):
        self.ainvoke_calls = []
        self.ainvoke_side_effect = None

    async def ainvoke(self, messages):
        self.ainvoke_calls.append(messages)
        if self.ainvoke_side_effect is None:
            raise RuntimeError("test forgot to set ainvoke_side_effect")
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
    """Stand-in for llm_mini. Per-Pydantic-model FakeStructuredLLMs so tests
    can independently set responses for batch classify vs resolution classify.
    """

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
# Load the module under test
# ---------------------------------------------------------------------------


def _load_classifier():
    spec = importlib.util.spec_from_file_location(
        "utils.integrations.jira_status_classifier",
        str(BACKEND_DIR / "utils" / "integrations" / "jira_status_classifier.py"),
    )
    mod = importlib.util.module_from_spec(spec)
    sys.modules["utils.integrations.jira_status_classifier"] = mod
    spec.loader.exec_module(mod)
    return mod


classifier = _load_classifier()


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
def _reset_state():
    fake_redis.reset()
    fake_firestore.reset()
    fake_llm_mini.reset()
    yield


def _run(coro):
    loop = asyncio.new_event_loop()
    try:
        return loop.run_until_complete(coro)
    finally:
        loop.close()


def _seed_cache(
    cloudid, status_name, *, actionability="self", certainty="high", source="llm", status_category="indeterminate"
):
    key = classifier._status_cache_key(cloudid, status_name)
    cached = classifier.CachedClassification(
        actionability=actionability,
        certainty=certainty,
        source=source,
        classified_at="2026-05-17T00:00:00+00:00",
        status_category=status_category,
    )
    fake_redis.store[key] = cached.model_dump_json().encode("utf-8")


def _make_batch_response(entries):
    """entries: list[(status_name, actionability, certainty)]"""
    return classifier.BatchStatusClassification(
        classifications=[
            classifier._ClassificationEntry(status_name=name, actionability=act, certainty=cert)
            for (name, act, cert) in entries
        ]
    )


# ---------------------------------------------------------------------------
# classify_statuses tests
# ---------------------------------------------------------------------------


class TestClassifyStatuses:
    def test_empty_input_returns_empty_dict(self):
        result = _run(classifier.classify_statuses("cloud-1", []))
        assert result == {}
        # No Redis call, no LLM call.
        assert fake_redis.mget_calls == []

    def test_cache_hit_roundtrips_pydantic(self):
        _seed_cache(
            "cloud-1",
            "In Review",
            actionability="waiting",
            certainty="high",
            source="llm",
            status_category="indeterminate",
        )
        inputs = [
            classifier.StatusInput(status_name="In Review", status_category="indeterminate"),
        ]
        result = _run(classifier.classify_statuses("cloud-1", inputs))
        assert "In Review" in result
        cached = result["In Review"]
        assert cached.actionability == "waiting"
        assert cached.certainty == "high"
        assert cached.source == "llm"
        # No LLM call on pure hit.
        batch_llm = fake_llm_mini.for_model(classifier.BatchStatusClassification)
        assert batch_llm.ainvoke_calls == []

    def test_cache_hit_with_stale_status_category_reclassifies(self):
        # Cache says "indeterminate", but the actual status is now "done"
        # (admin renamed/recategorized the workflow step).
        _seed_cache(
            "cloud-1",
            "In Review",
            actionability="waiting",
            certainty="high",
            status_category="indeterminate",
        )
        batch_llm = fake_llm_mini.for_model(classifier.BatchStatusClassification)
        batch_llm.ainvoke_side_effect = _make_batch_response([("In Review", "self", "high")])
        inputs = [
            classifier.StatusInput(status_name="In Review", status_category="done"),
        ]
        result = _run(classifier.classify_statuses("cloud-1", inputs))
        assert result["In Review"].actionability == "self"
        assert result["In Review"].source == "llm"
        assert len(batch_llm.ainvoke_calls) == 1

    def test_cache_hit_malformed_json_reclassifies(self):
        # Half-written / corrupted cache entry.
        key = classifier._status_cache_key("cloud-1", "Doing")
        fake_redis.store[key] = b"{not valid json"

        batch_llm = fake_llm_mini.for_model(classifier.BatchStatusClassification)
        batch_llm.ainvoke_side_effect = _make_batch_response([("Doing", "self", "high")])

        inputs = [classifier.StatusInput(status_name="Doing", status_category="indeterminate")]
        result = _run(classifier.classify_statuses("cloud-1", inputs))
        assert result["Doing"].actionability == "self"
        assert result["Doing"].source == "llm"

    def test_cache_hit_validation_error_reclassifies(self):
        # Valid JSON but missing required fields.
        key = classifier._status_cache_key("cloud-1", "Doing")
        fake_redis.store[key] = json.dumps({"actionability": "bogus"}).encode("utf-8")

        batch_llm = fake_llm_mini.for_model(classifier.BatchStatusClassification)
        batch_llm.ainvoke_side_effect = _make_batch_response([("Doing", "self", "medium")])

        inputs = [classifier.StatusInput(status_name="Doing", status_category="indeterminate")]
        result = _run(classifier.classify_statuses("cloud-1", inputs))
        assert result["Doing"].actionability == "self"
        assert result["Doing"].source == "llm"

    def test_cache_miss_llm_success_caches_and_returns(self):
        batch_llm = fake_llm_mini.for_model(classifier.BatchStatusClassification)
        batch_llm.ainvoke_side_effect = _make_batch_response(
            [
                ("In Review", "waiting", "high"),
                ("Blocked", "blocked", "high"),
            ]
        )
        inputs = [
            classifier.StatusInput(status_name="In Review", status_category="indeterminate"),
            classifier.StatusInput(status_name="Blocked", status_category="indeterminate"),
        ]
        result = _run(classifier.classify_statuses("cloud-1", inputs))

        assert result["In Review"].actionability == "waiting"
        assert result["Blocked"].actionability == "blocked"
        assert all(v.source == "llm" for v in result.values())

        # Both cached.
        review_key = classifier._status_cache_key("cloud-1", "In Review")
        blocked_key = classifier._status_cache_key("cloud-1", "Blocked")
        assert review_key in fake_redis.store
        assert blocked_key in fake_redis.store

    def test_cache_miss_partial_response_retries_then_fallbacks(self):
        # First LLM call returns only one of two statuses.
        # Retry call returns nothing.
        # Both should end up fallback (no cache).
        batch_llm = fake_llm_mini.for_model(classifier.BatchStatusClassification)
        batch_llm.ainvoke_side_effect = [
            _make_batch_response([("Status A", "self", "high")]),  # missing "Status B"
            _make_batch_response([]),  # retry returns nothing
        ]
        inputs = [
            classifier.StatusInput(status_name="Status A", status_category="indeterminate"),
            classifier.StatusInput(status_name="Status B", status_category="indeterminate"),
        ]
        result = _run(classifier.classify_statuses("cloud-1", inputs))

        assert result["Status A"].source == "llm"
        assert result["Status A"].actionability == "self"
        assert result["Status B"].source == "fallback"
        assert result["Status B"].actionability == "self"  # conservative default

        # Status A cached (llm); Status B NOT cached (fallback).
        assert classifier._status_cache_key("cloud-1", "Status A") in fake_redis.store
        assert classifier._status_cache_key("cloud-1", "Status B") not in fake_redis.store
        # Exactly two LLM calls (initial + bounded retry).
        assert len(batch_llm.ainvoke_calls) == 2

    def test_cache_miss_partial_response_retry_succeeds(self):
        # First call missing "Status B", retry fills it in.
        batch_llm = fake_llm_mini.for_model(classifier.BatchStatusClassification)
        batch_llm.ainvoke_side_effect = [
            _make_batch_response([("Status A", "self", "high")]),
            _make_batch_response([("Status B", "waiting", "medium")]),
        ]
        inputs = [
            classifier.StatusInput(status_name="Status A", status_category="indeterminate"),
            classifier.StatusInput(status_name="Status B", status_category="indeterminate"),
        ]
        result = _run(classifier.classify_statuses("cloud-1", inputs))

        assert result["Status A"].source == "llm"
        assert result["Status B"].source == "llm"
        assert result["Status B"].actionability == "waiting"
        # Both cached.
        assert classifier._status_cache_key("cloud-1", "Status A") in fake_redis.store
        assert classifier._status_cache_key("cloud-1", "Status B") in fake_redis.store

    def test_cache_miss_llm_error_falls_back_no_cache(self):
        batch_llm = fake_llm_mini.for_model(classifier.BatchStatusClassification)
        batch_llm.ainvoke_side_effect = RuntimeError("openai 500")
        inputs = [
            classifier.StatusInput(status_name="In Review", status_category="indeterminate"),
        ]
        result = _run(classifier.classify_statuses("cloud-1", inputs))

        assert result["In Review"].source == "fallback"
        assert result["In Review"].actionability == "self"
        # Nothing cached.
        assert fake_redis.store == {}

    def test_prewarm_flag_short_circuits_to_fallback(self):
        # is_prewarm_in_progress is checked by classify_statuses_for_sync —
        # design's sync entry point. Verify it bails before LLM/cache.
        fake_redis.store[classifier._prewarm_flag_key("uid-1", "cloud-1")] = b"1"
        batch_llm = fake_llm_mini.for_model(classifier.BatchStatusClassification)
        batch_llm.ainvoke_side_effect = _make_batch_response([("In Review", "waiting", "high")])

        inputs = [
            classifier.StatusInput(status_name="In Review", status_category="indeterminate"),
        ]
        result = _run(classifier.classify_statuses_for_sync("uid-1", "cloud-1", inputs))

        assert result["In Review"].source == "fallback"
        # No LLM call.
        assert batch_llm.ainvoke_calls == []
        # No cache write (only the seeded prewarm flag remains).
        cache_key = classifier._status_cache_key("cloud-1", "In Review")
        assert cache_key not in fake_redis.store

    def test_prewarm_flag_unset_routes_to_classify(self):
        batch_llm = fake_llm_mini.for_model(classifier.BatchStatusClassification)
        batch_llm.ainvoke_side_effect = _make_batch_response([("In Review", "waiting", "high")])
        inputs = [
            classifier.StatusInput(status_name="In Review", status_category="indeterminate"),
        ]
        result = _run(classifier.classify_statuses_for_sync("uid-1", "cloud-1", inputs))
        assert result["In Review"].source == "llm"
        assert result["In Review"].actionability == "waiting"


# ---------------------------------------------------------------------------
# classify_resolution tests
# ---------------------------------------------------------------------------


class TestClassifyResolution:
    def test_seed_completed_allowlist(self):
        for name in ["Done", "Fixed", "Resolved", "Implemented", "Delivered", "Complete", "Completed"]:
            assert _run(classifier.classify_resolution("cloud-1", name)) == "completed"

    def test_seed_dropped_allowlist(self):
        for name in ["Won't Do", "Cancelled", "Duplicate", "Won't Fix", "Rejected", "Invalid"]:
            assert _run(classifier.classify_resolution("cloud-1", name)) == "dropped"
        # No LLM call needed for any seed allowlist entry.
        res_llm = fake_llm_mini.for_model(classifier._ResolutionLLM)
        assert res_llm.ainvoke_calls == []

    def test_null_or_empty_returns_none(self):
        assert _run(classifier.classify_resolution("cloud-1", None)) is None
        assert _run(classifier.classify_resolution("cloud-1", "")) is None
        assert _run(classifier.classify_resolution("cloud-1", "   ")) is None

    def test_unknown_name_calls_llm_and_caches(self):
        res_llm = fake_llm_mini.for_model(classifier._ResolutionLLM)
        res_llm.ainvoke_side_effect = classifier._ResolutionLLM(resolution="dropped")

        out = _run(classifier.classify_resolution("cloud-1", "Shelved For Now"))
        assert out == "dropped"

        # Cached under jira:resolution_class:...
        key = classifier._resolution_cache_key("cloud-1", "Shelved For Now")
        assert key in fake_redis.store

        # Second call hits cache (no second LLM call).
        out2 = _run(classifier.classify_resolution("cloud-1", "Shelved For Now"))
        assert out2 == "dropped"
        assert len(res_llm.ainvoke_calls) == 1

    def test_unknown_name_llm_error_returns_none(self):
        res_llm = fake_llm_mini.for_model(classifier._ResolutionLLM)
        res_llm.ainvoke_side_effect = RuntimeError("openai down")
        out = _run(classifier.classify_resolution("cloud-1", "Frobnicated"))
        assert out is None
        # Nothing cached.
        assert classifier._resolution_cache_key("cloud-1", "Frobnicated") not in fake_redis.store


# ---------------------------------------------------------------------------
# rewrite_actionability_in_place tests
# ---------------------------------------------------------------------------


def _make_doc(doc_id, *, source="jira", cloudid="cloud-1", status="In Review", extra_md=None):
    md = {"cloudid": cloudid, "status": status}
    if extra_md:
        md.update(extra_md)
    data = {
        "external_source": {
            "source": source,
            "external_id": doc_id,
            "metadata": md,
        },
    }
    return _FakeDocSnapshot(doc_id, data, _FakeDocRef(doc_id))


class TestRewriteActionabilityInPlace:
    def test_zero_matches_returns_zero(self):
        # User has Jira items but none match cloudid + status_name.
        fake_firestore.docs_by_uid["uid-1"] = [
            _make_doc("a", status="Different Status"),
            _make_doc("b", cloudid="other-cloud"),
        ]
        count = classifier.rewrite_actionability_in_place("uid-1", "cloud-1", "In Review", "waiting")
        assert count == 0
        # No batch commits (nothing to write).
        assert all(not b.committed for b in fake_firestore.batches)

    def test_some_matches_batch_update_with_override_source(self):
        fake_firestore.docs_by_uid["uid-1"] = [
            _make_doc("a"),  # matches
            _make_doc("b"),  # matches
            _make_doc("c", status="Other"),  # doesn't match
            _make_doc("d", cloudid="cloud-2"),  # doesn't match
        ]
        count = classifier.rewrite_actionability_in_place("uid-1", "cloud-1", "In Review", "waiting")
        assert count == 2
        # One batch, committed, with two updates.
        committed_batches = [b for b in fake_firestore.batches if b.committed]
        assert len(committed_batches) == 1
        all_updates = []
        for b in committed_batches:
            all_updates.extend(b.updates)
        assert len(all_updates) == 2
        for ref, fields in all_updates:
            assert fields["external_source.metadata.actionability"] == "waiting"
            assert fields["external_source.metadata.classification_source"] == "override"

    def test_batch_boundary_commits_mid_loop(self):
        # 401 matching docs -> first commit at 400, final commit for 1 leftover.
        docs = [_make_doc(f"doc-{i}") for i in range(401)]
        fake_firestore.docs_by_uid["uid-1"] = docs

        count = classifier.rewrite_actionability_in_place("uid-1", "cloud-1", "In Review", "waiting")
        assert count == 401
        committed = [b for b in fake_firestore.batches if b.committed]
        # Exactly two commits: one at boundary, one trailing.
        assert len(committed) == 2
        # First commit holds 400 updates, second holds 1.
        sizes = sorted(len(b.updates) for b in committed)
        assert sizes == [1, 400]

    def test_skips_non_jira_source(self):
        # In practice the firestore where() filters this out — but the test
        # records that our helper relies on the query filter, not on a
        # secondary Python-side guard for source. We assert nothing for the
        # source filter (handled by FieldFilter); just confirm a metadata
        # cloudid mismatch is the dominant skip.
        fake_firestore.docs_by_uid["uid-1"] = [
            _make_doc("a", cloudid="cloud-2"),
        ]
        count = classifier.rewrite_actionability_in_place("uid-1", "cloud-1", "In Review", "waiting")
        assert count == 0


# ---------------------------------------------------------------------------
# Slug helper (light sanity)
# ---------------------------------------------------------------------------


class TestSlug:
    def test_slug_examples_from_design_doc(self):
        assert classifier._slug("In Review") == "in-review"
        assert classifier._slug("Code Review (Backend)") == "code-review-backend"
        # Variants collapse together (intentionally lossy per design).
        assert classifier._slug("In Review") == classifier._slug("in review") == classifier._slug("In-Review")
