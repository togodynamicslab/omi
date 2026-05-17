"""Admin override CLI for Jira status actionability classifications.

Writes a ``source=override`` entry to the Redis cache (wins forever) and
synchronously rewrites every existing action item matching the
(cloudid, status_name) pair so the next brief reflects the override
immediately. No Jira API call is made.

Usage:
    python scripts/jira_override_classification.py \\
        --uid <UID> \\
        --cloudid <ATLASSIAN_CLOUDID> \\
        --status-name "In Review" \\
        --actionability waiting

Notes:
- ``--status-name`` is the human Jira status label (matched verbatim against
  ``external_source.metadata.status``). It also gets slugified into the Redis
  cache key (same rule the classifier uses), so casing / punctuation differences
  collapse to the same entry.
- ``--actionability`` must be one of ``self`` / ``waiting`` / ``blocked``.
- The cached override entry uses ``status_category="indeterminate"`` because
  overrides intentionally bypass the rename-detection re-classify branch; the
  classifier returns the override regardless of the live status_category.

Cross-reference: design doc "Override-Triggered Resync Mechanism".
"""

from __future__ import annotations

import argparse
import logging
import sys
from datetime import datetime, timezone

from database.redis_db import r as redis_client
from utils.integrations import jira_status_classifier

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("jira_override_classification")

_ALLOWED_ACTIONABILITY = {"self", "waiting", "blocked"}


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _write_override_cache_entry(cloudid: str, status_name: str, actionability: str) -> str:
    """Persist the override directly into the per-status Redis cache.

    Returns the Redis key that was written so the caller can log it.
    """
    key = jira_status_classifier._status_cache_key(cloudid, status_name)
    cached = jira_status_classifier.CachedClassification(
        actionability=actionability,
        certainty="high",
        source="override",
        classified_at=_now_iso(),
        # Overrides bypass the rename-detection re-classify branch — we lose
        # the live status_category context (admin CLI does not query Jira),
        # but cached overrides are returned regardless of category drift.
        status_category="indeterminate",
    )
    redis_client.set(key, cached.model_dump_json())
    return key


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Override the LLM-classified actionability for a Jira status on a "
            "specific user+site. Writes a source=override entry to Redis (wins "
            "forever) and in-place rewrites every existing action item matching "
            "this (cloudid, status_name) in Firestore. NO Jira API call."
        ),
    )
    parser.add_argument("--uid", required=True, help="Nooto user id whose Jira items to rewrite")
    parser.add_argument(
        "--cloudid", required=True, help="Atlassian site cloudid (matches external_source.metadata.cloudid)"
    )
    parser.add_argument(
        "--status-name",
        required=True,
        help='Exact Jira status label to override, e.g. "In Review"',
    )
    parser.add_argument(
        "--actionability",
        required=True,
        choices=sorted(_ALLOWED_ACTIONABILITY),
        help="Override target bucket (self / waiting / blocked)",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)

    uid = args.uid.strip()
    cloudid = args.cloudid.strip()
    status_name = args.status_name.strip()
    actionability = args.actionability.strip()

    if not uid:
        print("ERROR: --uid must not be empty", file=sys.stderr)
        return 2
    if not cloudid:
        print("ERROR: --cloudid must not be empty", file=sys.stderr)
        return 2
    if not status_name:
        print("ERROR: --status-name must not be empty", file=sys.stderr)
        return 2
    if actionability not in _ALLOWED_ACTIONABILITY:
        print(f"ERROR: --actionability must be one of {sorted(_ALLOWED_ACTIONABILITY)}", file=sys.stderr)
        return 2

    key = _write_override_cache_entry(cloudid, status_name, actionability)
    logger.info("Wrote override cache entry key=%s actionability=%s", key, actionability)

    count = jira_status_classifier.rewrite_actionability_in_place(
        uid=uid,
        cloudid=cloudid,
        status_name=status_name,
        new_actionability=actionability,
    )
    print(f"Override written. Rewrote {count} action items.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
