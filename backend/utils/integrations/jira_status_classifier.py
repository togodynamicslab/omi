"""LLM-classified Jira status semantics + deterministic resolution mapping.

Adds a parallel axis to the existing 3-bucket ``status_type`` vocabulary:
``actionability`` (self / waiting / blocked) for non-terminal issues, and
``resolution`` (completed / dropped) for terminal issues. Both are written
additively into ``external_source.metadata`` so every existing reader keeps
working unchanged.

Cross-reference: see ``backend/utils/integrations/jira_actions.py:_infer_status_type``
(sync, used by the transition-write path, axis ``status_name → status_type``).
This module's classifier is async, used by the read/sync path, axis
``status_name → actionability``. Different lifecycles, intentionally distinct.

Data flow (cache miss/hit/fallback decision tree):

    classify_statuses(cloudid, statuses[])
        |
        |--- pre-warm flag set? ------> YES: return fallback for ALL,
        |       (jira:prewarm_in_progress    do NOT write cache.
        |        :{uid}:{cloudid})
        |
        | NO
        v
    r.mget(keys)  <-- one round-trip for the whole page
        |
        v
    for each (name, raw):
        raw is None? --> MISS
        raw decodes + validates? --> HIT (with status_category match check)
           - status_category matches? --> HIT
           - status_category drifted? --> stale rename, treat as MISS
        raw fails ValidationError / bad JSON? --> MISS (re-classify)
        |
        v
    MISS set non-empty?
        |
        v
    llm_mini.with_structured_output(BatchStatusClassification).ainvoke(prompt)
        | success?
        |    yes -> for every input, check coverage
        |        missing names? --> ONE retry with only the missing names
        |            still missing --> fallback for those, do NOT cache
        |        all present --> cache write per-name (source=llm)
        |    no (raises) -> fallback for ALL miss-set, do NOT cache
        v
    merge HIT + LLM/fallback results
        v
    return {status_name: CachedClassification}

classify_resolution(cloudid, resolution_name):
    None / empty --> None (open issue, no resolution yet)
    seed allowlist (completed) --> "completed"
    seed allowlist (dropped) --> "dropped"
    unknown --> Redis cache `jira:resolution_class:{cloudid}:{slug}`
              --> miss --> LLM single-shot classify --> cache --> return
              --> error --> None (no fallback bucket here; caller decides)

rewrite_actionability_in_place(uid, cloudid, status_name, new_actionability):
    Firestore where external_source.source == "jira"
        --> Python filter on metadata.cloudid == cloudid AND metadata.status == status_name
        --> batch update metadata.actionability + metadata.classification_source="override"
        --> commit every 400 docs
        --> returns count updated
"""

from __future__ import annotations

import json
import logging
import re
from datetime import datetime, timezone
from typing import Literal, Optional

from pydantic import BaseModel, Field, ValidationError

from google.cloud.firestore_v1 import FieldFilter

from database.redis_db import r as redis_client
from database._client import db as firestore_db
from utils.llm.clients import llm_mini
from utils.log_sanitizer import sanitize, sanitize_pii

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Pydantic schemas (per design doc)
# ---------------------------------------------------------------------------

Actionability = Literal["self", "waiting", "blocked"]
Certainty = Literal["high", "medium", "low"]
ResolutionType = Literal["completed", "dropped"]
Source = Literal["llm", "override", "seed", "fallback"]
StatusCategory = Literal["new", "indeterminate", "done"]


class StatusInput(BaseModel):
    status_name: str
    # NOTE: Jira's statusCategory.key vocabulary is "new"/"indeterminate"/"done".
    # Matches backend metadata.status_type after the _STATUS_TYPE_TO_METADATA
    # translation in jira_sync.py:45 (plugin's "in_progress" maps to
    # "indeterminate" before write).
    status_category: StatusCategory
    project_key: Optional[str] = None  # context only, not part of the cache key


class StatusClassification(BaseModel):
    actionability: Actionability = Field(
        description=(
            "self = user is actively working on it; "
            "waiting = user has handed off, waiting for review/QA/approval; "
            "blocked = user cannot progress without unblocking event"
        )
    )
    certainty: Certainty = Field(
        description=(
            "high if the status name is unambiguous (e.g. 'In Progress'); "
            "medium if name implies bucket but custom phrasing; "
            "low if name is opaque or could fit multiple buckets"
        )
    )


