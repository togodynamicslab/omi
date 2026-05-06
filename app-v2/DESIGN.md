# Design System — Nooto v2

> Anchor: **Apple Human Interface Guidelines** (iOS), adapted where the product
> thesis demands. Existing tokens live in `lib/theme/app_theme.dart`; this file
> is the source of truth for *why* they are what they are.

## Product Context

- **What this is:** Nooto v2 — a proactive AI companion mobile app, pendant-first, with a Companion Stream Home (assistant-generated cards, not a transcripts dashboard).
- **Who it's for:** Pre-launch, founder-as-user (Matheus). Validation loop is dogfood, not external research.
- **Space:** AI personal assistant / "chief of staff" category. Direct peers: Omi (upstream fork), Limitless. Adjacent: Notion AI, Granola, Reflect.
- **Project type:** Flutter mobile app, iOS-primary (Android works but iOS is the polish target).
- **Posture:** Looks and feels like a serious native iOS app. Not a Flutter cross-platform compromise. HIG fluency is non-negotiable; departures are intentional and documented.

## Aesthetic Direction

- **Direction:** **Brutally minimal with one expressive accent.** Typography and whitespace do the work. Brand blue + serif italic is the only "voice" the system raises.
- **Decoration level:** **Minimal.** No gradients, no decorative blobs, no shadows beyond what HIG uses for elevation. Borders at `Colors.white.withValues(alpha: 0.06)` are the most chrome we add.
- **Mood:** Calm, intelligent, deliberate. The product should feel like it knows you, not like it's selling itself to you.
- **Memorable thing:** A serious iOS app that happens to be an AI companion — not an AI app that happens to run on iOS. The HIG fluency IS the trust signal.

## Apple HIG Alignment (where we comply)

| HIG principle | Where we honor it |
|---|---|
| Minimum 44pt touch target | `AppStyles.touchTargetMinimum = 44.0`; `HeaderIconButton`, `_ActionButton`, `_SeeAllRow` all enforce |
| Standard nav bar height (44pt) | `ShellScreen` AppBar uses Material default |
| Tab bar 49pt + safe area | `ShellTabBar` computes `MediaQuery.padding.bottom` dynamically |
| Body text ≥ 16pt, button labels ≥ 14pt | Theme `bodyLarge: 16`, `labelLarge: 14`; never go below in interactive elements |
| Native dark mode (true blacks + elevation tower) | 4-step neutral tower `#0F0F0F → #2A2A2A`; surfaces lift, not invert |
| Off-white for body text in dark (~`#E0`) | `textSecondary: #E5E5E5` |
| Native motion (ease-out enter, ease-in exit, 150-300ms) | `CardEntrance` uses 180ms `Curves.easeOut` |
| `prefers-reduced-motion` | Honored by Flutter's animation system; reduced-motion skips entrance |

## Intentional Departures from HIG

These are deliberate. Each serves the chief-of-staff thesis.

1. **Voice cards (welcome, morning brief) have NO chrome.** HIG would put them in a `UITableView` cell or grouped style. We render them as direct text on the screen background so they read as the assistant *speaking*, not as a tile in a dashboard. The contrast against the chromed Today surface card creates the speaking-vs-list grammar the product depends on.
2. **Chat-pattern Home (composer docked at bottom).** HIG primary nav lives at top or via tab bar. We keep both AND add a chat composer pill at the bottom because "Ask Nooto anything" is a co-equal entry point, not a setting buried in a screen. The pill is a `GestureDetector`, not a `TextField`, so taps navigate immediately without keyboard-flash.
3. **One accent color, no segmentation by type.** HIG often differentiates with multiple tints (system blue for actions, system red for destructive, system green for confirmation). We use brand blue for both primary actions AND emphasis (eyebrow text, See all, Got it). Destructive uses a textTertiary X icon instead of red. The restraint means when red DOES appear, it means real failure.

## Typography

System sans-serif only. iOS gets SF Pro automatically, Android gets Roboto. No custom font face anywhere in the product.

| Role | Size | Weight | Used for |
|---|---|---|---|
| Brand emphasis (large) | 30-34pt | 700 | Welcome tagline emphasis, Home large title wordmark |
| Brand emphasis (compact) | 17-22pt | 600-700 | Voice card greeting, compact bar wordmark, hero one-liners |
| Display | 36pt | 600 | Reserved for hero screens (none on Home today) |
| Headline | 22pt | 600 | Section headers (rare; we lean on labelLarge instead) |
| Body large | 16pt | 400 | Card body text (welcome paragraph, brief body) |
| Body medium | 14pt | 400 | Bullets in Today card, secondary chrome |
| Label large | 14pt | 500 | Buttons, eyebrows, "See all", tab labels |
| Caption | 12pt | 400-600 | "Action item" eyebrow, relative time, source line |

