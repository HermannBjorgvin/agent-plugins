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
Worktree locations (`.claude/worktrees/<branch with / → ->`) are shared with Kirby; do not
change them.

**Session naming** (shared with Kirby; Orchestra implements it in bash in
`skills/orchestrator/scripts/_lib.sh`, Kirby in TypeScript). A tmux session's name is a
human-readable label chosen once at creation and never parsed; its identity is its tags.
`sanitize(x)` replaces every `/`, `.` and `:` with `-`. The preferred label is
`sanitize(basename(repo))-sanitize(branch)` for worktree sessions and
`sanitize(basename(repo))-shell` / `-agent` for Kirby's terminal tabs, capped at 200 characters:
on overflow, the first 195 characters, `-`, and the first 4 hex digits of sha256 over the
unsanitized string the label was built from (`<basename>-<branch>` for worktree sessions,
`<basename>-shell` / `<basename>-agent` for terminal tabs). If any session on the server
already has the name, `-2`, `-3`, … is appended to the preferred label until one is free (so
a taken `repo-feature-x-2` yields `repo-feature-x-2-2`); the suffix is appended AFTER the
200-character cap and may push the name past 200. It is chosen at creation only, counting
from the preferred label each time (a second lost race yields `-3`). Both test suites pin
this table; keep it identical in both repositories:

| repo | type | branch | label |
| --- | --- | --- | --- |
| `/home/u/Kirby` | worktree | `feature/x` | `Kirby-feature-x` |
| `/srv/agent-plugins` | worktree | `fix/typo.v1.2:rc` | `agent-plugins-fix-typo-v1-2-rc` |
| `/x/my.repo` | worktree | `main` | `my-repo-main` |
| `/home/u/Kirby` | shell | | `Kirby-shell` |
| `/home/u/Kirby` | agent | | `Kirby-agent` |
| `/x/r` | worktree | `a`×250 | `r-` + `a`×193 + `-0a22` |
| `/x/agent-plugins` | worktree | `a`×250 | `agent-plugins-` + `a`×181 + `-1fad` |
| `/x/r` | worktree | `a/`×125 | `r-` + `a-`×96 + `a-6e0f` |
| `/x/r` | worktree | `a.`×125 | `r-` + `a-`×96 + `a-b373` |

Every lookup resolves through the tags: a player is a session with `@orchestra-spawner` set
and `@orchestra-session-type` `worktree`; its identity is (`@orchestra-repo`,
`@orchestra-branch`), several matches prefer the smallest `session_created` and are reported,
never silently killed. A session whose name we would have chosen but that lacks the tags is
foreign: never attached, killed, adopted or listed. Scripts accept a branch (resolved in the
current/`--repo` repo, or uniquely across repos outside one) or an exact tagged session name.
Creation: resolve, pick a free name, `new-session -d` (retry the next suffix on a duplicate),
write the identity tags before anything else, then the buffer and `respawn-pane` flow.

**Session state contract** (shared with Kirby; names are defined once in
`skills/player/scripts/_routing.sh`). All player state lives on the tmux session as session
user options (tags); no files may track player or session state, and there are no
compatibility shims for the former git-dir files and mailbox directory.

- Tags: `@orchestra-spawner` (`kirby`|`orchestra`), `@orchestra-repo` (absolute,
  symlink-resolved main checkout), `@orchestra-session-type` (`worktree`|`shell`|`agent`),
  `@orchestra-branch` (unsanitized branch, worktree sessions only; these four are written by
  the creator only), `@orchestra-orchestrator` (`codex:<uuid>`|`tmux:<session>`), `@orchestra-agent`
  (`claude`|`codex`|`gemini`|`copilot`|`opencode`|`custom`), `@orchestra-launching` (`1` while
  the placeholder pane exists), `@orchestra-last-report` (`<KIND> <ISO-8601 UTC>`),
  `@orchestra-undelivered` (`<ISO-8601 UTC> <message>` lines, oldest first, under 8 KiB).
  Absent means unset; never write a sentinel. Values contain no tabs; only
  `@orchestra-undelivered` contains newlines. Target sessions as `=<name>:` (exact).
- Pane environment (injected by `spawn.sh`): `ORCHESTRA_SESSION` (the session name, used as
  is), `ORCHESTRA_SOCKET` (the tmux server socket holding the session; the pane's own tmux
  environment is a scratch server at `/tmp/orchestra-agent-tmux`), `ORCHESTRA_MODE`,
  `ORCHESTRA_HARNESS`, `ORCHESTRA_MODEL`, `ORCHESTRA_EFFORT`, `ORCHESTRA_PERMISSION_MODE`,
  `ORCHESTRA_COMMAND`, `ORCHESTRA_CLAUDE_SKILL`. The orchestrator target is never an
  environment variable. `report.sh` resolves the player's own session from
  `ORCHESTRA_SESSION`/`ORCHESTRA_SOCKET`, or from `TMUX` (`display-message -p '#S'`, socket
  `${TMUX%%,*}`) in a pane `spawn.sh` did not start, such as a Kirby session adopted by
  `adopt.sh`, and reports as `[player <session name>] KIND: …`.
- Task body: paste buffer `orchestra-prompt-<session>` on the same server, loaded from stdin
  by `spawn.sh` and deleted by the launcher.
- Listing: the resolver is one `tmux list-sessions -F` call with `#{session_name}`,
  `#{session_created}`, `#{session_path}` and the `#{@orchestra-*}` fields; `sessions.sh`
  is one `list-panes -a -F` call with the same tags, scoped to sessions whose repo tag equals
  the current/`--repo` repo (`--all`: every worktree session). Matching is client-side; no
  `list-sessions -f` filters (Kirby supports tmux 2.0+). Reads pass `tmux -u` so values
  survive a non-UTF-8 client locale.

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
