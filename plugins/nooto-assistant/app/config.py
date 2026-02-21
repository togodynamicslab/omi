import os
from pathlib import Path

OPENROUTER_API_KEY = os.getenv('OPENROUTER_API_KEY', '')
LLM_MODEL = os.getenv('LLM_MODEL', 'google/gemini-2.5-flash')
DETECT_MODEL = os.getenv('DETECT_MODEL', 'google/gemini-2.0-flash-001')
REDIS_URL = os.getenv('REDIS_URL', 'redis://redis:6379')
CHUNK_THRESHOLD = int(os.getenv('CHUNK_THRESHOLD', '15'))
TIME_THRESHOLD_SECONDS = int(os.getenv('TIME_THRESHOLD_SECONDS', '45'))

# Omi Integration API
OMI_API_URL = os.getenv('OMI_API_URL', 'https://api.omi.me')
OMI_APP_ID = os.getenv('OMI_APP_ID', '')
OMI_APP_API_KEY = os.getenv('OMI_APP_API_KEY', '')

# Anti-spam cooldown (seconds) — shorter than grammarly since this is Q&A
NOTIFICATION_COOLDOWN_SECONDS = int(os.getenv('NOTIFICATION_COOLDOWN_SECONDS', '30'))

# Hybrid delivery: wait this many seconds for a webhook to pick up the answer
# before falling back to the Omi notification API
WEBHOOK_FALLBACK_SECONDS = int(os.getenv('WEBHOOK_FALLBACK_SECONDS', '45'))

# Adaptive flush: wait for silence after last segment, not a fixed window.
# Omi splits speech across segments, so "Opa" and the question may arrive separately.
FLUSH_SILENCE_SECONDS = int(os.getenv('FLUSH_SILENCE_SECONDS', '5'))
MIN_COLLECT_SECONDS = int(os.getenv('MIN_COLLECT_SECONDS', '8'))
MAX_COLLECT_SECONDS = int(os.getenv('MAX_COLLECT_SECONDS', '30'))

# Sequential question queue — prevents race conditions on rapid triggers
PROCESS_LOCK_TTL = int(os.getenv('PROCESS_LOCK_TTL', '120'))
MAX_QUEUE_SIZE = int(os.getenv('MAX_QUEUE_SIZE', '5'))
QUEUE_ITEM_TTL = int(os.getenv('QUEUE_ITEM_TTL', '300'))

# ---------------------------------------------------------------------------
# Prompt loading — simple file-based prompts, no soul framework needed.
# ---------------------------------------------------------------------------

_root = Path(__file__).resolve().parent.parent


def _load_prompt(rel_path: str) -> str:
    p = _root / rel_path
    if p.exists():
        return p.read_text().strip()
    raise RuntimeError(f'Missing prompt file: {p}')


DETECT_PROMPT = _load_prompt('prompts/detect.md')
ANSWER_PROMPT = _load_prompt('prompts/answer.md')
DIRECT_ANSWER_PROMPT = _load_prompt('prompts/direct.md')
