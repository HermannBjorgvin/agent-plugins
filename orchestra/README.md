# Orchestra

Orchestra lets one conversation coordinate several coding agents across your repositories. Each agent, called a **player**, works on its own branch in a git worktree and tmux session. It sends progress, questions, and results back to the **orchestrator**.

Use Claude Code in tmux or a Codex desktop/CLI conversation as the orchestrator. Players run interactive Claude Code or Codex CLI sessions on the same machine. You can attach to a player's tmux session whenever you want to see its work or talk to it directly.

## Install

### Claude Code

```text
/plugin marketplace add HermannBjorgvin/agent-plugins
/plugin install orchestra@hermannbjorgvin
```

The plugin provides `/orchestra:orchestrator` and `/orchestra:player`. Use the namespaced names to avoid conflicts with other installed skills.

### Codex and other agents

Install both skills with [Vercel's skills CLI](https://github.com/vercel-labs/skills)
(requires Node.js and npm):

```bash
npx skills@latest add HermannBjorgvin/agent-plugins --global --skill orchestrator player
```

Choose the agents you use when prompted. Global installation is recommended for
Codex because players run in fresh worktrees and need access to both skills.
To install directly for Codex:

```bash
npx skills@latest add HermannBjorgvin/agent-plugins --global --agent codex --skill orchestrator player
```

Start a new Codex session, then invoke `$orchestrator` or `$player`. Other agents
use their own skill invocation syntax. Install **both** skills in the same scope:
the orchestrator uses the player's reporting helpers. Both installation routes
use the same `SKILL.md` files and bundled scripts; Codex metadata lives beside
each skill in `agents/openai.yaml`.

Use one installation route per agent to avoid duplicates. Claude plugin users
should use the plugin route above; standalone Claude installations use
`/orchestrator` and `/player` instead of the plugin namespace. When launching or
adopting standalone Claude players, set `ORCHESTRA_CLAUDE_SKILL=/player` in the
orchestrator's environment. By default, Claude players use `/orchestra:player`
even when their orchestrator runs in Codex. Installer support
for an agent does not imply that Orchestra's session launch and reporting have
been tested with it; see [Requirements](#requirements) and [limitations](#environment-and-limitations).

Update the skills installed through the CLI with:

```bash
npx skills@latest update --global
```

This updates globally installed skills managed by the CLI. Claude plugin updates
are managed through Claude Code.

### Existing installations

If you used the former `codex/install.sh`, back up any customizations and remove
only its `orchestrator` and `player` directories from `~/.agents/skills` (or the
custom directory you supplied) before installing with the skills CLI. Those
copies contain instructions and script links tied to the manual installation.

### Local development

From this repository's root:

```bash
npx skills@latest add . --global --agent codex --skill orchestrator player
```

Rerun the local install after editing the source skills and start a new session.
The installer manages its own installed copies; this is not a live link to the
checkout.

## Start a task

For a Claude orchestrator, open Claude Code inside tmux. A Codex orchestrator can use a desktop or CLI conversation directly.

```text
/orchestra:orchestrator Add search to this repo. Give the task to a Fable player and have it open a draft PR.
/orchestra:orchestrator Show me the status of my players.
```

In Codex, use `$orchestrator` with the same task text. The orchestrator chooses a branch and starts a player, then receives its reports in the conversation. Each assignment should fit one branch and PR; the orchestrator can coordinate assignments across multiple repositories.

The spawn command prints the worktree and tmux session name. To inspect a player yourself:

```bash
tmux attach -t '=SESSION_NAME'
```

Detach with **Ctrl+B, then D**. Ctrl+C interrupts the running agent.

## Requirements

- Linux or macOS with Bash, Git, coreutils (`realpath`, `sha256sum`), and `ps`/`pgrep`. Tested on Linux.
- tmux 3.x; tested with 3.4.
- An authenticated `claude` or `codex` CLI for each type of player you want to run.
- `jq` for JSON session listings.
- util-linux `script` for automatic CLI detection during resume.

Gemini, Copilot, and OpenCode can also be launched, but have more limited resume support. The plugin uses each CLI's existing authentication and permissions.

## Models and effort

| Player | Default model | Default effort |
| --- | --- | --- |
| Claude Code | `opus` | `high` |
| Claude Code with `--model fable` | `fable` | `high` |
| Codex | `gpt-6-astra` | `medium` |
| Codex with another model | The supplied model | `high` |

Use `--model` and `--effort` to override these defaults. The scripts accept `low`, `medium`, `high`, `xhigh`, and `max`; the selected CLI determines which combinations are available. `--permission-mode` applies only to Claude Code.

Resume passes model and effort options only when you supply them. Codex otherwise uses its configured default model. Claude's restoration of model and effort has not been verified, so pass those options explicitly when you need a particular configuration.

## Scripts

The orchestrator uses the scripts in `skills/orchestrator/scripts/`. All accept `--repo PATH` to select a repository from elsewhere.

| Command | Purpose |
| --- | --- |
| `sessions.sh --all` | List players across repositories with their session name, branch, agent, reporting target and last report; without `--all`, the players tagged for the current or `--repo` repository. Add `--json` for structured output or `--sample N` to compare activity over time. |
| `spawn.sh --branch B --prompt "Task"` | Create a worktree and tmux session, then start a player. Also accepts `--prompt-file FILE`. |
| `screen.sh SESSION --history 200` | Read a player's pane. `--lines N` limits the visible output. |
| `send.sh SESSION "Message"` | Send guidance. Use `--raw` for menus, `--key` for a keypress, or `--type` to type text. |
| `adopt.sh SESSION` | Connect an idle player to the current orchestrator. Optional text gives it a new assignment. |
| `spawn.sh --branch B --resume` | Restart a stopped player in its existing worktree. |
| `kill.sh SESSION` | Stop one player's tmux session. Its branch and worktree remain. |

New branches start from the freshly fetched default branch. Use `--from REF` to choose another starting point, or `--dry-run` to preview a spawn without writes or fetching.

`SESSION` in these commands is either the player's branch (`feature/search`, resolved in the current or `--repo` repository, or uniquely across repositories when run outside one) or the exact tmux session name that `sessions.sh` and `spawn.sh` print. Nothing matches by prefix.

Worktrees live under the main checkout's `.claude/worktrees/` directory. A session's tmux name is a label built from the repository directory and the branch (`agent-plugins-feature-search` for branch `feature/search` in a checkout named `agent-plugins`; `/`, `.` and `:` become `-`); when any session already has that name, `-2`, `-3`, … is appended. The label is chosen once and never parsed: the scripts find a player through its session tags, so a session that merely has such a name is never touched. These conventions match [Kirby](https://github.com/HermannBjorgvin/Kirby).

Both prompt options load the task into a tmux paste buffer named `orchestra-prompt-<session>` on the same server; the launcher inside the pane reads and deletes it. Task text therefore does not consume tmux's roughly 16 KiB command allowance and is never written into the repository. If a new launch fails, its placeholder session is removed and the worktree is kept for a retry.

## Session tags

Everything the scripts know about a player is stored on its tmux session as session user options (tags). Tags die with the session, are readable by anyone who can reach the tmux server, and are the contract shared with [Kirby](https://github.com/HermannBjorgvin/Kirby), which sets the provenance tags on the sessions it creates and reads the rest. No files are used. Read one with `tmux show-options -qv -t '=SESSION:' @orchestra-agent`; `sessions.sh` shows them all.

| Tag | Value |
| --- | --- |
| `@orchestra-spawner` | `orchestra` or `kirby`: which program created the session. |
| `@orchestra-repo` | Absolute, symlink-resolved path of the main checkout. |
| `@orchestra-session-type` | `worktree` for every player. Kirby's terminal tabs carry `shell` or `agent` and are never treated as players. |
| `@orchestra-branch` | The branch the session was spawned under, unsanitized (`feature/x`). |
| `@orchestra-orchestrator` | Reporting target: `codex:<thread-id>` or `tmux:<session>`. Set by `spawn.sh`, replaced by `adopt.sh`. |
| `@orchestra-agent` | Harness in the pane: `claude`, `codex`, `gemini`, `copilot`, `opencode` or `custom`. The launcher records what actually started. |
| `@orchestra-launching` | `1` only while the placeholder pane exists. |
| `@orchestra-last-report` | `<KIND> <ISO-8601 UTC timestamp>` of the last report a transport accepted. |
| `@orchestra-undelivered` | Reports no transport accepted: `<ISO-8601 UTC timestamp> <message>` lines, oldest first, kept under 8 KiB. |

The first four tags are the session's identity and are written once, when the session is created; every lookup (spawn, resume, send, adopt, kill, listing) goes through them rather than through the name. The player pane receives `ORCHESTRA_SESSION` (its tmux name), `ORCHESTRA_SOCKET` (the tmux server socket that holds the session), `ORCHESTRA_MODE`, `ORCHESTRA_HARNESS`, `ORCHESTRA_MODEL`, `ORCHESTRA_EFFORT`, `ORCHESTRA_PERMISSION_MODE`, `ORCHESTRA_COMMAND` and `ORCHESTRA_CLAUDE_SKILL`. The orchestrator target is not passed as an environment variable; the player reads the tag.

## Reporting

Each player session carries one reporting target in its `@orchestra-orchestrator` tag. Spawning or adopting a player sets it; the player cannot change it, and `report.sh --orchestrator` only prints it. Reports arrive as `[player SESSION] KIND: text`, where `SESSION` is the player's tmux session name.

Reports go to either a Codex conversation through `codex queue` or a Claude orchestrator's tmux pane, reached through `ORCHESTRA_SOCKET`. An explicit `--orchestrator codex:<thread-id>` or `--orchestrator tmux:<session>` selects the target when spawning or adopting. Otherwise, the scripts detect the orchestrator from the current session. A player's own Codex ID is never used as its parent target.

Players send four kinds of report:

| Report | Meaning |
| --- | --- |
| `PROGRESS` | A meaningful milestone. |
| `QUESTION` | A decision that needs input. |
| `BLOCKED` | Something prevents further progress. |
| `DONE` | The task is complete, with results and any limitations. |

The reporting script confirms when a transport accepts a message and records `<KIND> <timestamp>` in the session's `@orchestra-last-report` tag. If delivery fails, it returns a nonzero exit code and appends the report to the session's `@orchestra-undelivered` tag; it explicitly says `NOT RECORDED` when even that fails. Recorded reports do not wake the orchestrator; read the tag if a player appears finished but no report arrived.

## Resume or hand off a player

Resume restores a conversation in its existing worktree:

```bash
spawn.sh --repo PATH --branch feature/search --resume
spawn.sh --repo PATH --branch feature/search --resume --prompt "Next, add keyboard navigation."
```

The player receives a restart note and no task body; the reporting target tag is set again from the current orchestrator. You can supply a new message with `--prompt` or `--prompt-file`; the original task is not replayed.

The script chooses the CLI from `--agent`, then the session's `@orchestra-agent` tag. If neither is available, it tries Claude `--continue`. Only the specific no-conversation diagnostic triggers a fallback to the newest Codex conversation recorded for that worktree. Other errors stop the launch and leave a dead pane to inspect.

Use `adopt.sh SESSION` to hand a running, idle player to another orchestrator. Without a new task, the player reports its current status; with task text, it takes the new assignment. Dead panes and bare shells cannot be adopted.

## Environment and limitations

Players inherit configuration and authentication variables, including `CLAUDE_CONFIG_DIR`, `ANTHROPIC_API_KEY`, and `CODEX_HOME`. Known parent-session markers are removed so the new CLI has its own session identity.

The launcher unsets `TMUX` and redirects `TMUX_TMPDIR` to a scratch directory to reduce accidental interaction with the user's tmux server. Reporting reaches the real server through `ORCHESTRA_SOCKET` and reads the target from the session tag. This environment setup is not a security boundary and does not grant access through a sandbox.

Known limitations:

- Version 2.0.0 changed session naming and identity without compatibility shims: sessions created by earlier versions, which kept state in files and named sessions after a hash of the repository path, are not recognised. Kill or finish those players with the version that created them.
- The test suites use fake agent CLIs. They do not verify live model sessions or delivery from a real player through `codex queue`.
- Codex resume finds conversations by the worktree path in rollout files; paths requiring JSON escaping do not match.
- OpenCode resume is untested. Gemini and Copilot resume are unsupported.
- Automatic CLI detection during resume keeps a `script` transcript in `/tmp` for the Claude session's lifetime.
- The pane check treats any non-shell foreground process as an agent, including an editor or pager.
- Host permissions still apply. The plugin does not change AppArmor or sandbox settings.

## Tests

Run from the repository root:

```bash
python3 orchestra/tests/test_port.py
bash orchestra/tests/smoke_tmux.sh
```

Both suites use temporary Git repositories and fake agent CLIs, without model calls. The Python suite mocks tmux, including exact targeting, command-size limits, session user options and paste buffers. The shell suite uses a real tmux server on an isolated socket and checks the tags there.
