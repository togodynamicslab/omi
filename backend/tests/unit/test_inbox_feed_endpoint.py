"""Unit tests for the GET /v2/chat/inbox/feed handler logic.

These tests exercise the route handler as a plain Python function (no
FastAPI TestClient) because the test venv ships without fastapi/firebase.
The handler is pure modulo I/O — DB calls and the apps registry are
monkey-patched.

Covers:
- Empty user → empty items list
- day_summary-only user
- apps-only user
- mixed feed sorted by created_at desc
- pagination via `before` cursor
- sender resolution fallback ("App") when apps registry returns null name
- encryption parity — message text is decrypted by the prepare_for_read decorator
- bad cursor → 400 (HTTPException raised)
"""

import os
import sys
import types
from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock

os.environ.setdefault(
    "ENCRYPTION_SECRET",
    "omi_ZwB2ZNqB2HHpMK6wStk7sTpavJiPTFg7gXUHnc4tFABPU6pZ2c2DKgehtfgi4RZv",
)

# --- Stubs for heavy / external deps (firebase_admin, fastapi-shaped imports) ---


def _stub_module(name):
    mod = types.ModuleType(name)
    sys.modules[name] = mod
    return mod


# Stub firestore client (used at import time by database.chat / database.apps).
mock_client_module = _stub_module("database._client")
mock_client_module.db = MagicMock()
mock_client_module.get_prod_db = MagicMock()
mock_client_module.document_id_from_seed = MagicMock(return_value='seeded-id')

# firebase_admin family.
firebase_admin = _stub_module("firebase_admin")
firebase_admin.auth = MagicMock()
firebase_admin.messaging = MagicMock()
sys.modules["firebase_admin.auth"] = firebase_admin.auth
sys.modules["firebase_admin.messaging"] = firebase_admin.messaging

import pytest

# Importing routers.chat / database.chat pulls in fastapi + database._client
# helpers that aren't shipped by the minimal CI venv. Skip the whole module
# when those aren't available; CI environments with the full requirements
# installed will execute these tests normally.
try:
    import database.chat as chat_db
    import utils.inbox_senders as inbox_senders
    from routers.chat import get_inbox_feed
    from fastapi import HTTPException
except (ModuleNotFoundError, ImportError):
    pytest.skip(
        "fastapi / firebase / full backend deps not available in test venv",
        allow_module_level=True,
    )


@pytest.fixture(autouse=True)
def _reset_sender_cache():
    inbox_senders.cache_clear()
    yield
    inbox_senders.cache_clear()


def _msg(msg_id, text, created_at, **kw):
    base = {
        'id': msg_id,
        'text': text,
        'created_at': created_at,
        'sender': 'ai',
        'type': 'text',
        'from_external_integration': False,
    }
    base.update(kw)
    return base


def _call(limit=50, before=None):
    return get_inbox_feed(limit=limit, before=before, uid="test-user")


def test_empty_feed(monkeypatch):
    monkeypatch.setattr(chat_db, "get_inbox_messages", lambda uid, limit, before: [])
    body = _call()
    assert body == {'items': [], 'next_cursor': None}


def test_day_summary_only_user(monkeypatch):
    now = datetime(2026, 5, 6, 12, 0, tzinfo=timezone.utc)
    rows = [_msg('m1', 'Your daily brief', now, type='day_summary', from_external_integration=False)]
    monkeypatch.setattr(chat_db, "get_inbox_messages", lambda uid, limit, before: rows)

    body = _call()
    assert len(body['items']) == 1
    item = body['items'][0]
    assert item['id'] == 'm1'
    assert item['type'] == 'day_summary'
    assert item['app_id'] is None
    assert item['sender'] == {'display_name': 'Brief', 'avatar_url': None, 'type': 'brief'}
    assert item['text'] == 'Your daily brief'


def test_apps_only_user_resolves_sender(monkeypatch):
    now = datetime(2026, 5, 6, 12, 0, tzinfo=timezone.utc)
    rows = [
        _msg('m1', 'Hi from Linear', now, app_id='linear', plugin_id='linear', from_external_integration=True),
        _msg(
            'm2',
            'Hi from Jira',
            now - timedelta(minutes=5),
            app_id='jira',
            plugin_id='jira',
            from_external_integration=True,
        ),
    ]
    monkeypatch.setattr(chat_db, "get_inbox_messages", lambda uid, limit, before: rows)

    fetched_calls = []

    def _fake_batch(ids):
        fetched_calls.append(list(ids))
        return [
            {'id': 'linear', 'name': 'Linear', 'image': 'https://cdn/linear.png'},
            {'id': 'jira', 'name': 'Jira', 'image': 'https://cdn/jira.png'},
        ]

    monkeypatch.setattr(inbox_senders, "get_apps_by_ids_db", _fake_batch)

    body = _call()
    items = body['items']
    assert len(items) == 2

    by_id = {it['id']: it for it in items}
    assert by_id['m1']['sender'] == {'display_name': 'Linear', 'avatar_url': 'https://cdn/linear.png', 'type': 'app'}
    assert by_id['m2']['sender'] == {'display_name': 'Jira', 'avatar_url': 'https://cdn/jira.png', 'type': 'app'}
    # one batch lookup for the whole page
    assert len(fetched_calls) == 1
    assert sorted(fetched_calls[0]) == ['jira', 'linear']


