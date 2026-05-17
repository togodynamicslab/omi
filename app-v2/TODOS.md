# TODOS — app-v2

Deferred work captured during planning. Add to a sprint when picking up.

## Promote on-device intent dispatcher into app-v2 once PoC clears accuracy bar

**What:** After the `app-v2/native-poc/{ios,android}/` PoC ships and reports ≥18/20 parses on both platforms, expose the parser+dispatcher as Flutter method channels and surface one entry point in the real Nooto UI (Companion Stream tab, e.g., a quick-action chip "set an alarm…").

**Why:** The PoC is sandboxed to prove the on-device LLM → JSON → system action chain works. Promotion is the path from "we proved it" to "Nooto users can use it." Without this TODO it's easy to leave the PoC dogfooded by Matheus only and never close the loop.

**Pros:**
- Validates the "Nooto as composer of on-device capabilities" thesis in the real product.
- Reuses the parsed-intent contract — promotion is a wiring exercise, not a re-design.
- Closes the founder-only feedback loop flagged in the design doc.

**Cons:**
- Method-channel marshaling adds latency (~10–30ms per round trip — should still leave warm latency under 700ms total).
- Once promoted, the parser is on the dogfood path and changes to it have to clear the regular app-v2 review bar.
- Hand-rolled bindings (Foundation Models, MediaPipe) per platform need a CI/CD story before the integration ships in a release.

**Context:** Surfaced during `/plan-eng-review` of the PoC design (2026-05-16). Full design doc at `~/.gstack/projects/togodynamicslab-omi/matheusoliviera-main-design-poc-on-device-intent-20260516-003859.md`. The PoC's "Next Steps" section lists five other follow-ups (grammar-constrained decoding, LoRA fine-tune, BLE wearable bridge, cloud fallback for unknown, speech input) — those stay in the design doc, not here, because they're improvements to the PoC itself, not the app-v2 integration.