Brand emphasis comes from **weight + size + letter-spacing**, never from a different typeface. The `brandEmphasis()` helper in `app_theme.dart` is the single allowed channel for emphasis text — it returns a system-font TextStyle with -0.2 letter-spacing.

**Why no custom font:** Apple licensing prevents shipping SF Pro in non-iOS builds. Loading a custom sans like Inter would fight HIG on iOS *and* introduce a font-loading flash. Custom serif (e.g. Playfair) was tried and explicitly rejected — too literary for the chief-of-staff role and out of step with the rest of the product surface.

**Allowed exception (added 2026-05-05): Source Serif 4 Regular as a single editorial accent face.** Reintroduced after 5 weeks of sans-only dogfood. Used via `brandAccent()` at exactly one site — the morning brief greeting line. Source Serif 4 is humanist, neutral, and expressly *not* cursive (which is why Playfair was rejected). Single weight (400 Regular), bundled at `assets/fonts/SourceSerif4-Regular.otf`, no italic. The accent earns its existence by appearing exactly once per screen.

**Hard blacklist — never reintroduce:**
- Playfair Display, Libre Caslon Display, or any *display-style* serif. Editorial gravity = good; literary affectation = rejected.
- Italic as a brand-emphasis lever. The accent works because it's restrained, not because it's tilted.
- Custom sans (Inter, Roboto, Poppins, Space Grotesk) as primary brand font.
- Cursive, handwritten, or decorative display faces.
- The previous `brandSerif()` helper (uses Playfair italic). Use `brandAccent()` for editorial accent and `brandEmphasis()` for sans-serif weight emphasis.
- Adding `brandAccent` to a second surface without a fresh design pass. Restraint = power; one surface keeps the accent meaningful.

## Color

**Approach:** Restrained. One accent + neutral tower + semantic.

### Neutrals (dark mode only)

| Token | Hex | Role |
|---|---|---|
| `backgroundPrimary` | `#0F0F0F` | Scaffold / screen background |
| `backgroundSecondary` | `#1A1A1A` | Surface cards (Today, action item chrome) |
| `backgroundTertiary` | `#252525` | Hover/pressed states, modal sheets |
| `backgroundQuaternary` | `#2A2A2A` | Highest elevation (rare) |

The 4-step tower follows HIG's "elevation by lightness" principle for dark mode. Distance between adjacent steps is 5-7% lightness — enough to register as different surfaces under fluorescent lighting and pendant glances.

### Text

| Token | Hex | Role | Contrast on `#0F0F0F` |
|---|---|---|---|
| `textPrimary` | `#FFFFFF` | Headings, primary body | 21:1 |
| `textSecondary` | `#E5E5E5` | Default body (HIG-aligned off-white) | 18:1 |
| `textTertiary` | `#B0B0B0` | Captions, eyebrows, dismiss icons | 9.5:1 |
| `textQuaternary` | `#888888` | Disabled, placeholders | 5.7:1 |

All four pass WCAG AA on the entire neutral tower. `textQuaternary` is the floor — never use for interactive labels.

### Brand

| Token | Hex | Role |
|---|---|---|
| `brandPrimary` | `#3B82F6` | Primary CTA, action item eyebrow, See all link, brief streaming caret |
| `brandAccent` | `#2563EB` | Pressed state of brandPrimary |
| `brandLight` | `#93C5FD` | Reserved (not used today) |

**Why this blue:** matches the landing site and `desktop-v2`. It's close enough to iOS system blue (`#007AFF`) that HIG-trained eyes don't reject it, but slightly cooler/desaturated to feel less stock. The brand consistency across mobile + desktop + web is a deliberate signal: same product, three surfaces, one company.

### Semantic

| Token | Hex | Role |
|---|---|---|
| `successColor` | `#10B981` | Confirmation states (rare today) |
| `warningColor` | `#F59E0B` | Caution / non-blocking warnings |
| `errorColor` | `#EF4444` | Real failures only — never used for routine destructive actions |

## Spacing

**Base unit:** 4pt. **Density:** comfortable (mid-density between iOS Mail and Notion).