class _ClassificationEntry(BaseModel):
    """Flat shape for the LLM response.

    NOTE (deviation from the design doc): the design's
    ``BatchStatusClassification.classifications: dict[str, StatusClassification]``
    shape relies on OpenAI structured-output accepting an arbitrary-key dict,
    which langchain's ``with_structured_output`` does not reliably serialize
    for OpenAI function-calling (additionalProperties on object schemas is
    unsupported). We use a flat list of entries with ``status_name`` as a
    field instead and convert to dict[str, StatusClassification] internally.
    Semantics are identical; only the wire shape changes.
    """

    status_name: str = Field(description="The exact status name from the input list.")
    actionability: Actionability
    certainty: Certainty


class BatchStatusClassification(BaseModel):
    """LLM returns one entry per input status, keyed by ``status_name``."""

    classifications: list[_ClassificationEntry] = Field(
        description="One entry per input status. Every input MUST have a matching entry."
    )


class CachedClassification(BaseModel):
    actionability: Actionability
    certainty: Certainty
    source: Source
    classified_at: str  # ISO8601
    status_category: StatusCategory  # for rename / drift detection


class _ResolutionCache(BaseModel):
    resolution: ResolutionType
    source: Source  # "seed" | "llm" | "override"
    classified_at: str


class _ResolutionLLM(BaseModel):
    resolution: ResolutionType = Field(
        description=(
            "completed = the work shipped / was accepted; " "dropped = the work was abandoned / cancelled / not done"
        )
    )


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Resolution seed allowlists. Standard Jira ships these; admins can add more.
# Unknown names fall through to the LLM.
_RESOLUTION_COMPLETED_SEED = frozenset(
    {
        "done",
        "fixed",
        "resolved",
        "implemented",
        "delivered",
        "complete",
        "completed",
    }
)
_RESOLUTION_DROPPED_SEED = frozenset(
    {
        "won't do",
        "wont do",
        "cancelled",
        "canceled",
        "duplicate",
        "won't fix",
        "wont fix",
        "rejected",
        "invalid",
    }
)

_SLUG_NON_ALNUM_RE = re.compile(r"[^a-z0-9]+")

# Redis key formats (cloudid + slug(status_name) so renames-that-collide-to-
# the-same-slug remain cache hits — see design doc "slug is intentionally lossy").
_STATUS_CACHE_KEY = "jira:status_class:{cloudid}:{slug}"
_RESOLUTION_CACHE_KEY = "jira:resolution_class:{cloudid}:{slug}"
_PREWARM_FLAG_KEY = "jira:prewarm_in_progress:{uid}:{cloudid}"

# Pre-warm flag TTL (seconds). Matches design doc Day 3 spec.
PREWARM_FLAG_TTL = 60

# Firestore batch commit boundary.
_FIRESTORE_BATCH_LIMIT = 400


# ---------------------------------------------------------------------------
# LLM system prompt (full certainty rubric per design doc)
# ---------------------------------------------------------------------------

_CLASSIFIER_SYSTEM_PROMPT = """You classify Jira workflow status names into actionability buckets so the product can tell the user what is actually on their plate vs what is parked with someone else.

ACTIONABILITY DEFINITIONS:
- "self": user is the next actor. Examples: "In Progress", "To Do",
  "Open", "Implementing", "Coding", "Working".
- "waiting": user has handed off; another human's action is the next step.
  Examples: "In Review", "Code Review", "PR Review", "Awaiting QA",
  "QA - Round 2", "Awaiting Stakeholder Sign-off", "Pending Legal Review".
- "blocked": user cannot progress without an unblocking event (dependency,
  decision, external system). Examples: "Blocked", "On Hold", "Waiting on
  Customer", "Pending External Dependency".

CERTAINTY RUBRIC (output one of high|medium|low):
- "high": the status name unambiguously maps to one bucket. Examples that
  are "high": "To Do" -> self/high, "In Review" -> waiting/high, "Blocked"
  -> blocked/high, "In Progress" -> self/high.
- "medium": the status name implies a bucket but uses custom phrasing.
  Examples: "Sprint Backlog" -> self/medium, "Awaiting Specs" ->
  waiting/medium, "Parked - Q3" -> blocked/medium.
- "low": the status name is opaque, codified, or could plausibly fit
  multiple buckets. Examples: "Step 7", "Phase 2", "Discovery",
  "Triaged", "Acknowledged".

Default to "self" when uncertain - it's the conservative bucket because
marking something "waiting" hides it from the on-plate count, but marking
something "self" only over-counts (and the user notices and corrects).

You will receive a list of status names with their Jira statusCategory hint
("new" / "indeterminate" / "done"). Return one classification per input.
Every input status name MUST have exactly one matching entry in your output.
"""

