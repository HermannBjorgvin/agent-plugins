# Orchestra

Run several coding agents in parallel, each in its own tmux session and git worktree,
and supervise them from one conversation. The plugin ships two cooperating skills:

- **orchestrator** splits a backlog into PR-sized tasks, spawns a *player* per task, watches
  the sessions, relays questions and verifies results.
- **player** is what runs inside each spawned session: it binds to its orchestrator, does the
  task in its worktree, and reports PROGRESS / QUESTION / BLOCKED / DONE back.

Players can be Claude Code or Codex CLI (Gemini, Copilot and OpenCode launch too, with fewer
features). The orchestrator can be a Claude Code session inside tmux, or a Codex desktop/CLI
thread; reports are delivered by pasting into the orchestrator's tmux pane or by
`codex queue` respectively.

## Requirements

- Linux or macOS with `bash`, `git`, `coreutils` (`realpath`, `sha256sum`), `ps`/`pgrep`
- `tmux` 3.x (3.4 tested). The orchestrator itself must run *inside* a tmux session when it is
  a Claude Code session, so players know where to report.
- `jq` for `sessions.sh --json` only
- `script` from util-linux, only for the automatic harness detection on resume
- The agent CLIs you intend to run: `claude` and/or `codex` (`gemini`, `copilot`, `opencode`
  optional). Each must already be logged in; the plugin never handles credentials.

## Install

```bash
/plugin marketplace add HermannBjorgvin/claude-plugins
/plugin install orchestra@hermannbjorgvin
```

That gives Claude Code the skills `/orchestra:orchestrator` and `/orchestra:player`
(the bare `/orchestrator` and `/player` also work unless another skill uses those names).

### Codex

Codex reads skills from `~/.agents/skills`. From the installed plugin directory run:

```bash
bash codex/install.sh            # or: bash codex/install.sh --skills-dir DIR
```

It copies the Codex entrypoints (`SKILL.md` + `agents/openai.yaml`, explicit-only invocation)
to `~/.agents/skills/orchestrator` and `~/.agents/skills/player`, and links their `scripts`
directories to this plugin's, so both harnesses run the same files. The links point at the
directory you ran the script from: rerun it after a plugin update (each update lands in a new
version directory), or run it from a git checkout of this repository to follow the checkout.
In Codex the skills are invoked as `$orchestrator` and `$player`.

## Use

Start an orchestrator in a tmux session (Claude) or a Codex thread, then:

```
/orchestra:orchestrator Split these backlog items into PRs and run them: …
/orchestra:orchestrator status
```

The orchestrator uses the scripts in `skills/orchestrator/scripts/` (every one accepts
`--repo PATH`, and session names match exactly, never by prefix):

| Script | Purpose |
| --- | --- |
| `sessions.sh [--all] [--json] [--sample N]` | List player sessions with a busy/idle/dead heuristic |
| `spawn.sh --branch B (--prompt-file F \| --prompt T) [--agent …] [--model …] [--effort …]` | Create worktree + tmux session and start a player |
| `spawn.sh --branch B --resume [--prompt "Next: …"]` | Restart a dead or vanished player's conversation |
| `screen.sh SESSION [--lines N] [--history N]` | Show a pane's text |
| `send.sh SESSION TEXT` (`--raw`, `--key`, `--type`) | Type into a player's pane |
| `adopt.sh SESSION [--orchestrator T] [text]` | Rebind an idle player to this orchestrator |
| `kill.sh SESSION` | Kill one player's tmux session (worktree and branch stay) |