def test_mixed_feed_sorted_desc(monkeypatch):
    t0 = datetime(2026, 5, 6, 12, 0, tzinfo=timezone.utc)
    rows = [
        _msg('a', 'newest brief', t0, type='day_summary'),
        _msg('b', 'older app msg', t0 - timedelta(minutes=10), app_id='linear', from_external_integration=True),
        _msg('c', 'middle app msg', t0 - timedelta(minutes=5), app_id='linear', from_external_integration=True),
    ]
    rows = sorted(rows, key=lambda m: m['created_at'], reverse=True)
    monkeypatch.setattr(chat_db, "get_inbox_messages", lambda uid, limit, before: rows)
    monkeypatch.setattr(
        inbox_senders, "get_apps_by_ids_db", lambda ids: [{'id': 'linear', 'name': 'Linear', 'image': None}]
    )

    body = _call()
    items = body['items']
    assert [it['id'] for it in items] == ['a', 'c', 'b']
    assert items[0]['sender']['type'] == 'brief'
    assert items[1]['sender']['type'] == 'app'


def test_pagination_cursor_round_trip(monkeypatch):
    base = datetime(2026, 5, 6, 12, 0, tzinfo=timezone.utc)
    page1 = [
        _msg(f'p1-{i}', f't{i}', base - timedelta(minutes=i), app_id='linear', from_external_integration=True)
        for i in range(3)
    ]
    page2 = [
        _msg(f'p2-{i}', f't{i}', base - timedelta(minutes=10 + i), app_id='linear', from_external_integration=True)
        for i in range(3)
    ]

    seen = {'before': None, 'limit': None}

    def _fake_get(uid, limit, before):
        seen['before'] = before
        seen['limit'] = limit
        if before is None:
            return page1
        return page2

    monkeypatch.setattr(chat_db, "get_inbox_messages", _fake_get)
    monkeypatch.setattr(
        inbox_senders, "get_apps_by_ids_db", lambda ids: [{'id': 'linear', 'name': 'Linear', 'image': None}]
    )

    body1 = _call(limit=3)
    assert len(body1['items']) == 3
    cursor = body1['next_cursor']
    assert cursor is not None  # last item created_at iso

    body2 = _call(limit=3, before=cursor)
    assert [it['id'] for it in body2['items']] == ['p2-0', 'p2-1', 'p2-2']
    assert seen['before'] is not None
    assert seen['limit'] == 3


def test_sender_resolution_fallback_when_app_missing_name(monkeypatch):
    now = datetime(2026, 5, 6, 12, 0, tzinfo=timezone.utc)
    rows = [_msg('m1', 'orphan', now, app_id='ghost', from_external_integration=True)]
    monkeypatch.setattr(chat_db, "get_inbox_messages", lambda uid, limit, before: rows)
    # apps registry returns nothing for 'ghost'
    monkeypatch.setattr(inbox_senders, "get_apps_by_ids_db", lambda ids: [])

    body = _call()
    item = body['items'][0]
    assert item['sender'] == {'display_name': 'App', 'avatar_url': None, 'type': 'app'}


def test_invalid_cursor_raises_400(monkeypatch):
    monkeypatch.setattr(chat_db, "get_inbox_messages", lambda uid, limit, before: [])
    with pytest.raises(HTTPException) as excinfo:
        _call(before="not-a-timestamp")
    assert excinfo.value.status_code == 400


def test_encryption_parity_text_passes_through_decryption_decorator():
    """The DB-layer get_inbox_messages is wrapped in @prepare_for_read which
    invokes _prepare_message_for_read on each row. This test verifies that
    rows tagged data_protection_level='enhanced' flow through that decoder
    so encrypted text becomes plaintext by the time the endpoint sees it."""
    from utils import encryption

    plaintext = "secret hello"
    ciphertext = encryption.encrypt(plaintext, "test-user")

    encrypted_row = _msg(
        'm1',
        ciphertext,
        datetime(2026, 5, 6, 12, 0, tzinfo=timezone.utc),
        app_id='linear',
        from_external_integration=True,
        data_protection_level='enhanced',
    )

    user_doc_ref = MagicMock()
    messages_ref = MagicMock()
    user_doc_ref.collection.return_value = messages_ref

    fake_doc = MagicMock()
    fake_doc.to_dict.return_value = encrypted_row
    fake_doc.id = 'firestore-doc-id'

    chained = MagicMock()
    chained.stream.return_value = iter([fake_doc])
    chained.where.return_value = chained
    chained.order_by.return_value = chained
    chained.limit.return_value = chained
    messages_ref.where.return_value = chained

    mock_client_module.db.collection.return_value.document.return_value = user_doc_ref

    rows = chat_db.get_inbox_messages("test-user", limit=10, before=None)
    assert len(rows) == 1
    assert rows[0]['text'] == plaintext