_RESOLUTION_SYSTEM_PROMPT = """You classify a Jira resolution name as either "completed" (the work shipped / was accepted) or "dropped" (the work was abandoned / cancelled / not done). Default to "completed" only when the name unambiguously implies success; anything that smells like abandonment, deferral, or rejection is "dropped"."""


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _slug(name: str) -> str:
    """Lowercase, replace [^a-z0-9]+ with '-', strip leading/trailing '-'."""
    slugged = _SLUG_NON_ALNUM_RE.sub("-", (name or "").lower()).strip("-")
    return slugged


def _status_cache_key(cloudid: str, status_name: str) -> str:
    return _STATUS_CACHE_KEY.format(cloudid=cloudid, slug=_slug(status_name))


def _resolution_cache_key(cloudid: str, resolution_name: str) -> str:
    return _RESOLUTION_CACHE_KEY.format(cloudid=cloudid, slug=_slug(resolution_name))


def _prewarm_flag_key(uid: str, cloudid: str) -> str:
    return _PREWARM_FLAG_KEY.format(uid=uid, cloudid=cloudid)


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _fallback(status_category: StatusCategory) -> CachedClassification:
    """Conservative default when the LLM is unavailable or partial.

    actionability="self" preserves today's behavior (item counted on plate).
    source="fallback" signals "do NOT cache this result" upstream.
    """
    return CachedClassification(
        actionability="self",
        certainty="low",
        source="fallback",
        classified_at=_now_iso(),
        status_category=status_category,
    )


def _build_classification_prompt(statuses: list[StatusInput]) -> str:
    """Render the user message for a batch classify call."""
    lines = []
    for s in statuses:
        proj = f", project_key={s.project_key}" if s.project_key else ""
        lines.append(f'- "{s.status_name}" (statusCategory={s.status_category}{proj})')
    return "Classify each of the following Jira statuses:\n" + "\n".join(lines)


async def _call_llm_batch(statuses: list[StatusInput]) -> BatchStatusClassification:
    """Single batched LLM call. Raises on transport / parse failure."""
    prompt = _build_classification_prompt(statuses)
    messages = [
        {"role": "system", "content": _CLASSIFIER_SYSTEM_PROMPT},
        {"role": "user", "content": prompt},
    ]
    with_parser = llm_mini.with_structured_output(BatchStatusClassification)
    response: BatchStatusClassification = await with_parser.ainvoke(messages)
    return response


async def _call_llm_resolution(resolution_name: str) -> _ResolutionLLM:
    """Single-shot LLM classify for an unknown resolution name."""
    messages = [
        {"role": "system", "content": _RESOLUTION_SYSTEM_PROMPT},
        {"role": "user", "content": f'Classify this Jira resolution name: "{resolution_name}"'},
    ]
    with_parser = llm_mini.with_structured_output(_ResolutionLLM)
    response: _ResolutionLLM = await with_parser.ainvoke(messages)
    return response


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