| Token | Value | Usage |
|---|---|---|
| `spacingXS` | 4pt | Tight groupings (icon + label inside a row) |
| `spacingS` | 8pt | Adjacent UI elements that belong together |
| `spacingM` | 12pt | Between sub-elements within a card |
| `spacingL` | 16pt | Card padding, between top-level rows |
| `spacingXL` | 24pt | Between sections, AppBar to first card |
| `spacingXXL` | 32pt | Major section breaks |

The Home screen rhythm uses these as: `spacingXL` AppBar→first voice card, `spacingL` between voice and surface cards, `spacingL` between consecutive surface cards, `spacingXL` last card to composer, 8pt composer to safe-area inset.

## Layout

- **Approach:** Vertical stack with chat-pattern composer dock. Cards flow top-down by priority. No grid columns on mobile.
- **Card priority:** welcome (1000) > brief (750) > today (500). Higher = floats up.
- **Max content width:** N/A (single-column mobile). Tablet/iPad treatment is deferred.
- **Border radius:**

| Token | Value | Usage |
|---|---|---|
| `radiusSmall` | 6pt | Inline pills, small buttons (rare) |
| `radiusMedium` | 8pt | Action buttons, input fields |
| `radiusLarge` | 12pt | Surface cards (Today) |
| `radiusXLarge` | 20pt | Composer pill, hero containers |
| `radiusPill` | 999pt | Full-pill buttons (Apple chip style) |

**Inner radius rule (HIG):** when nesting, inner radius = outer radius − inner padding. We don't enforce in code today; flag during review.

## Motion

- **Approach:** **Minimal-functional with one signature.** Card entrance is the only deliberate motion; everything else is default Flutter spring/ease behavior.
- **Card entrance:** `FadeTransition` 180ms `Curves.easeOut` + `SlideTransition` 4% translate-y from below. Defined once in `lib/home/cards/card_entrance.dart`, reused by all cards.
- **Brief streaming (PR2c+ when streaming UI lands):** caret cursor `▎` blinks at 1Hz at end of partial text; fades over 200ms on stream complete.
- **No page transitions:** tab switches use `IndexedStack` (instant, no animation). HIG-compliant for tab bars.
- **Reduced motion:** Flutter's `MediaQuery.of(context).disableAnimations` is honored by `FadeTransition`/`SlideTransition` automatically.

## Card Grammar (the locked decision)

Two card kinds with different chrome:

**Voice cards** — `welcome_card`, `morning_brief_card`. No bordered container, no fill, no shadow. Direct text on `backgroundPrimary`. Padded with `spacingL` horizontal / `spacingM` vertical. Reads as the assistant *speaking*.

**Surface cards** — `today_card`, future `commitment_capture`, `focus_block`. `backgroundSecondary` fill, `radiusLarge`, `Border.all(Colors.white.withValues(alpha: 0.06))`, `EdgeInsets.all(spacingL)` padding. Reads as a structured affordance.

**Message bubbles** — used in `inbox_screen` for messages from apps and Brief. Sender meta line above (avatar + display name + timestamp) + bubble below (`backgroundSecondary` fill, no border, `radiusXLarge`, `EdgeInsets.symmetric(horizontal: spacingL, vertical: spacingM)` padding). Reads as conversation, not as a list or as the assistant speaking. Differentiates from surface cards by the **no-border discipline**: if a message bubble had a border, it would read as a stacked surface card (the hard-rejection anti-pattern). Use only in chat-pattern surfaces (Inbox, future per-app drill-down). Brief sender names render in `brandPrimary` to mark first-party voice; app sender names render in `textPrimary`.

This is the most important visual decision in the system. Stacking multiple surface cards = dashboard mode (anti-pattern, hard rejection from `/plan-design-review`). The hierarchy on Home is: voice first, surface below, max one surface per content domain.

**Inline ref chip exception:** voice cards forbid chrome at the **container** level. Inline ref chips (`InlineRefChip` — ticket, person, conversation, plan) are exempt because they are sentence-level elements analogous to inline links in prose, not card-level chrome. They render inside voice cards (e.g., `morning_brief_card`) via `WidgetSpan` baseline-aligned with surrounding text. This is a deliberate carveout, not a violation. Decided in `/plan-design-review` 2026-05-05.

## Accessibility

- All tap targets meet 44pt minimum (enforced by `AppStyles.touchTargetMinimum`).
- `Semantics(label: ...)` wraps every card with a screen-reader label that aggregates the visible content.
- Color contrast: every text/background combo passes WCAG AA (verified in the Color section).
- Action item bullets in Today card are individually focusable so VoiceOver navigates row-by-row (deferred to Day-30 when we add per-bullet actions).
- No color-only encoding — eyebrow says "Action item" in text, dot color reinforces.
- Reduced motion respected via Flutter platform integration.

