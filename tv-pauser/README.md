# TV Pauser

Your TV keeps playing while you stare at a permission prompt? Not anymore.

TV Pauser automatically pauses your media player (Apple TV, Chromecast, etc.) when Claude stops working and resumes when you start typing. It's a productivity plugin that respects your binge-watching.

## Features

- **Auto pause/resume** - Pauses media on permission prompts, resumes when Claude finishes
- **Easy toggle** - `/tv-pauser:toggle` command to enable/disable
- **Graceful failure** - Silently fails if Home Assistant is unreachable (you're not at home)
- **Debouncing** - Prevents rapid pause/resume toggling

## Installation

```bash
# Add the marketplace (one-time)
/plugin marketplace add HermannBjorgvin/agent-plugins

# Install TV Pauser
/plugin install tv-pauser@hermannbjorgvin
```

Then restart Claude Code.

## Prerequisites

- [Home Assistant](https://www.home-assistant.io/) with a media player integration (Apple TV, Chromecast, etc.)
- A long-lived access token from Home Assistant
- Your media player entity ID (e.g., `media_player.living_room_apple_tv`)

## Configuration

Add these environment variables to your Claude Code settings file (`~/.claude/settings.json`):

```json
{
  "env": {
    "TV_PAUSER_HA_URL": "http://homeassistant.local:8123",
    "TV_PAUSER_HA_TOKEN": "your-long-lived-access-token",
    "TV_PAUSER_HA_ENTITY": "media_player.living_room_apple_tv"
  }
}
```

| Variable | Description | Default |
|----------|-------------|---------|
| `TV_PAUSER_HA_URL` | Home Assistant URL | `http://homeassistant.local:8123` |
| `TV_PAUSER_HA_TOKEN` | Long-lived access token | (required) |
| `TV_PAUSER_HA_ENTITY` | Media player entity ID | `media_player.apple_tv` |

**Long-Lived Access Token:** Create one in Home Assistant: Profile → Long-Lived Access Tokens

**Media Player Entity ID:** Find it in Home Assistant: Settings → Devices → Entities → search your device name

## Usage

Toggle the plugin on or off:
```
/tv-pauser:toggle
```

Check status and configuration:
```
/tv-pauser:status
```

## How It Works

| Event | Action | Why |
|-------|--------|-----|
| **UserPromptSubmit** | ▶️ Resume | You sent a message, Claude is working |
| **PostToolUse** | ▶️ Resume | Tool completed, Claude is working |
| **PermissionRequest** | ⏸️ Pause | Claude needs your attention |
| **Stop** | ⏸️ Pause | Claude finished, your turn |

## Troubleshooting

**Plugin not working:**
1. Check status: `/tv-pauser:status`
2. Verify `TV_PAUSER_HA_TOKEN` is set in `~/.claude/settings.json`
3. Restart Claude Code after installing

**Media player not responding:**
1. Verify the entity ID in Home Assistant
2. Try controlling the media player directly from Home Assistant first