async def classify_statuses(cloudid: str, statuses: list[StatusInput]) -> dict[str, CachedClassification]:
    """Classify a batch of Jira status names. Returns one entry per input.

    - Pre-warm flag set for (uid, cloudid)? cannot happen here — the flag
      is keyed by uid, which sync-path callers pass via the cache-key prefix
      is NOT used; pre-warm short-circuit is checked by the SYNC caller via
      ``is_prewarm_in_progress(uid, cloudid)``. This function does not see
      uid (only cloudid) because the cache is per-site, not per-user. For
      safety, sync callers should consult ``is_prewarm_in_progress`` before
      invoking; if set, they should skip cache writes by treating returned
      entries as fallback.

    NOTE: The cache write path checks ``classified_at`` only — entries with
    ``source == "fallback"`` are NEVER written. See ``_write_cache_entries``.
    """
    if not statuses:
        return {}

    # 1. Batch-read Redis with mget per design decision #5.
    keys = [_status_cache_key(cloudid, s.status_name) for s in statuses]
    try:
        raw_values = redis_client.mget(keys)
    except Exception as e:
        logger.warning(f"jira_status_classifier: mget failed cloudid={cloudid}: {sanitize(str(e))}")
        raw_values = [None] * len(keys)

    hits: dict[str, CachedClassification] = {}
    misses: list[StatusInput] = []

    for status_input, raw in zip(statuses, raw_values):
        if raw is None:
            misses.append(status_input)
            continue
        try:
            decoded = raw.decode("utf-8") if isinstance(raw, (bytes, bytearray)) else raw
            payload = json.loads(decoded)
            cached = CachedClassification.model_validate(payload)
        except (ValidationError, ValueError, TypeError, AttributeError, json.JSONDecodeError) as e:
            # Schema drift / half-written entry / manual override typo.
            # Fall through to re-classify per design decision #2.
            logger.info(
                "jira_status_classifier: cache entry invalid, re-classifying "
                f"cloudid={cloudid} status={sanitize_pii(status_input.status_name)} err={sanitize(str(e))}"
            )
            misses.append(status_input)
            continue
        # Status-category drift = workflow rename, treat as miss.
        if cached.status_category != status_input.status_category:
            logger.info(
                "jira_status_classifier: status_category drift, re-classifying "
                f"cloudid={cloudid} status={sanitize_pii(status_input.status_name)} "
                f"cached={cached.status_category} actual={status_input.status_category}"
            )
            misses.append(status_input)
            continue
        hits[status_input.status_name] = cached

    if not misses:
        return hits

    # 2. Cache miss path - LLM batch with one bounded retry for partial responses.
    miss_results = await _classify_misses_with_retry(cloudid, misses)
    hits.update(miss_results)
    return hits


async def _classify_misses_with_retry(cloudid: str, misses: list[StatusInput]) -> dict[str, CachedClassification]:
    """LLM batch call + one bounded retry for missing names; fallback for stragglers.

    Cached only when source == "llm" (success). Fallback entries never cache.
    """
    results: dict[str, CachedClassification] = {}
    miss_by_name = {s.status_name: s for s in misses}

    try:
        response = await _call_llm_batch(misses)
    except Exception as e:
        logger.warning(
            "jira_status_classifier: LLM batch failed cloudid=" f"{cloudid} count={len(misses)} err={sanitize(str(e))}"
        )
        for s in misses:
            results[s.status_name] = _fallback(s.status_category)
        return results

    for entry in response.classifications:
        if entry.status_name not in miss_by_name:
            continue  # LLM hallucinated a name; ignore.
        status_input = miss_by_name[entry.status_name]
        results[entry.status_name] = CachedClassification(
            actionability=entry.actionability,
            certainty=entry.certainty,
            source="llm",
            classified_at=_now_iso(),
            status_category=status_input.status_category,
        )

    missing_after_first = [s for s in misses if s.status_name not in results]
    if missing_after_first:
        logger.info(
            "jira_status_classifier: partial batch response, retrying with missing "
            f"cloudid={cloudid} missing={len(missing_after_first)} of {len(misses)}"
        )
        try:
            retry_response = await _call_llm_batch(missing_after_first)
        except Exception as e:
            logger.warning(
                f"jira_status_classifier: retry LLM batch failed cloudid={cloudid} " f"err={sanitize(str(e))}"
            )
            retry_response = None

        if retry_response is not None:
            retry_miss_by_name = {s.status_name: s for s in missing_after_first}
            for entry in retry_response.classifications:
                if entry.status_name not in retry_miss_by_name:
                    continue
                status_input = retry_miss_by_name[entry.status_name]
                results[entry.status_name] = CachedClassification(
                    actionability=entry.actionability,
                    certainty=entry.certainty,
                    source="llm",
                    classified_at=_now_iso(),
                    status_category=status_input.status_category,
                )

        # Anything still missing after retry -> fallback, no cache.
        for s in missing_after_first:
            if s.status_name not in results:
                results[s.status_name] = _fallback(s.status_category)

    # 3. Cache write for successful entries only.
    _write_cache_entries(cloudid, results)

    # 4. Instrumentation per design Day 3 spec.
    for name, cached in results.items():
        logger.info(
            "jira_status_classifier: classified "
            f"cloudid={cloudid} status={sanitize_pii(name)} "
            f"actionability={cached.actionability} certainty={cached.certainty} "
            f"source={cached.source}"
        )

    return results