## Light Mode

**Out of scope.** App is dark-only, inherited from upstream Omi convention and the pendant-glance use case (low-light environments where dark UI doesn't blast retinas). Light mode would be a cross-tab decision, not a design-system fix.

## What's NOT in this system (anti-patterns)

The following are explicit rejections — flag during review if any appear:

- Purple/violet/indigo gradient backgrounds
- 3-column feature grid with icons in colored circles (the SaaS landing-page tell)
- Centered everything (`text-align: center` on all cards)
- Uniform bubbly border-radius applied to every element
- Colored left-border on cards (`border-left: 3px solid <accent>`)
- Decorative blobs, floating circles, wavy SVG dividers
- Emoji as design elements (rockets in headings, emoji bullets) — **forbidden in UI per project CLAUDE.md**
- Generic hero copy ("Welcome to Nooto", "Unlock the power of...", "All-in-one")
- Stacked cards mosaic (instant rejection — see Card Grammar)
- Cookie-cutter section rhythm (hero → 3 features → testimonials)
- **Serif typography of any kind** (Playfair, Times, Georgia) — permanent blacklist; brand emphasis comes from sans-serif weight + size only
- Message bubbles MUST NOT have borders. The fill-only treatment is what differentiates message-bubble from surface-card and prevents stacking-as-dashboard reading.

## Decisions Log

| Date | Decision | Rationale |
|---|---|---|
| 2026-04-30 | Initial DESIGN.md created | Formalize tokens already shipped in `app_theme.dart`; anchor to Apple HIG; codify the voice/surface card grammar locked in `/plan-design-review` |
| 2026-04-30 | Voice cards drop chrome | Hard rejection rule from `/plan-design-review` — stacking cards reads as dashboard |
| 2026-04-30 | One accent color (brand blue) | Restraint; lets red mean real failure |
| 2026-04-30 | Playfair Display Italic for brand serif | Editorial gravity without script informality; matches `desktop-v2` |
| 2026-04-30 | **Serif reversed — no serif anywhere, ever** | Founder dogfeed rejected Playfair on sight ("I hate serif fonts"). Brand emphasis switches to sans-serif weight + size only; `brandSerif()` deleted; google_fonts dropped from pubspec; permanent blacklist added to anti-patterns |
| 2026-05-05 | Inline ref chips exempt from voice card "no chrome" rule | Adding inline action chips to the brief voice card (Home redesign) needed reconciliation with the voice/surface grammar. Chips are sentence-level elements, not card-level chrome — analogous to links in prose. Carveout documented in Card Grammar section. |
| 2026-05-05 | InlineRefChip family promoted to 24pt + 14pt label | Plan chip joins the family at 24pt; existing ticket/person/conversation chips bump from 22pt/13pt to match. Eliminates line-jitter when paragraph mixes kinds. Single chip metric, no competing focal points. |
| 2026-05-05 | Priority-1 chip emphasis reserved for real urgency | Only chips representing OVERDUE or DUE-SOON-WITHIN-4H items get the `brandPrimary` border. Stuck Jira and plan refs stay quiet. Honors the "when accent appears, it means real urgency" restraint. |
| 2026-05-05 | **Serif partial re-entry — Source Serif 4 Regular at ONE site** | The 2026-04-30 "no serif anywhere, ever" decision was an overcorrection driven by Playfair's literary feel. After 5 weeks of dogfood, the home screen greeting felt sterile in pure sans. Source Serif 4 Regular (humanist, non-cursive, non-decorative) reintroduced via `brandAccent()` at exactly one site: the morning brief greeting. Bundled (no `google_fonts` dependency). Italic and display serifs remain blacklisted; the accent's value is its restraint. |
| 2026-05-06 | **Message bubble grammar introduced for Inbox screen** | Notifications-as-chat ships in v0 with the Inbox surfacing apps + Brief as conversational messages. Voice cards (no chrome) read as the assistant speaking; surface cards (chromed border) read as structured affordances. Neither fit a list-of-messages-from-multiple-senders. Message bubble (fill-only, no border, radiusXLarge) is the third grammar for chat-pattern surfaces. Decided in `/plan-design-review` 2026-05-06. |
| 2026-04-30 | Light mode out of scope | Dark-only inherited from upstream + pendant-glance use case |