Each player gets a worktree at `<main checkout>/.claude/worktrees/<branch>` and a tmux
session named `kirby-<16 hex of the repo path>-<branch>`; both conventions are shared with
[Kirby](https://github.com/HermannBjorgvin/Kirby) so its UI shows the same sessions. New
branches start from the freshly fetched default branch unless `--from REF` is given.

The task travels in a file (`--prompt-file`), so it can be any length; the launcher composes
the first message as the player invocation, the reporting target and the task body.

### Models and effort

| Harness | Default model | Default effort |
| --- | --- | --- |
| Claude Code | `opus` | `high` |
| Claude Code (`--model fable`) | `fable` | `high` |
| Codex | `gpt-6-astra` | `medium` |
| Codex, any other model | as given | `high` |

`--model` and `--effort` (`low`, `medium`, `high`, `xhigh`, `max`) override the presets on
fresh launches. On `--resume` nothing is added unless given: Claude continues with its own
settings and Codex resumes with its configured default model. `--permission-mode` applies to
Claude only. Whether a model or effort value is available is the CLI's business.

### Reporting

Inside the player, `report.sh KIND "text"` sends `[player NAME] KIND: text` to the orchestrator.
The destination is bound per worktree (in its git directory, together with the tmux socket) at
spawn/adopt time and re-confirmed by the player from its first message; an explicit
`--orchestrator codex:<thread-id>` or `tmux:<session>` always wins, and a player never
substitutes its own Codex thread for its parent.

`report.sh` prints `queued for …` or `sent to …` only when the transport accepted the message.
Otherwise it exits nonzero and prints `NOT DELIVERED …; saved in <mailbox>` (a log under
`~/.claude/orchestrator-mail/`, or `ORCHESTRATOR_MAIL_DIR`) or `NOT DELIVERED … and NOT SAVED`
with the text echoed. The mailbox does not wake the orchestrator; check it when a player looks
finished but nothing arrived.

### Resume and handoff

- `spawn.sh --branch B --resume` restarts a dead or vanished player in its worktree and sends
  "continue" with the current reporting target. The original task is never replayed. Harness:
  `--agent`, else the session's tag, else the harness recorded in the worktree, else Claude
  `--continue` and, only if Claude reports no conversation, the newest Codex conversation
  recorded for that worktree. Any other failure leaves a dead pane to inspect.
- `spawn.sh … --resume --prompt "Next: …"` resumes with a new assignment.
- `adopt.sh SESSION` hands an idle player to a different orchestrator (dead panes and
  shell-owned panes are refused). Without text the player answers with a PROGRESS summary;
  with text it takes that as its new task.

### Isolation

Players run with the parent session markers removed (`CLAUDECODE`, `CLAUDE_CODE_*` session
variables, `CODEX_THREAD_ID`, …) so they do not think they are nested and do save their
transcripts, while `CLAUDE_CONFIG_DIR`, `ANTHROPIC_API_KEY` and `CODEX_HOME` are inherited.
`TMUX` is unset and `TMUX_TMPDIR` points at a scratch directory, so nothing a player runs can
reach the tmux server hosting your own sessions.

## Tests

Both suites use temporary git repositories and fake `claude`/`codex` binaries; no model is
called and no user tmux session is touched.

```bash
python3 orchestra/tests/test_port.py      # mock tmux (enforces exact targets and the 16 KiB limit)
bash orchestra/tests/smoke_tmux.sh        # real tmux server on an isolated socket
```

## Limitations

- Live launches of real Claude/Codex players and `codex queue` delivery from a real player are
  not covered by the tests here (fake binaries only).
- The plugin does not grant host access: if a sandbox blocks tmux, Codex state writes, a
  repository or the network, the scripts report it and stop. They never change AppArmor or
  sandbox settings.
- Codex conversation lookup on resume matches the worktree path recorded in the rollout file;
  paths that need JSON escaping would not match.
- Whether Claude `--continue` restores the previous model/effort is not verified; pass them on
  resume when they must be guaranteed. Codex resumes with its configured default unless
  `--model` is given.
- OpenCode resume is untested; Gemini and Copilot have no resume support.
- The automatic harness detection on resume keeps a `script(1)` typescript in `/tmp` for the
  Claude session's lifetime.
- The pane-ownership check treats any non-shell foreground process as an agent, so a pane
  running some other program (an editor, a pager) counts as agent-owned.
