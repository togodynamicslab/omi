"""Unit tests for the sender resolution batch helper + 60s LRU cache.

Lives in ``utils/inbox_senders.py`` so it can be unit-tested without dragging
in the full ``utils/apps.py`` surface (Redis, Firebase, Stripe).

Verifies:
- distinct app_ids are deduped before the apps-registry round trip
- a single batch lookup is used for N messages with K distinct app_ids
- cached entries are reused across calls within the TTL
- null app names fall back to "App"
- duplicate / falsy app_ids are filtered safely
- brief_sender_dict is the static "Brief" entry
"""

import os
import sys
import types
from unittest.mock import MagicMock

os.environ.setdefault(
    "ENCRYPTION_SECRET",
    "omi_ZwB2ZNqB2HHpMK6wStk7sTpavJiPTFg7gXUHnc4tFABPU6pZ2c2DKgehtfgi4RZv",
)

# Stub firestore client + firebase_admin so database.apps imports cleanly
# without hitting real Firestore / ADC.
mock_client_module = types.ModuleType("database._client")
mock_client_module.db = MagicMock()
mock_client_module.get_prod_db = MagicMock()
sys.modules["database._client"] = mock_client_module

firebase_admin = types.ModuleType("firebase_admin")
firebase_admin.auth = MagicMock()
firebase_admin.messaging = MagicMock()
sys.modules["firebase_admin"] = firebase_admin
sys.modules["firebase_admin.auth"] = firebase_admin.auth
sys.modules["firebase_admin.messaging"] = firebase_admin.messaging

# database.redis_db is pulled in by database.apps (for get_app_reviews). Stub it.
redis_db_mod = types.ModuleType("database.redis_db")
redis_db_mod.get_app_reviews = MagicMock(return_value={})
sys.modules["database.redis_db"] = redis_db_mod

# ulid + google.cloud.firestore + models — stub anything imported at top of database.apps.
ulid_mod = types.ModuleType("ulid")
ulid_mod.ULID = MagicMock()
sys.modules["ulid"] = ulid_mod

import pytest

import utils.inbox_senders as inbox_senders


@pytest.fixture(autouse=True)
def _clear_cache():
    inbox_senders.cache_clear()
    yield
    inbox_senders.cache_clear()


def test_single_batch_lookup_for_n_messages_with_k_distinct(monkeypatch):
    # Page of 10 messages with K=3 distinct app_ids.
    page_app_ids = ['a', 'b', 'a', 'c', 'b', 'a', 'c', 'b', 'a', 'c']
    fetch_calls = []

    def _fake_batch(ids):
        fetch_calls.append(list(ids))
        return [
            {'id': 'a', 'name': 'AppA', 'image': 'img-a'},
            {'id': 'b', 'name': 'AppB', 'image': 'img-b'},
            {'id': 'c', 'name': 'AppC', 'image': 'img-c'},
        ]

    monkeypatch.setattr(inbox_senders, "get_apps_by_ids_db", _fake_batch)

    resolved = inbox_senders.resolve_senders_for_app_ids(page_app_ids)

    assert len(fetch_calls) == 1
    # Distinct ids passed to the batch — exactly the unique set.
    assert sorted(fetch_calls[0]) == ['a', 'b', 'c']
    assert resolved['a'] == {'display_name': 'AppA', 'avatar_url': 'img-a'}
    assert resolved['b'] == {'display_name': 'AppB', 'avatar_url': 'img-b'}
    assert resolved['c'] == {'display_name': 'AppC', 'avatar_url': 'img-c'}


def test_cache_hit_within_ttl(monkeypatch):
    fetch_calls = []

    def _fake_batch(ids):
        fetch_calls.append(list(ids))
        return [{'id': 'a', 'name': 'AppA', 'image': None}]

    monkeypatch.setattr(inbox_senders, "get_apps_by_ids_db", _fake_batch)

    inbox_senders.resolve_senders_for_app_ids(['a'])
    assert len(fetch_calls) == 1

    # Second call within TTL — served from cache, no extra round trip.
    inbox_senders.resolve_senders_for_app_ids(['a'])
    assert len(fetch_calls) == 1


def test_partial_cache_hit_only_fetches_misses(monkeypatch):
    fetch_calls = []

    def _fake_batch(ids):
        fetch_calls.append(sorted(ids))
        return [{'id': i, 'name': i.upper(), 'image': None} for i in ids]

    monkeypatch.setattr(inbox_senders, "get_apps_by_ids_db", _fake_batch)

    inbox_senders.resolve_senders_for_app_ids(['a'])
    assert fetch_calls == [['a']]

    inbox_senders.resolve_senders_for_app_ids(['a', 'b'])
    # second call — only 'b' is fetched
    assert fetch_calls == [['a'], ['b']]


def test_null_name_falls_back_to_app_label(monkeypatch):
    monkeypatch.setattr(inbox_senders, "get_apps_by_ids_db", lambda ids: [{'id': 'x', 'name': None, 'image': None}])
    out = inbox_senders.resolve_senders_for_app_ids(['x'])
    assert out['x'] == {'display_name': 'App', 'avatar_url': None}


def test_missing_app_doc_falls_back_to_app_label(monkeypatch):
    # Registry returns nothing — caller still gets an entry with the fallback.
    monkeypatch.setattr(inbox_senders, "get_apps_by_ids_db", lambda ids: [])
    out = inbox_senders.resolve_senders_for_app_ids(['ghost'])
    assert out['ghost'] == {'display_name': 'App', 'avatar_url': None}


def test_filters_falsy_and_non_string_inputs(monkeypatch):
    fetch_calls = []
    monkeypatch.setattr(inbox_senders, "get_apps_by_ids_db", lambda ids: (fetch_calls.append(list(ids)) or []))

    out = inbox_senders.resolve_senders_for_app_ids([None, '', 0, 'real-app'])

    assert fetch_calls == [['real-app']]
    assert 'real-app' in out
    assert None not in out
    assert '' not in out


def test_brief_sender_dict_is_constant():
    assert inbox_senders.brief_sender_dict() == {'display_name': 'Brief', 'avatar_url': None}
