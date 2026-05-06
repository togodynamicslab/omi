/// Inline-tag parser for the morning brief.
///
/// The brief LLM is instructed to embed self-closing tags like
/// `<ticket id="WPNG-3417"/>`, `<person id="..."/>`, and
/// `<conversation id="..."/>` mid-sentence whenever it references an item
/// from its grounded context. This file turns the raw body string into an
/// ordered stream of [BriefSegment]s the renderer maps to text spans and
/// inline chip widgets.
///
/// The brief body arrives as a single complete string (see
/// `ChatService.fetchBrief` in `services/chat_service.dart`), so the parser
/// never sees partial tags. If that ever changes, an unterminated `<ticket`
/// will simply pass through as plain text — the parser only converts a tag
/// to a [BriefSegment.ref] once it sees the closing `/>`.
library;

import 'package:nooto_v2/library/conversation_model.dart';

/// Tag name as it appears in the wire format. Mirrors [Enum.name] for the
/// four known kinds; we route through a getter so callers don't depend on
/// `Enum.name` semantics if the enum ever needs renaming.
///
/// `plan` references action items (overdue tasks, due-soon items) by their
/// internal `ActionItem.id`. Tapping a plan chip jumps to the Plan tab and
/// scrolls the item into view (see `BriefRichBody._resolveRef`).
enum BriefRefKind {
  ticket,
  person,
  conversation,
  plan;

  String get tagName => name;
}

/// Stable id for a person referenced inline. The brief prompt and the
/// renderer both run this on the speaker name so the LLM-emitted
/// `<person id="..."/>` resolves against the same key the renderer
/// computed at build time. Lower-case, single-spaced.
String personIdFor(String displayName) {
  return displayName.trim().toLowerCase().split(RegExp(r'\s+')).join(' ');
}

/// One non-user speaker pulled from a conversation's transcript segments,
/// already deduplicated within the conversation. Used by both the prompt
/// builder (people context) and the renderer (people index).
class BriefSpeaker {
  const BriefSpeaker({required this.id, required this.displayName});
  final String id;
  final String displayName;
}

/// Yields each non-user speaker that appears at least once in the
/// conversation's transcript, in first-seen order. Same id derivation as
/// [personIdFor] so the LLM-emitted `<person id="..."/>` resolves against
/// these speakers at render time.
Iterable<BriefSpeaker> briefSpeakersIn(ConversationItem conv) sync* {
  final segs = conv.raw['transcript_segments'];
  if (segs is! List) return;
  final seen = <String>{};
  for (final s in segs) {
    if (s is! Map) continue;
    if (s['is_user'] == true) continue;
    final name = s['speaker'];
    if (name is! String) continue;
    final trimmed = name.trim();
    if (trimmed.isEmpty) continue;
    final id = personIdFor(trimmed);
    if (id.isEmpty) continue;
    if (!seen.add(id)) continue;
    yield BriefSpeaker(id: id, displayName: trimmed);
  }
}

/// One piece of the parsed brief body — literal text, a reference the
/// renderer chips, or an emphasized run the renderer paints with
/// `brandEmphasis()` (sans-serif weight 600 + −0.2 letter spacing).
sealed class BriefSegment {
  const BriefSegment();

  const factory BriefSegment.text(String value) = BriefTextSegment;
  const factory BriefSegment.ref(BriefRefKind kind, String id) = BriefRefSegment;
  const factory BriefSegment.emphasis(String value) = BriefEmphasisSegment;
}

class BriefTextSegment extends BriefSegment {
  const BriefTextSegment(this.value);
  final String value;
}

class BriefRefSegment extends BriefSegment {
  const BriefRefSegment(this.kind, this.id, {this.title});
  final BriefRefKind kind;
  final String id;

  /// LLM-supplied human-readable title carried on the tag as
  /// `<plan id="..." title="..."/>`. Used by the renderer as graceful
  /// fallback text when the id can't be resolved against currently-loaded
  /// providers (stale refs after the user completes / dismisses an item
  /// between brief generation and render). Null on legacy tags without the
  /// attribute — those fall back to literal-tag rendering.
  final String? title;
}

/// Run between `<em>` and `</em>`. Renderer paints with brand-emphasis style
/// so the assistant can put weight on a focal phrase ("the most overdue
/// item", "blocking Friday's social plan") inline. By contract the run does
/// NOT contain chip tags — the LLM emits emphasis OR a chip, not both
/// nested. Lets the parser stay regex-driven without a real grammar.
class BriefEmphasisSegment extends BriefSegment {
  const BriefEmphasisSegment(this.value);
  final String value;
}

/// Matches one of:
///   * `<kind id="value"/>` or `<kind id="..." title="..."/>` (self-closing
///     chip tag — `kind` restricted to four known names)
///   * `<em>...</em>` (paired emphasis tag — non-greedy inner match)
///
/// Single regex with alternation so `parseBriefBody` walks the body once and
/// gets segments in source order. `kind` allowlisting keeps a stray `<br/>`
/// or `<i>...</i>` from getting reinterpreted.
final RegExp _tagPattern = RegExp(
  r'<\s*(ticket|person|conversation|plan)\s+id\s*=\s*"([^"]+)"(?:\s+title\s*=\s*"([^"]*)")?\s*/\s*>'
  r'|<em>(.*?)</em>',
  dotAll: true,
);

/// Parses [body] into an ordered list of segments. Plain runs collapse into
/// a single [BriefTextSegment] each; chip tags become [BriefRefSegment]s;
/// `<em>...</em>` ranges become [BriefEmphasisSegment]s. Empty input returns
/// an empty list. The string is preserved character-for-character outside of
/// recognized tags — no whitespace normalization, no HTML entity decoding.
List<BriefSegment> parseBriefBody(String body) {
  if (body.isEmpty) return const [];
  final segments = <BriefSegment>[];
  var cursor = 0;
  for (final match in _tagPattern.allMatches(body)) {
    if (match.start > cursor) {
      segments.add(BriefSegment.text(body.substring(cursor, match.start)));
    }
    final kindRaw = match.group(1);
    if (kindRaw != null) {
      final kind = _kindFor(kindRaw);
      final id = match.group(2)!;
      // groupCount guards against Flutter hot-reload leaving the old compiled
      // RegExp in memory (top-level `final` initializers don't re-run on hot
      // reload) — without this the title-aware parser would crash with
      // RangeError when reading group 3 from a 2-group regex.
      final title = match.groupCount >= 3 ? match.group(3) : null;
      if (kind != null && id.isNotEmpty) {
        segments.add(BriefRefSegment(kind, id, title: (title?.isEmpty ?? true) ? null : title));
      } else {
        segments.add(BriefSegment.text(match.group(0)!));
      }
    } else {
      // Emphasis branch (group 4). Empty `<em></em>` falls through as text
      // so the literal tag pair is visible in dogfood logs.
      final emValue = match.groupCount >= 4 ? match.group(4) : null;
      if (emValue != null && emValue.isNotEmpty) {
        segments.add(BriefSegment.emphasis(emValue));
      } else {
        segments.add(BriefSegment.text(match.group(0)!));
      }
    }
    cursor = match.end;
  }
  if (cursor < body.length) {
    segments.add(BriefSegment.text(body.substring(cursor)));
  }
  return segments;
}

BriefRefKind? _kindFor(String raw) {
  switch (raw) {
    case 'ticket':
      return BriefRefKind.ticket;
    case 'person':
      return BriefRefKind.person;
    case 'conversation':
      return BriefRefKind.conversation;
    case 'plan':
      return BriefRefKind.plan;
  }
  return null;
}
