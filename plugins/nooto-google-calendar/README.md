# Nooto Google Calendar

Manage your Google Calendar with voice commands — create events, view your schedule, and more.

## Quick Start (Coolify)

### 1. Google Cloud Setup

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create or select a project
3. Enable **Google Calendar API** (APIs & Services > Library)
4. Go to **APIs & Services > OAuth consent screen**:
   - Choose External
   - Fill app name, support email
   - Add scopes: `calendar`, `calendar.events`, `userinfo.email`, `userinfo.profile`
   - Add yourself as test user
5. Go to **APIs & Services > Credentials**:
   - Create Credentials > OAuth client ID > Web application
   - Add redirect URI: `https://your-domain.com/auth/google/callback`
   - Copy **Client ID** and **Client Secret**

### 2. Deploy to Coolify

1. Create a new service from this directory
2. Set environment variables:

```
GOOGLE_CLIENT_ID=your_client_id.apps.googleusercontent.com
GOOGLE_CLIENT_SECRET=your_client_secret
GOOGLE_REDIRECT_URI=https://your-domain.com/auth/google/callback
REDIS_URL=redis://your-redis:6379
```

3. Deploy — Coolify will build the Dockerfile automatically

### 3. Register in Omi App

Go to the Omi developer portal and create/update your app with these URLs:

| Field | Value |
|-------|-------|
| **Setup URL** | `https://your-domain.com/?uid={{uid}}` |
| **Setup Completed URL** | `https://your-domain.com/setup/google?uid={{uid}}` |
| **Chat Tools Manifest URL** | `https://your-domain.com/.well-known/omi-tools.json` |

## Local Development

```bash
# 1. Create .env file
cp .env.example .env
# Fill in GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET

# 2. Start with Docker
docker compose up --build

# 3. Expose with ngrok
ngrok http 8080

# 4. Update .env with ngrok URL
GOOGLE_REDIRECT_URI=https://your-ngrok.ngrok.app/auth/google/callback

# 5. Add the ngrok redirect URI in Google Cloud Console

# 6. Restart
docker compose up -d

# 7. Visit
open https://your-ngrok.ngrok.app/?uid=test-user-1
```

## Environment Variables

| Variable | Description | Required |
|----------|-------------|----------|
| `GOOGLE_CLIENT_ID` | Google OAuth Client ID | Yes |
| `GOOGLE_CLIENT_SECRET` | Google OAuth Client Secret | Yes |
| `GOOGLE_REDIRECT_URI` | OAuth callback URL | Yes |
| `REDIS_URL` | Redis connection URL (falls back to file storage) | No |

## API Endpoints

### Chat Tools (POST)

| Endpoint | Description |
|----------|-------------|
| `/tools/list_events` | List upcoming calendar events |
| `/tools/create_event` | Create a new event |
| `/tools/get_event` | Get event details |
| `/tools/update_event` | Update an event |
| `/tools/delete_event` | Delete an event |
| `/tools/list_calendars` | List all calendars |

### OAuth & Setup (GET)

| Endpoint | Description |
|----------|-------------|
| `/?uid=<uid>` | Setup UI / settings page |
| `/auth/google?uid=<uid>` | Start OAuth flow |
| `/auth/google/callback` | OAuth callback |
| `/setup/google?uid=<uid>` | Check setup status (returns JSON) |
| `/disconnect?uid=<uid>` | Disconnect account |
| `/health` | Health check |
| `/.well-known/omi-tools.json` | Chat tools manifest |

## Example Voice Commands

- "What's on my calendar today?"
- "Show me my schedule for next week"
- "Create a meeting with John tomorrow at 2pm"
- "Schedule a dentist appointment on Friday at 10am"
- "Delete my 3pm meeting"
- "Reschedule my team sync to 4pm"