def _write_cache_entries(cloudid: str, entries: dict[str, CachedClassification]) -> None:
    """Persist successful classifications. Fallback entries are skipped."""
    for name, cached in entries.items():
        if cached.source == "fallback":
            continue
        key = _status_cache_key(cloudid, name)
        try:
            redis_client.set(key, cached.model_dump_json())
        except Exception as e:
            logger.warning(
                f"jira_status_classifier: cache write failed cloudid={cloudid} "
                f"status={sanitize_pii(name)} err={sanitize(str(e))}"
            )


def is_prewarm_in_progress(uid: str, cloudid: str) -> bool:
    """Sync-path helper: true if a pre-warm task holds the flag for (uid, cloudid).

    Sync callers should treat all classifier results as fallback (no cache
    write) while this is true. Avoids the post-OAuth double-LLM-call race.
    """
    try:
        return redis_client.get(_prewarm_flag_key(uid, cloudid)) is not None
    except Exception as e:
        logger.warning(
            f"jira_status_classifier: prewarm flag check failed uid={uid} " f"cloudid={cloudid} err={sanitize(str(e))}"
        )
        return False


async def classify_statuses_for_sync(
    uid: str, cloudid: str, statuses: list[StatusInput]
) -> dict[str, CachedClassification]:
    """Sync-path wrapper that honors the pre-warm short-circuit.

    If pre-warm is in flight, return fallback for every input WITHOUT writing
    to the cache. This is what the design's normalize-path uses.
    """
    if not statuses:
        return {}
    if is_prewarm_in_progress(uid, cloudid):
        logger.info(
            f"jira_status_classifier: pre-warm in progress, short-circuiting to fallback "
            f"uid={uid} cloudid={cloudid} count={len(statuses)}"
        )
        return {s.status_name: _fallback(s.status_category) for s in statuses}
    return await classify_statuses(cloudid, statuses)


async def classify_resolution(cloudid: str, resolution_name: Optional[str]) -> Optional[ResolutionType]:
    """Map a Jira ``fields.resolution.name`` to ``completed`` / ``dropped``.

    Order:
      1. None / empty / whitespace -> None (open issue, no resolution).
      2. Seed allowlist (case-insensitive) -> deterministic answer.
      3. Redis cache `jira:resolution_class:{cloudid}:{slug}`.
      4. LLM single-shot classify; cache on success.
      5. LLM error -> None (caller decides; resolution is optional metadata).
    """
    if not resolution_name or not resolution_name.strip():
        return None

    normalized = resolution_name.strip().lower()
    if normalized in _RESOLUTION_COMPLETED_SEED:
        return "completed"
    if normalized in _RESOLUTION_DROPPED_SEED:
        return "dropped"

    key = _resolution_cache_key(cloudid, resolution_name)
    try:
        raw = redis_client.get(key)
    except Exception as e:
        logger.warning(
            f"jira_status_classifier: resolution cache get failed cloudid={cloudid} " f"err={sanitize(str(e))}"
        )
        raw = None

    if raw is not None:
        try:
            decoded = raw.decode("utf-8") if isinstance(raw, (bytes, bytearray)) else raw
            cached = _ResolutionCache.model_validate(json.loads(decoded))
            return cached.resolution
        except (ValidationError, ValueError, TypeError, AttributeError, json.JSONDecodeError) as e:
            logger.info(
                "jira_status_classifier: resolution cache invalid, re-classifying "
                f"cloudid={cloudid} resolution={sanitize_pii(resolution_name)} err={sanitize(str(e))}"
            )

    try:
        response = await _call_llm_resolution(resolution_name)
    except Exception as e:
        logger.warning(
            "jira_status_classifier: resolution LLM failed "
            f"cloudid={cloudid} resolution={sanitize_pii(resolution_name)} err={sanitize(str(e))}"
        )
        return None

    cached = _ResolutionCache(
        resolution=response.resolution,
        source="llm",
        classified_at=_now_iso(),
    )
    try:
        redis_client.set(key, cached.model_dump_json())
    except Exception as e:
        logger.warning(
            f"jira_status_classifier: resolution cache write failed cloudid={cloudid} " f"err={sanitize(str(e))}"
        )

    logger.info(
        "jira_status_classifier: classified resolution "
        f"cloudid={cloudid} resolution={sanitize_pii(resolution_name)} "
        f"value={response.resolution} source=llm"
    )
    return response.resolution


