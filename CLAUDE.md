# Agent Plugin Marketplace

This monorepo distributes Claude Code plugins through `.claude-plugin/marketplace.json`
and shared Orchestra skills to Codex and other agents through Vercel's skills CLI.

## Structure

```
.claude-plugin/
  marketplace.json      # Marketplace definition (plugins list)
tv-pauser/              # Plugin: TV Pauser
  .claude-plugin/
    plugin.json         # Plugin metadata
  commands/             # Slash commands (/tv-pauser:status, /tv-pauser:toggle)
  hooks/
    hooks.json          # Hook definitions (pause on PermissionRequest, etc.)
  scripts/              # Bash scripts called by hooks
orchestra/              # Plugin: Orchestra (orchestrator + player skills)
  .claude-plugin/
    plugin.json
  skills/
    orchestrator/       # Shared SKILL.md, scripts/, agents/openai.yaml
    player/             # Shared SKILL.md, scripts/, agents/openai.yaml
  tests/                # Mock-tmux unit tests and real-tmux smoke test (fake CLIs)
```

## Adding a New Plugin

1. Create a new directory: `my-plugin/`
2. Add `.claude-plugin/plugin.json` with name, version, description
3. Add hooks, commands, scripts as needed
4. Register in `.claude-plugin/marketplace.json`:
   ```json
   {
     "name": "my-plugin",
     "source": "./my-plugin",
     "description": "What it does"
   }
   ```

## Testing Locally

```bash
# Load plugin directly for development
claude --plugin-dir ./tv-pauser

# Or install from local marketplace
/plugin marketplace add /path/to/this/repo
/plugin install tv-pauser@hermannbjorgvin
```

## Publishing

Commit and push. Users install via:
```bash
/plugin marketplace add HermannBjorgvin/agent-plugins
/plugin install tv-pauser@hermannbjorgvin
```

Codex and other agents install both shared skills through Vercel's skills CLI.
Recommend global installation for Codex so fresh player worktrees discover them:

```bash
npx skills@latest add HermannBjorgvin/agent-plugins --global --agent codex --skill orchestrator player
```

Start a new session after installation. TV Pauser supports Claude Code only.

## Orchestra Details

Two cooperating skills: the orchestrator spawns players (one tmux session + git worktree +
branch each) and the player reports back through `skills/player/scripts/report.sh`. The
scripts resolve each other relative to their real location, including installer symlinks.
Keep both skills as siblings and install them together. Maintain one shared SKILL.md
per skill, with Claude-specific invocation and path guidance clearly labeled and Codex
metadata in agents/openai.yaml. Do not create client-specific copies of the instructions.
Session names (`kirby-<key>-<branch>`) and worktree locations (`.claude/worktrees/`)
are shared with Kirby; do not change them.

Tests (no model calls, isolated tmux socket):
```bash
python3 orchestra/tests/test_port.py
bash orchestra/tests/smoke_tmux.sh
```

## TV Pauser Details

Pauses Home Assistant media players when Claude needs attention, resumes when working.

**Environment variables** (set in `~/.claude/settings.json`):
- `TV_PAUSER_HA_URL` - Home Assistant URL
- `TV_PAUSER_HA_TOKEN` - Long-lived access token
- `TV_PAUSER_HA_ENTITY` - Media player entity ID

**State file**: `~/.local/state/tv-pauser/enabled` (enabled by default, "0" = disabled)

**Hook flow**:
- `PermissionRequest` / `Stop` → pause
- `UserPromptSubmit` / `PostToolUse` → resume
