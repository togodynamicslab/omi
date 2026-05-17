/// One row of `GET /v1/integrations/jira/status-classifications`.
///
/// Mirrors the backend payload field-for-field. Nulls are kept as nulls (not
/// coerced to enums) because "unclassified" is a meaningful display state
/// distinct from any bucket — the UI renders an outlined "Unclassified" chip
/// for [bucket] == null instead of falling back to a default bucket.
class JiraStatusClassification {
  const JiraStatusClassification({
    required this.cloudid,
    required this.statusName,
    this.statusCategory,
    this.bucket,
    this.actionability,
    this.resolution,
    this.source,
    this.certainty,
    this.classifiedAt,
    this.matchingItemCount = 0,
  });

  /// Atlassian cloud id the status belongs to. Required for the override POST
  /// body because the same `status_name` can appear under multiple clouds with
  /// different meanings.
  final String cloudid;

  /// Raw Jira status name (e.g. "In Progress", "Code Review", "Awaiting QA").
  final String statusName;

  /// Jira's own grouping ("To Do" / "In Progress" / "Done"). Display-only —
  /// we don't use it to derive bucket because cross-instance conventions
  /// diverge wildly.
  final String? statusCategory;

  /// Our actionability bucket: self | waiting | blocked | completed | dropped.
  /// Null means the LLM hasn't classified yet (or classification was wiped).
  /// Source of truth for Plan filtering on the backend.
  final String? bucket;

  /// Free-form LLM annotation (e.g. "user is the next actor"). Display-only.
  final String? actionability;

  /// Jira resolution string when [bucket] is "completed" or "dropped".
  /// Display-only.
  final String? resolution;

  /// How the bucket was assigned: llm | override | seed | fallback. Drives
  /// the row subtitle ("LLM-classified" / "You overrode" / "Default").
  final String? source;

  /// LLM self-reported confidence: high | medium | low. Drives the "needs
  /// your review" hint in the row subtitle when low.
  final String? certainty;

  /// ISO-8601 timestamp of the last classification. Kept opaque (string) — no
  /// UI today renders it, but plumbing it through lets a future "Last
  /// classified N min ago" caption land without a model bump.
  final String? classifiedAt;

  /// How many items in the user's Plan currently match this status. Drives
  /// the "N items" prefix in the row subtitle and the list sort order
  /// (descending — high-impact statuses surface first).
  final int matchingItemCount;

  /// Returns a copy with [bucket] and [source] replaced. Used by the provider
  /// to optimistically reflect a manual override (source becomes "override")
  /// without waiting for a re-fetch.
  JiraStatusClassification copyWith({String? bucket, String? source}) {
    return JiraStatusClassification(
      cloudid: cloudid,
      statusName: statusName,
      statusCategory: statusCategory,
      bucket: bucket ?? this.bucket,
      actionability: actionability,
      resolution: resolution,
      source: source ?? this.source,
      certainty: certainty,
      classifiedAt: classifiedAt,
      matchingItemCount: matchingItemCount,
    );
  }

  /// Parses a single row from the backend `items[]` array. Defensive against
  /// missing/typed-wrong fields — anything except [cloudid] and [statusName]
  /// is optional. `matching_item_count` collapses to 0 when absent so the
  /// row still renders.
  factory JiraStatusClassification.fromJson(Map<String, dynamic> json) {
    final raw = json['matching_item_count'];
    final count = raw is int
        ? raw
        : raw is num
        ? raw.toInt()
        : 0;
    return JiraStatusClassification(
      cloudid: (json['cloudid'] ?? '').toString(),
      statusName: (json['status_name'] ?? '').toString(),
      statusCategory: json['status_category'] as String?,
      bucket: json['bucket'] as String?,
      actionability: json['actionability'] as String?,
      resolution: json['resolution'] as String?,
      source: json['source'] as String?,
      certainty: json['certainty'] as String?,
      classifiedAt: json['classified_at'] as String?,
      matchingItemCount: count,
    );
  }
}
