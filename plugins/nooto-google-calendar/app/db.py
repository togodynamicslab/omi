"""
Redis-based storage for Google Calendar tokens and user settings.
Supports both local development (file fallback) and production (Redis).
"""

import json
import os
import sys
from datetime import datetime
from typing import Optional, Dict, Any

try:
    import redis

    REDIS_AVAILABLE = True
except ImportError:
    REDIS_AVAILABLE = False

_redis_client = None

REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379")


def _get_redis() -> Optional['redis.Redis']:
    """Get or create Redis connection."""
    global _redis_client

    if not REDIS_AVAILABLE:
        return None

    if not REDIS_URL:
        return None

    if _redis_client is None:
        try:
            _redis_client = redis.from_url(REDIS_URL, decode_responses=True)
            _redis_client.ping()
            print("[db] connected to Redis")
            sys.stdout.flush()
        except Exception as e:
            print(f"[db] Redis connection failed: {e}, falling back to file storage")
            sys.stdout.flush()
            return None

    return _redis_client


# File-based fallback for local development
DATA_DIR = os.path.join(os.path.dirname(__file__), "..", "data")
TOKENS_FILE = os.path.join(DATA_DIR, "tokens.json")
OAUTH_STATES_FILE = os.path.join(DATA_DIR, "oauth_states.json")
USER_SETTINGS_FILE = os.path.join(DATA_DIR, "user_settings.json")


def _ensure_data_dir():
    """Ensure the data directory exists."""
    os.makedirs(DATA_DIR, exist_ok=True)


def _load_json(filepath: str) -> Dict[str, Any]:
    """Load JSON from file, return empty dict if not exists."""
    _ensure_data_dir()
    if os.path.exists(filepath):
        with open(filepath, "r") as f:
            return json.load(f)
    return {}


def _save_json(filepath: str, data: Dict[str, Any]):
    """Save data to JSON file."""
    _ensure_data_dir()
    with open(filepath, "w") as f:
        json.dump(data, f, indent=2)


# ============================================
# Token Management
# ============================================


def store_google_tokens(uid: str, access_token: str, refresh_token: str, expires_at: str):
    """Store Google OAuth2 tokens for a user."""
    r = _get_redis()

    token_data = {
        "access_token": access_token,
        "refresh_token": refresh_token,
        "expires_at": expires_at,
        "updated_at": datetime.utcnow().isoformat(),
    }

    if r:
        key = f"gcal:tokens:{uid}"
        r.set(key, json.dumps(token_data))
        r.expire(key, 60 * 60 * 24 * 365)  # 1 year
        print(f"[db] stored tokens in Redis for {uid}")
        sys.stdout.flush()
    else:
        tokens = _load_json(TOKENS_FILE)
        tokens[uid] = token_data
        _save_json(TOKENS_FILE, tokens)
        print(f"[db] stored tokens in file for {uid}")
        sys.stdout.flush()


def get_google_tokens(uid: str) -> Optional[Dict[str, Any]]:
    """Get Google tokens for a user."""
    r = _get_redis()

    if r:
        key = f"gcal:tokens:{uid}"
        data = r.get(key)
        if data:
            return json.loads(data)
        return None
    else:
        tokens = _load_json(TOKENS_FILE)
        return tokens.get(uid)


def update_google_tokens(uid: str, access_token: str, expires_at: str):
    """Update access token after refresh (keeps existing refresh token)."""
    r = _get_redis()

    if r:
        key = f"gcal:tokens:{uid}"
        data = r.get(key)
        if data:
            token_data = json.loads(data)
            token_data["access_token"] = access_token
            token_data["expires_at"] = expires_at
            token_data["updated_at"] = datetime.utcnow().isoformat()
            r.set(key, json.dumps(token_data))
            r.expire(key, 60 * 60 * 24 * 365)
    else:
        tokens = _load_json(TOKENS_FILE)
        if uid in tokens:
            tokens[uid]["access_token"] = access_token
            tokens[uid]["expires_at"] = expires_at
            tokens[uid]["updated_at"] = datetime.utcnow().isoformat()
            _save_json(TOKENS_FILE, tokens)


def delete_google_tokens(uid: str):
    """Delete Google tokens for a user."""
    r = _get_redis()

    if r:
        r.delete(f"gcal:tokens:{uid}")
    else:
        tokens = _load_json(TOKENS_FILE)
        if uid in tokens:
            del tokens[uid]
            _save_json(TOKENS_FILE, tokens)


# ============================================
# OAuth State Management (CSRF protection)
# ============================================


def store_oauth_state(uid: str, state: str):
    """Store OAuth state for CSRF verification."""
    r = _get_redis()

    if r:
        key = f"gcal:oauth_state:{uid}"
        r.set(key, state)
        r.expire(key, 60 * 10)  # 10 minutes
    else:
        states = _load_json(OAUTH_STATES_FILE)
        states[uid] = {"state": state, "created_at": datetime.utcnow().isoformat()}
        _save_json(OAUTH_STATES_FILE, states)


def get_oauth_state(uid: str) -> Optional[str]:
    """Get stored OAuth state for a user."""
    r = _get_redis()

    if r:
        return r.get(f"gcal:oauth_state:{uid}")
    else:
        states = _load_json(OAUTH_STATES_FILE)
        state_data = states.get(uid)
        if state_data:
            return state_data.get("state")
        return None


def delete_oauth_state(uid: str):
    """Delete OAuth state after verification."""
    r = _get_redis()

    if r:
        r.delete(f"gcal:oauth_state:{uid}")
    else:
        states = _load_json(OAUTH_STATES_FILE)
        if uid in states:
            del states[uid]
            _save_json(OAUTH_STATES_FILE, states)


# ============================================
# User Settings Management
# ============================================


def store_user_setting(uid: str, key: str, value: Any):
    """Store a setting for a user."""
    r = _get_redis()

    if r:
        redis_key = f"gcal:settings:{uid}"
        settings = r.get(redis_key)
        settings = json.loads(settings) if settings else {}
        settings[key] = value
        r.set(redis_key, json.dumps(settings))
    else:
        settings = _load_json(USER_SETTINGS_FILE)
        if uid not in settings:
            settings[uid] = {}
        settings[uid][key] = value
        _save_json(USER_SETTINGS_FILE, settings)


def get_user_setting(uid: str, key: str) -> Optional[Any]:
    """Get a setting for a user."""
    r = _get_redis()

    if r:
        redis_key = f"gcal:settings:{uid}"
        settings = r.get(redis_key)
        if settings:
            return json.loads(settings).get(key)
        return None
    else:
        settings = _load_json(USER_SETTINGS_FILE)
        return settings.get(uid, {}).get(key)
