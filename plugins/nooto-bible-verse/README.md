# Bible Verse — Omi Plugin

A companion plugin that listens to your conversations and sends relevant Bible verses for support, encouragement, and comfort when it detects you could benefit from one.

Built on the [Sandbox plugin framework](../sandbox/).

## How It Works

The plugin processes real-time conversation transcripts and detects emotional states — stress, grief, joy, anxiety, gratitude, fear, and more. When it recognizes a moment where a Bible verse could help, it sends a notification with the verse reference and text.

- **Notifications**: Bible verses matched to detected emotions (low threshold — this is the core feature)
- **Memories**: Captures faith-related preferences, prayer requests, and spiritual context
- **Tasks**: Disabled — this app focuses purely on spiritual support

## Quick Start

```bash
# 1. Configure
cp .env.template .env
# Edit .env with your OpenRouter key and Omi credentials

# 2. Run
docker compose up -d

# 3. Test
curl http://localhost:8080/health
```

## Soul Configuration

The `soul/` directory defines the plugin's behavior:

| File | Purpose |
|------|---------|
| `identity.md` | Bible verse companion identity |
| `notifications.md` | Triggers on emotional states (stress, grief, joy, etc.) |
| `memories.md` | Captures faith preferences, prayer requests, milestones |
| `tasks.md` | Disabled — always returns empty |
| `personality.md` | Warm, gentle tone — verse as a gift, no preaching |
| `custom_rules.md` | Verse categories by emotion, no repetition |

## Example

**User says**: "I've been so anxious about this job interview tomorrow"

**Plugin responds**: Philippians 4:6-7 — "Do not be anxious about anything, but in every situation, by prayer and petition, with thanksgiving, present your requests to God. And the peace of God, which transcends all understanding, will guard your hearts and your minds in Christ Jesus."

## Confidence Thresholds

| Type | Threshold | Rationale |
|------|-----------|-----------|
| Notifications | 0.5 | Low bar — sending verses is the core purpose |
| Tasks | 0.9 | High bar — tasks are not the focus |
| Memories | 0.5 | Remember spiritual context for better verse matching |

## Deploy

See the [Sandbox README](../sandbox/README.md) for deployment instructions (Coolify, Docker Compose, cost estimates).