# ---------------------------------------------------------------------------
# Override buckets — v2 UI replaces the legacy 3-bucket actionability CLI with
# a 5-bucket model that can also flip terminal-state metadata.
# ---------------------------------------------------------------------------

Bucket = Literal["self", "waiting", "blocked", "completed", "dropped"]

_NON_TERMINAL_BUCKETS: frozenset[str] = frozenset({"self", "waiting", "blocked"})
_TERMINAL_BUCKETS: frozenset[str] = frozenset({"completed", "dropped"})


def _bucket_to_actionability(bucket: Bucket) -> Optional[Actionability]:
    if bucket in _NON_TERMINAL_BUCKETS:
        return bucket  # type: ignore[return-value]
    return None


def _bucket_to_resolution(bucket: Bucket) -> Optional[ResolutionType]:
    if bucket == "completed":
        return "completed"
    if bucket == "dropped":
        return "dropped"
    return None


def _bucket_to_status_category(bucket: Bucket, cached_category: Optional[StatusCategory]) -> StatusCategory:
    """Pick the status_category to persist alongside the override cache entry.

    Terminal buckets force "done" (the whole point of "this is a terminal
    state"). Non-terminal buckets preserve the cached category when known
    (keeps rename-detection accurate) and default to "indeterminate" otherwise
    — matches the legacy CLI's choice.
    """
    if bucket in _TERMINAL_BUCKETS:
        return "done"
    return cached_category or "indeterminate"


def _bucket_to_actionability_for_cache(bucket: Bucket) -> Actionability:
    """The CachedClassification schema requires a non-null actionability.

    For terminal buckets the override semantically nulls actionability on
    Firestore (resolution wins), but the per-status cache entry still needs
    an Actionability value. We persist the conservative "self" placeholder
    — the classifier never reads it back for terminal-bucket statuses
    because the override path consults bucket via resolution-derivation,
    not the cached actionability field. See ``apply_status_override``.
    """
    actionability = _bucket_to_actionability(bucket)
    if actionability is not None:
        return actionability
    return "self"


def _read_cached_status_category(cloudid: str, status_name: str) -> Optional[StatusCategory]:
    """Best-effort read of the prior cache entry's status_category, for
    rename-detection preservation on non-terminal overrides."""
    key = _status_cache_key(cloudid, status_name)
    try:
        raw = redis_client.get(key)
    except Exception:
        return None
    if raw is None:
        return None
    try:
        decoded = raw.decode("utf-8") if isinstance(raw, (bytes, bytearray)) else raw
        payload = json.loads(decoded)
        cached = CachedClassification.model_validate(payload)
    except (ValidationError, ValueError, TypeError, AttributeError, json.JSONDecodeError):
        return None
    return cached.status_category


def derive_bucket(cached: CachedClassification) -> Bucket:
    """Map a cached classification back to its 5-bucket label.

    Override entries written by ``apply_status_override`` carry the bucket
    implicitly via ``actionability``/``status_category`` — the cached
    ``actionability`` is a placeholder for terminal buckets, so we prefer
    ``status_category == "done"`` (terminal) over actionability. For
    terminal entries we can't tell completed-vs-dropped from the cached
    actionability alone; callers needing that distinction should consult
    ``external_source.metadata.resolution`` on a matching action item, but
    the UI typically derives bucket from the action_item metadata, not the
    cache entry. This helper is a best-effort fallback for unmatched
    (cache-only) entries.
    """
    if cached.status_category == "done":
        # We cannot disambiguate completed vs dropped from cache alone;
        # default to "completed" as the higher-frequency case. Override
        # entries are normally read alongside matching action items where
        # metadata.resolution is authoritative.
        return "completed"
    return cached.actionability  # type: ignore[return-value]


def get_cached_classification(cloudid: str, status_name: str) -> Optional[CachedClassification]:
    """Single-key cache read, used by the status-classifications GET endpoint.

    Returns None on cache miss, malformed payload, or Redis transport error.
    """
    key = _status_cache_key(cloudid, status_name)
    try:
        raw = redis_client.get(key)
    except Exception as e:
        logger.warning(
            f"jira_status_classifier: cache get failed cloudid={cloudid} "
            f"status={sanitize_pii(status_name)} err={sanitize(str(e))}"
        )
        return None
    if raw is None:
        return None
    try:
        decoded = raw.decode("utf-8") if isinstance(raw, (bytes, bytearray)) else raw
        payload = json.loads(decoded)
        return CachedClassification.model_validate(payload)
    except (ValidationError, ValueError, TypeError, AttributeError, json.JSONDecodeError):
        return None


