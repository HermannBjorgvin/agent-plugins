# Orchestra

Orchestra lets one conversation coordinate several coding agents across your repositories. Each agent, called a **player**, works on its own branch in a git worktree and tmux session. It sends progress, questions, and results back to the **orchestrator**.

Use Claude Code in tmux or a Codex desktop/CLI conversation as the orchestrator. Players run interactive Claude Code or Codex CLI sessions on the same machine. You can attach to a player's tmux session whenever you want to see its work or talk to it directly.

## Install

In Claude Code:

```text
/plugin marketplace add HermannBjorgvin/agent-plugins
/plugin install orchestra@hermannbjorgvin
```

The plugin provides `/orchestra:orchestrator` and `/orchestra:player`. Use the namespaced names to avoid conflicts with other installed skills.

In Codex:

```bash
codex plugin marketplace add HermannBjorgvin/agent-plugins
codex plugin add orchestra@hermannbjorgvin
```

Start a new Codex session, then invoke `$orchestra:orchestrator` or `$orchestra:player`. Codex loads
its entrypoints from the installed plugin; both clients share the bundled scripts.
No separate skill installer is needed.

For local development, add the repository root with `codex plugin marketplace add .`,
then install `orchestra@hermannbjorgvin` and start a new session.

If you used the former `codex/install.sh`, remove `~/.agents/skills/orchestrator`
and `~/.agents/skills/player` after confirming they are the copies installed by
Orchestra. Preserve any personal changes before removing them, so Codex doesn't
load duplicate standalone skills alongside the plugin.

## Start a task

For a Claude orchestrator, open Claude Code inside tmux. A Codex orchestrator can use a desktop or CLI conversation directly.

```text
/orchestra:orchestrator Add search to this repo. Give the task to a Fable player and have it open a draft PR.
/orchestra:orchestrator Show me the status of my players.
```

In Codex, use `$orchestra:orchestrator` with the same task text. The orchestrator chooses a branch and starts a player, then receives its reports in the conversation. Each assignment should fit one branch and PR; the orchestrator can coordinate assignments across multiple repositories.

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
| `sessions.sh --all` | List players across repositories. Add `--json` for structured output or `--sample N` to compare activity over time. |
| `spawn.sh --branch B --prompt "Task"` | Create a worktree and tmux session, then start a player. Also accepts `--prompt-file FILE`. |
| `screen.sh SESSION --history 200` | Read a player's pane. `--lines N` limits the visible output. |
| `send.sh SESSION "Message"` | Send guidance. Use `--raw` for menus, `--key` for a keypress, or `--type` to type text. |
| `adopt.sh SESSION` | Connect an idle player to the current orchestrator. Optional text gives it a new assignment. |
| `spawn.sh --branch B --resume` | Restart a stopped player in its existing worktree. |
| `kill.sh SESSION` | Stop one player's tmux session. Its branch and worktree remain. |

New branches start from the freshly fetched default branch. Use `--from REF` to choose another starting point, or `--dry-run` to preview a spawn without writes or fetching.

Worktrees live under the main checkout's `.claude/worktrees/` directory. Session names use `kirby-<repo path hash>-<branch>`, with branch separators normalized for tmux. These conventions match [Kirby](https://github.com/HermannBjorgvin/Kirby). Session targeting is exact, so a short name cannot select a different player by prefix.

Both prompt options use a file for transport into tmux. Task text therefore does not consume tmux's roughly 16 KiB command allowance. If a new launch fails, its placeholder session is removed and the worktree is kept for a retry.

## Reporting

Each worktree stores one orchestrator destination in its local Git metadata. Spawning or adopting a player sets that destination; the player's first message confirms it. Rebinding replaces the destination.

Reports go to either a Codex conversation through `codex queue` or a Claude orchestrator's tmux pane. An explicit `--orchestrator codex:<thread-id>` or `--orchestrator tmux:<session>` selects the destination. Otherwise, the scripts detect the orchestrator from the current session. A player's own Codex ID is never used as its parent destination.

Players send four kinds of report:

| Report | Meaning |
| --- | --- |
| `PROGRESS` | A meaningful milestone. |
| `QUESTION` | A decision that needs input. |
| `BLOCKED` | Something prevents further progress. |
| `DONE` | The task is complete, with results and any limitations. |

The reporting script confirms when a transport accepts a message. If delivery fails, it returns a nonzero exit code and tries to save the report under `~/.claude/orchestrator-mail/` (or `ORCHESTRATOR_MAIL_DIR`). It explicitly says when saving also fails. Saved reports do not wake the orchestrator; check that mailbox if a player appears finished but no report arrived.

## Resume or hand off a player

Resume restores a conversation in its existing worktree:

```bash
spawn.sh --repo PATH --branch feature/search --resume
spawn.sh --repo PATH --branch feature/search --resume --prompt "Next, add keyboard navigation."
```

The default message is `continue`, together with the current reporting destination. You can supply a new message with `--prompt` or `--prompt-file`; the original task is not replayed.

The script chooses the CLI from `--agent`, then the tmux session tag, then the worktree's recorded agent. If none is available, it tries Claude `--continue`. Only the specific no-conversation diagnostic triggers a fallback to the newest Codex conversation recorded for that worktree. Other errors stop the launch and leave a dead pane to inspect.

Use `adopt.sh SESSION` to hand a running, idle player to another orchestrator. Without a new task, the player reports its current status; with task text, it takes the new assignment. Dead panes and bare shells cannot be adopted.

## Environment and limitations

Players inherit configuration and authentication variables, including `CLAUDE_CONFIG_DIR`, `ANTHROPIC_API_KEY`, and `CODEX_HOME`. Known parent-session markers are removed so the new CLI has its own session identity.

The launcher unsets `TMUX` and redirects `TMUX_TMPDIR` to a scratch directory to reduce accidental interaction with the user's tmux server. Reporting uses the saved destination and socket. This environment setup is not a security boundary and does not grant access through a sandbox.

Known limitations:

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

Both suites use temporary Git repositories and fake agent CLIs, without model calls. The Python suite mocks tmux, including exact targeting and command-size limits. The shell suite uses a real tmux server on an isolated socket.