**Depends on:** PoC reports ≥18/20 accuracy AND median warm latency <800ms on both iOS and Android. Recommend handing the PoC to at least one non-Matheus user before promotion (the design doc's Assignment).

## Bound `home.actions.v1` retention to 90 days

**What:** On `main()` boot, compact the `home.actions.v1` Hive box by deleting rows whose `ts` is older than 90 days.

**Why:** The action log accumulates a row per dismiss / snooze / tap-through / open / accept. Over months of dogfood, thousands of rows. Unbounded local growth has no functional value beyond ~30–60 days; older rows aren't read by any generator's dedup check.

**Pros:**
- Keeps Hive open-box latency bounded at cold start.
- Trivial implementation (~5 lines): iterate keys, delete where `now - ts > 90d`.
- Invisible to the user.

**Cons:**
- Tiny scope creep on whichever sprint picks it up.
- Loses ability to do retention analytics from prior 90+ days (but no current analysis depends on that).

**Context:** Surfaced during `/plan-eng-review` of the Companion Stream Home design (2026-04-30). The full design doc is at `~/.gstack/projects/togodynamicslab-omi/matheusoliviera-main-design-20260430-111632.md` — see "Performance notes" section.

**Depends on:** Sprint 0 having shipped (`home.actions.v1` Hive box must exist). After that, do anytime.

## Bound chat session message retention (per-session cap)

**What:** Replace the existing global `ChatBoxes.retentionLimit` cap in `ChatProvider._trim()` with a per-session cap (e.g., last 200 messages per session). After each message is added to a session, trim that session's list to the cap.

**Why:** Today the cap is global across all messages. With chat sessions landing, one chatty session can push out messages from other sessions. Result: user opens an older session and finds the start of the conversation gone, even though they only ever exchanged 50 messages there.

**Pros:**
- Each session preserves its own history independent of activity in other sessions.
- Same family of fix as `home.actions.v1` retention TODO — bounded local growth.
- Simple change (~15 min): `_trim(sessionId)` after each per-session insert.

**Cons:**
- Power users with one very long session would lose old messages there earlier than under the global cap.
- Still doesn't bound total session count (separate concern).

**Context:** Surfaced during `/plan-eng-review` of the chat-sessions design (2026-05-01). Full design doc at `~/.gstack/projects/togodynamicslab-omi/matheusoliviera-main-design-chat-sessions-20260501-093400.md` — see Performance Review issue 4.1.

**Depends on:** Chat sessions PR shipping first (`chat.sessions.v1` box and per-session message map must exist).

## Expose backend session_id on /v2/messages for true multi-session

**What:** In `backend/routers/chat.py`, accept an optional `session_id` query param on POST `/v2/messages`, GET `/v2/messages`, and DELETE `/v2/messages`. Overload `chat_db.acquire_chat_session` to either find a specific session by id or fall back to the current `(uid, app_id)` lookup. `backend/database/chat.py:get_chat_session_by_id` already exists — wire it as the primary lookup when session_id is supplied.

**Why:** Currently the backend has exactly one `ChatSession` per `(uid, app_id)`. App-v2's chat-sessions v0 ships client-side sessions on top, but the backend LLM still sees all messages for that user — server-side memory bleeds across what the user thinks are separate chats. ChatGPT parity needs server-side isolation.

**Pros:**
- True isolation: each chat thread has its own LLM context, no memory bleed between threads.
- Unblocks cross-device session sync (the same session_id works on iPhone + desktop-v2).
- Backend `ChatSession` model already exists (`backend/models/chat.py:204`) — much smaller change than originally estimated (~1 day, not 2-3).

**Cons:**
- Touches the chat router that desktop-v2 and the legacy app share — needs careful regression testing.
- Schema change on the `messages` and `chat_sessions` Firestore collections (backfill old messages with a default session_id).
- Mobile + desktop clients both need to pass session_id on every send after rollout.

**Context:** Surfaced during `/plan-eng-review` of chat-sessions design (2026-05-01). The original design doc premise stated "backend doesn't have session_id concept" — that was wrong; backend has a 1:1 `(uid, app_id)` → session model. This TODO is the v0.1 follow-up to make it n:1 per user.

**Depends on:** App-v2 chat-sessions v0 shipping first (so we have a real surface that exercises the backend change).

## Search across chat sessions

**What:** Add a search input to the top of the chat sessions drawer (`ChatSessionsDrawer`). Filter sessions by title + first user message text. Best implemented after the backend `session_id` work lands so the search hits the server's full session history rather than just local Hive cache.

**Why:** Once a user has 10+ chat sessions, scrolling Today / Yesterday / This Week / Older buckets to find "where did I ask about X?" gets tedious. Search is one of ChatGPT's most-used features.

**Pros:**
- Power-user feature that compounds value as the session count grows.
- Building once over the cross-device backend session_id substrate is the right move (avoids throwaway local-only search code).
- Small UI: search input in drawer header, filter logic in `ChatSessionsProvider` (or equivalent).

**Cons:**
- Until backend session_id ships, search would only see local sessions on the current device — incomplete answer for a cross-device user.
- Adds one more failure mode (search returns 0 results — needs empty state).

**Context:** Surfaced during `/plan-ceo-review` of chat-sessions design (2026-05-01, SELECTIVE EXPANSION mode). Considered for v0 inclusion and explicitly deferred — see CEO plan at `~/.gstack/projects/togodynamicslab-omi/ceo-plans/2026-05-01-chat-sessions.md` for the deferral reasoning.

**Depends on:** Backend session_id TODO (above) shipping first — search becomes meaningful once session history is cross-device.

## Pendant orb as global brand element (Approach C)

**What:** After 2-4 weeks of v0 dogfood on the constellation ceremony, extract the `PendantOrb` widget into a reusable `NootoOrb` and thread it through `StatusPill` (paired states show a 12pt orb instead of the colored dot), the chat composer mic indicator (orb-as-mic, replacing the static icon), and the welcome voice card background (faint ambient orb visible on first paint). The pendant ceremony becomes the orb's *birth*; thereafter it's the "this app is alive" signal across the product.

**Why:** Pays off the constellation ceremony 4x across surfaces. The orb becomes Nooto's distinctive visual signature, not just a one-screen moment. Every surface reminds the user the relationship exists.

**Pros:**
- Most distinctive single product moment in v2 if it lands cleanly.
- Cross-surface coherence — the chief-of-staff thesis gets a visual through-line.
- The orb identity is already proven by the time we extract (post-dogfood).

**Cons:**
- Blast radius across 4-5 surfaces locked in earlier lanes (StatusPill in Lane B, ChatComposer in Lane C, WelcomeCard in Lane A).
- Re-fights design battles in surfaces that just shipped (e.g., "no decorative motion in chat composer").
- XL effort estimate (human ~4-5 days / CC ~3 hours).

**Context:** Discussed and explicitly deferred in `/office-hours` D7 (2026-05-04). Approach B (pendant-screen-only) was chosen as the v0 scope. See design doc `matheusoliviera-main-design-pendant-magic-moment-20260504-124235.md` for the full reasoning.

**Depends on:** v0 ships AND gets 2-4 weeks of dogfood that confirms the orb identity feels right. Do not start before then.

## Pendant LED firmware sync for ceremony Found-beat

**What:** Add a write characteristic to the Omi pendant firmware so the screen ceremony's "Found you." beat can flash the pendant LED (single soft pulse) at the same moment the screen brightens a particle and fires the haptic. Three-way choreography: hardware LED + screen + haptic.

**Why:** Closes the physical-digital loop — the user feels (haptic), sees (screen), and watches the pendant itself participate (LED) in its own pairing recognition moment. Few products achieve hardware-screen-haptic synchrony.

**Pros:**
- Maximum brand moment; the pendant participates in its own celebration.
- Differentiates Nooto from any pendant pairing UX in market.

**Cons:**
- Requires firmware change in a separately-governed codebase.
- BLE write characteristic needs definition + spec.
- BLE round-trip latency (tens of ms) makes timing sync non-trivial — may not feel "instant."

**Context:** Surfaced as Open Question 1 in design doc `matheusoliviera-main-design-pendant-magic-moment-20260504-124235.md`. Out of scope for the v0 screen-only PR.

**Depends on:** Firmware team capacity + agreement on BLE protocol extension. Not blocking v0.

## Programmatic CI frame-rate test for motion paths

**What:** When app-v2 lands a SECOND non-trivial motion path beyond the constellation ceremony, add a programmatic frame-timing CI test using `WidgetsBinding.addTimingsCallback` that drives all motion paths through their full lifecycle and asserts no frame > 18ms (55fps).

**Why:** Today the constellation is the only motion path and manual DevTools verification suffices. Once there are 2+ motion paths (e.g., Approach C lands and the orb is animating across 4 surfaces), eyeball-only doesn't scale — regressions slip in silently between PRs.

**Pros:**
- Catches motion regressions at PR-time, not dogfood-time.
- Compounds across all future motion work — every new motion path inherits the safety net.
- No human required — automatic CI signal.

**Cons:**
- Flaky on slow CI runners; may need to widen the threshold (e.g., 33ms = 30fps), which dilutes the signal.
- Adds CI test infrastructure to maintain.

**Context:** Surfaced as PERF-1 Option B during `/plan-eng-review` of the pendant-magic-moment design (2026-05-04). Currently rejected as over-engineered for one motion path; tracked here for the trigger event.

**Depends on:** Existence of a second non-trivial motion path in app-v2 (likely Approach C — see "Pendant orb as global brand element" TODO above). Not actionable until then.

## App-v2 Hive↔server chat sync strategy

**What:** Decide how app-v2's local Hive chat (`chat.sessions.v1`, `chat.messages.v1`) reconciles with backend server-of-record chat sessions for per-app threads + replies. Net-new infra; no transport exists today (REST only, no listener / WS / SSE).

**Why:** Notifications-as-Chat v0 sidesteps this by making Inbox a live view (no Hive caching). v1 work that needs persistent per-app conversation history (replies to plugins, multi-device read-state sync, offline read of past Inbox messages) requires a real sync strategy. Without one captured, v1 starts by re-discovering the problem and may force re-architecture under deadline pressure.

**Pros:**
- Unblocks all v1+ chat features that need server-of-record persistence (plugin replies, multi-device sync, archive search).
- Forces an explicit transport choice (Firestore listener / WebSocket / SSE / poll) once, not piecemeal per feature.

**Cons:**
- Real architectural work — likely 1–2 week scope of its own.
- May reveal that backend `/v2/messages` needs surface changes (today it doesn't accept session_id from client).

**Context:** Surfaced during `/plan-eng-review` of the notifications-as-chat design (2026-05-06). Design doc at `~/.gstack/projects/togodynamicslab-omi/matheusoliviera-main-design-notifications-as-chat-20260506-010606.md` — see Open Questions item 7 and v1 backlog. Per learning `app-v2-chat-is-hive-local`: app-v2 chat is Hive-local; backend `/v2/messages` doesn't accept client session_id.

**Depends on:** Completion of notifications-as-chat v0 (to validate the Inbox-bypass-Hive shape works for read-only flows). Triggered when v1 work begins on plugin replies, per-app drill-down with persistence, or multi-device read sync.

## Inbox sender cache: switch from in-process LRU to cross-pod Redis

**What:** Replace the ad-hoc 60s in-process LRU in `backend/utils/inbox_senders.py` (`_CACHE`, `_LOCK`, `_cache_get`, `_cache_put`, `_MAX_ENTRIES`) with the existing `database.redis_db.get_app_cache_by_id` / `set_app_cache_by_id` helpers, or with `database.cache.get_memory_cache().get_or_fetch(key, fn, ttl)`.

**Why:** Every backend pod currently warms its own copy of the apps catalog while Redis already caches it cross-pod via the `apps:{app_id}` key. The existing helpers also have a `delete_app_cache_by_id` invalidation hook on app updates that the inbox sender path bypasses today — meaning a renamed app keeps its old display name in Inbox feed responses for up to 60s per pod.

**Pros:**
- Cross-pod cache consistency (one warm copy, not N).
- Free invalidation when apps are updated.
- Removes ~30 LOC of bespoke cache bookkeeping.

**Cons:**
- Introduces a Redis dependency at the inbox feed hot path (already present everywhere else in backend).
- Test isolation argument that justified the standalone module needs a stub for Redis (similar to existing patterns in `utils/apps.py` test paths).

**Context:** Surfaced during `/simplify` review of the notifications-as-chat feature (2026-05-06). Three reviewers independently flagged the duplication. The standalone module was deliberate (test isolation per the agent's deviation note) but the rationale is fixable with stubs rather than a forked resolution path. Defer until the feature has shipped and the audit-gated rate-limit + default flip have landed — replacing the cache during initial dogfood would conflate two changes.

**Depends on:** Notifications-as-chat v0 in production for ~1 week to confirm the existing module works end-to-end before refactoring.

## AppColors.borderSubtle token + replace `Colors.white.withValues(alpha: 0.06)` literals

**What:** Add `AppColors.borderSubtle` token (value: `Color(0x0FFFFFFF)`, equivalent to `Colors.white.withValues(alpha: 0.06)`) to `app-v2/lib/theme/app_theme.dart`. Replace existing literals in `chat_sessions_drawer.dart`, `chat_screen.dart`, `inbox_screen.dart` with the token. Update DESIGN.md to document the token.

**Why:** DESIGN.md prescribes this exact alpha for surface-card and divider chrome ("Borders at `Colors.white.withValues(alpha: 0.06)` are the most chrome we add"). The literal is repeated across 5+ files. CLAUDE.md forbids hardcoded `Color(0xXX...)` literals — a token is the project convention.

**Pros:**
- One source of truth for the subtle border treatment.
- DESIGN.md and code stay aligned.
- Zero behavior change (same alpha).

**Cons:**
- Touches multiple files (chat_sessions_drawer, chat_screen, inbox_screen, possibly more).
- Pure cosmetic / convention compliance — no user-visible impact.

**Context:** Surfaced during `/simplify` review of the notifications-as-chat feature (2026-05-06). Pre-existing duplication that Lane C extended rather than introduced. Out of scope for the inbox feature ship; reasonable to bundle with any future theme-token cleanup.

**Depends on:** None. Trivially actionable any time.

## Jira sync N+1: per-task `_find_by_external_source` round-trip

**What:** Replace the per-task Firestore round-trip in `backend/utils/integrations/jira_sync.py:262` with a batch read. Collect all `ext_id`s for the page, run a single `where("external_source.external_id", "in", ext_ids)` query (Firestore `in` accepts up to 30 values; chunk if needed), then iterate in memory.

**Why:** Today the sync loop reads Firestore once per Jira task to deep-merge metadata. For a power user with 200+ issues, that's 200+ sequential round-trips per sync cycle. Compounds the LLM batch classify added in the Jira terminal-states design (2026-05-17) — even with the classify batched, the Firestore reads dominate latency.

**Pros:**
- ~10-100x faster sync for users with many issues.
- Standard Firestore `in` query, no new index needed.
- Reduces sync-now latency that the freshness design (2026-05-07) is also trying to optimize.

**Cons:**
- `in` query maxes at 30 values per call — needs chunking for >30 issues per page.
- Subtle: the deep-merge currently relies on per-doc snapshot; moving to a batch means holding all priors in memory briefly. Trivial for hundreds of items.

**Context:** Pre-existing N+1 flagged during plan-eng-review of the Jira terminal-states design (2026-05-17). Not introduced by that design; carved out as a separate perf pass to avoid scope creep. Bundle with the next Jira sync work.

**Depends on:** None. Independent of the terminal-states design landing.

## Jira terminal-states v2 — Settings → Apps → Jira "Status meanings" subsection

**What:** Add a per-app Settings subsection in `app-v2/lib/apps/app_detail_screen.dart` (or a new `JiraSettingsScreen` route) listing every classified Jira status for the user's site with the LLM's guess and a one-tap override (`Actively working` / `Waiting on others` / `Blocked`). Low-certainty classifications get a "Tap to confirm" badge. Override writes call `POST /v1/integrations/jira/status-overrides` (new endpoint), which triggers `rewrite_actionability_in_place` backend-side.

**Why:** v1 of the Jira terminal-states design (2026-05-17) ships with an admin-CLI override only because dogfood is single-user. v2 makes the override self-serve so the LLM's 70-80% accuracy can be corrected by every user without a backend deploy. Until this lands, default-on rollout to all users is gated by the calibration criterion (≥85% LLM match on a 50-status fixture).

**Pros:**
- Unblocks default-on rollout to all Nooto users with Jira installed.
- Establishes a reusable "integration settings subsection" pattern that Linear, GitHub, Notion can adopt for their semantic-layer quirks.
- Closes the trust loop: users see the LLM's guess and correct it inline, no support escalation needed.

**Cons:**
- ~1.5-2 days net-new UI work (provider + API client + list/picker widget + override mutation). AppDetailScreen has no per-app subsection slot today.
- Adds a Settings surface users have to discover.

**Context:** v1 deferred this explicitly to dogfood the LLM accuracy first. See "Deferred to v2" section in the design doc. Plan once Days 4-10 dogfood data lands and we know the LLM accuracy gap on real workflows.

**Depends on:** Jira terminal-states v1 (2026-05-17 design) shipped and ≥1 week of dogfood log data showing the LLM accuracy distribution.

## Jira terminal-states default-on calibration gate

**What:** Before flipping the Jira terminal-states classification to default-on for all Nooto users (post v2 Settings UI), produce a 50-status hand-labeled fixture (Matheus' real workflow statuses + 3-5 other Nooto users' workflows if available) and measure gpt-4.1-mini classification accuracy against it. Require ≥85% match before flag flip.

**Why:** v1 success criterion is "eyeball logs for a week" — fine for single-user dogfood, not rigorous enough for an all-users default-on. Outside-voice reviewer flagged this as a calibration gap (2026-05-17). Without a baseline, "the LLM gets it right most of the time" is not measurable.

**Pros:**
- Quantifies the LLM accuracy gap with numbers, not vibes.
- Surfaces specific status names where the LLM consistently mis-classifies, which informs system-prompt tuning.
- Standard ML evaluation pattern; reusable for Linear / GitHub / Notion when their classifiers ship.

**Cons:**
- Takes 1-2 hours to build the fixture (real status names + ground-truth labels from 1-3 users).
- Needs to be re-run each time the system prompt or model changes.

**Context:** Surfaced during plan-eng-review of the Jira terminal-states design (2026-05-17). Outside-voice review noted "you will hit ~70% and have no calibration signal to know whether to ship." This TODO closes that loop.

**Depends on:** Jira terminal-states v2 Settings UI landing (so users can override misclassifications self-serve before any default-on rollout).