def apply_status_override(uid: str, cloudid: str, status_name: str, bucket: Bucket) -> dict:
    """Override the per-status classification AND in-place rewrite every
    matching action item.

    Returns ``{"redis_written": bool, "items_updated": int}``.

    Bucket mapping:
      - "self":      actionability=self,     resolution=None,      status_type unchanged, completed unchanged
      - "waiting":   actionability=waiting,  resolution=None,      status_type unchanged, completed unchanged
      - "blocked":   actionability=blocked,  resolution=None,      status_type unchanged, completed unchanged
      - "completed": actionability=None,     resolution=completed, status_type=done,      completed=True
      - "dropped":   actionability=None,     resolution=dropped,   status_type=done,      completed=True

    Terminal buckets ("completed"/"dropped") FORCE status_type=done +
    completed=True on every matching action item, regardless of Jira's own
    statusCategory. Non-terminal buckets DO NOT touch status_type or
    completed — they only change actionability. The cached entry and every
    rewritten item are stamped with ``classification_source="override"``.
    """
    if bucket not in _NON_TERMINAL_BUCKETS and bucket not in _TERMINAL_BUCKETS:
        raise ValueError(f"unknown bucket: {bucket!r}")

    # 1. Write the override into the per-status Redis cache. Wins forever
    # against any subsequent LLM re-classification.
    cached_category = _read_cached_status_category(cloudid, status_name)
    cached = CachedClassification(
        actionability=_bucket_to_actionability_for_cache(bucket),
        certainty="high",
        source="override",
        classified_at=_now_iso(),
        status_category=_bucket_to_status_category(bucket, cached_category),
    )
    key = _status_cache_key(cloudid, status_name)
    redis_written = True
    try:
        redis_client.set(key, cached.model_dump_json())
    except Exception as e:
        redis_written = False
        logger.warning(
            f"jira_status_classifier: override cache write failed cloudid={cloudid} "
            f"status={sanitize_pii(status_name)} err={sanitize(str(e))}"
        )

    # 2. In-place rewrite of every matching action item.
    new_actionability = _bucket_to_actionability(bucket)
    new_resolution = _bucket_to_resolution(bucket)
    is_terminal = bucket in _TERMINAL_BUCKETS

    coll = firestore_db.collection("users").document(uid).collection("action_items")
    query = coll.where(filter=FieldFilter("external_source.source", "==", "jira"))

    count = 0
    batch = firestore_db.batch()
    pending = 0
    for doc in query.stream():
        data = doc.to_dict() or {}
        ext = data.get("external_source") or {}
        md = ext.get("metadata") or {}
        if md.get("cloudid") != cloudid:
            continue
        if md.get("status") != status_name:
            continue
        update_payload: dict = {
            "external_source.metadata.actionability": new_actionability,
            "external_source.metadata.resolution": new_resolution,
            "external_source.metadata.classification_source": "override",
        }
        if is_terminal:
            # Terminal buckets force status_type=done at the metadata level
            # AND flip the top-level completed flag (NOT inside metadata).
            update_payload["external_source.metadata.status_type"] = "done"
            update_payload["completed"] = True
        batch.update(doc.reference, update_payload)
        count += 1
        pending += 1
        if pending >= _FIRESTORE_BATCH_LIMIT:
            batch.commit()
            batch = firestore_db.batch()
            pending = 0

    if pending > 0:
        batch.commit()

    logger.info(
        f"jira_status_classifier: applied status override uid={uid} cloudid={cloudid} "
        f"status={sanitize_pii(status_name)} bucket={bucket} "
        f"redis_written={redis_written} items_updated={count}"
    )
    return {"redis_written": redis_written, "items_updated": count}


def rewrite_actionability_in_place(
    uid: str,
    cloudid: str,
    status_name: str,
    new_actionability: Actionability,
) -> int:
    """Legacy 3-bucket wrapper around :func:`apply_status_override`.

    Preserved so the admin CLI (``scripts/jira_override_classification.py``)
    and pre-v2 tests keep working unchanged. The new 5-bucket UI calls
    ``apply_status_override`` directly.
    """
    result = apply_status_override(uid, cloudid, status_name, new_actionability)
    return int(result.get("items_updated", 0))
