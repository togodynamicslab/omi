"""Unit tests for the DELETE /v1/users/fcm-token handler logic.

Calls the route handler as a plain Python function (no FastAPI TestClient)
because the test venv ships without fastapi/firebase. Verifies:

- device_key is derived from X-App-Platform + X-Device-Id-Hash exactly like
  the POST handler
- notification_db.delete_token is called with the derived device_key
- defaults are applied when headers are missing
- POST and DELETE produce identical device_key values for the same headers
"""

import os
import sys
import types
from unittest.mock import MagicMock

os.environ.setdefault(
    "ENCRYPTION_SECRET",
    "omi_ZwB2ZNqB2HHpMK6wStk7sTpavJiPTFg7gXUHnc4tFABPU6pZ2c2DKgehtfgi4RZv",
)

# Stub heavy deps before importing routers.notifications.
mock_client_module = types.ModuleType("database._client")
mock_client_module.db = MagicMock()
mock_client_module.get_prod_db = MagicMock()
mock_client_module.document_id_from_seed = MagicMock(return_value='seeded-id')
sys.modules["database._client"] = mock_client_module

firebase_admin = types.ModuleType("firebase_admin")
firebase_admin.auth = MagicMock()
firebase_admin.messaging = MagicMock()
sys.modules["firebase_admin"] = firebase_admin
sys.modules["firebase_admin.auth"] = firebase_admin.auth
sys.modules["firebase_admin.messaging"] = firebase_admin.messaging

import pytest

try:
    from routers.notifications import delete_token as delete_token_handler
    from routers.notifications import save_token as save_token_handler
    import database.notifications as notification_db
    from models.other import SaveFcmTokenRequest
except (ModuleNotFoundError, ImportError):
    pytest.skip(
        "fastapi / firebase / full backend deps not available in test venv",
        allow_module_level=True,
    )


def test_delete_handler_derives_device_key_from_headers(monkeypatch):
    captured = {}

    def _fake_delete(uid, device_key):
        captured['uid'] = uid
        captured['device_key'] = device_key
        return True

    monkeypatch.setattr(notification_db, "delete_token", _fake_delete)

    resp = delete_token_handler(uid="user-1", x_app_platform="ios", x_device_id_hash="abc123")

    assert resp == {'status': 'Ok'}
    assert captured == {'uid': 'user-1', 'device_key': 'ios_abc123'}


def test_delete_handler_uses_default_when_headers_missing(monkeypatch):
    captured = {}

    def _fake_delete(uid, device_key):
        captured['uid'] = uid
        captured['device_key'] = device_key
        return False  # nothing to delete — still Ok from caller view

    monkeypatch.setattr(notification_db, "delete_token", _fake_delete)

    resp = delete_token_handler(uid="user-2", x_app_platform=None, x_device_id_hash=None)

    assert resp == {'status': 'Ok'}
    assert captured == {'uid': 'user-2', 'device_key': 'unknown_default'}


def test_post_and_delete_derive_matching_device_key(monkeypatch):
    """The same headers must produce the same device_key in POST and DELETE
    so a device that registered a token can also delete its own token."""
    seen = []

    monkeypatch.setattr(
        notification_db,
        "save_token",
        lambda uid, data: seen.append(('save', uid, data['device_key'])),
    )
    monkeypatch.setattr(
        notification_db,
        "delete_token",
        lambda uid, device_key: seen.append(('delete', uid, device_key)),
    )

    save_payload = SaveFcmTokenRequest(fcm_token="t", time_zone="UTC")
    save_token_handler(
        data=save_payload,
        uid="user-3",
        x_app_platform="android",
        x_device_id_hash="xyz789",
    )
    delete_token_handler(uid="user-3", x_app_platform="android", x_device_id_hash="xyz789")

    save_evt = next(s for s in seen if s[0] == 'save')
    del_evt = next(s for s in seen if s[0] == 'delete')
    assert save_evt[2] == del_evt[2] == 'android_xyz789'
