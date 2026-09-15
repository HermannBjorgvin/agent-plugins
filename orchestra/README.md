# Orchestra

Orchestra lets one coding agent delegate work to other coding agents on the same machine. The **orchestrator** supervises the work; each **player** runs in a tmux session and works on a branch in a git worktree. Players send progress, questions, and results back to the supervising agent.

Orchestra provides two skills backed by Bash scripts. The skills tell the agents how to coordinate; the scripts perform the Git and tmux operations. Use Claude Code in tmux or a Codex desktop/CLI conversation as the orchestrator. You can attach to any player's session to inspect its work or talk to it directly.

[Install](#install) · [Start a task](#start-a-task) · [Architecture](#architecture) · [Scripts](#scripts) · [Reporting](#reporting) · [Resume and handoff](#resume-or-hand-off-a-player) · [Requirements](#requirements)

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

## Architecture

### Skills guide the agents; scripts operate the sessions

| Component | Role |
| --- | --- |
| [Orchestrator skill](skills/orchestrator/SKILL.md) | Guides the supervising agent: divide the work, choose players, inspect progress, and respond to reports. |
| [Orchestrator scripts](skills/orchestrator/scripts/) | `spawn.sh`, `sessions.sh`, `screen.sh`, `send.sh`, `adopt.sh`, and `kill.sh` perform the requested Git and tmux operations. |
| [Player launcher](skills/orchestrator/scripts/_launch.sh) | Runs inside a player's pane, reads its assignment, and starts or resumes the selected agent CLI. |
| [Player skill](skills/player/SKILL.md) | Guides the coding agent: work in its assigned worktree and report progress, questions, blockers, and completion. |
| [Reporting script](skills/player/scripts/report.sh) | Reads the session's reporting target and sends the player's message to the supervising agent. |

The scripts share naming and discovery helpers in [`_lib.sh`](skills/orchestrator/scripts/_lib.sh) and tag definitions, tmux targeting, and reporting helpers in [`_routing.sh`](skills/player/scripts/_routing.sh). Both skills must be installed together because the orchestrator scripts source the player's routing helpers.

### Labels, identity, and supervision

Three separate values describe a player:

| Concern | Where it lives | Example |
| --- | --- | --- |
| Human-readable label | tmux session name | `shop-feature-search` |
| Repository and branch identity | `@orchestra-repo` and `@orchestra-branch` session options | `/code/shop` + `feature/search` |
| Current supervisor | `@orchestra-orchestrator` session option | `tmux:planning` or `codex:<thread-id>` |

The session name is chosen at creation from the repository directory and branch, with `/`, `.` and `:` replaced by `-`. If any session already has that name, a numeric suffix is added: `shop-feature-search-2`, then `-3`, and so on. Scripts find the player through its tags, so the suffix does not change its identity.

A player must have a creator tag, a repository tag, and session type `worktree`. A familiar-looking name alone does not make a session a player. The reporting target can change while the same player process and conversation keep running.

### State lives on the tmux session

The `@orchestra-*` tags are native tmux **session user options**: string values that the Bash scripts read and write with tmux commands. The diagram shows the actual option names and example values. `@orchestra-launching` exists during launch; `@orchestra-last-report` is set after a transport accepts a report.

```mermaid
flowchart LR
    Spawn["spawn.sh"]
    Adopt["adopt.sh"]
    List["sessions.sh"]

    subgraph Session["tmux session: shop-feature-search"]
        subgraph Options["Session user options stored by tmux"]
            Identity["Set at creation<br/>@orchestra-spawner = orchestra<br/>@orchestra-repo = /code/shop<br/>@orchestra-session-type = worktree<br/>@orchestra-branch = feature/search"]
            Runtime["Launch state<br/>@orchestra-agent = claude<br/>@orchestra-launching = 1 during launch, then unset"]
            Target["Reporting destination<br/>@orchestra-orchestrator = tmux:planning"]
            Reports["Last accepted report<br/>@orchestra-last-report = KIND + timestamp"]
        end
        Pane["Pane process: coding agent CLI<br/>Working directory: /code/shop/.claude/worktrees/feature-search"]
    end

    Spawn -->|set-option| Identity
    Spawn -->|set-option| Runtime
    Spawn -->|set-option| Target
    Spawn -->|respawn-pane runs _launch.sh| Pane
    Adopt -->|set-option changes destination| Target
    Options -.->|list-panes -a -F reads tags| List
```

### Launch and prompt transport

1. `spawn.sh` prepares the branch and worktree, creates a detached tmux session, and writes the session tags.
2. It loads the assignment through stdin into a named tmux paste buffer, `orchestra-prompt-<session>`, on the same server. This carries large prompts without using tmux's roughly 16 KiB command allowance.
3. `respawn-pane` starts `_launch.sh` inside the pane with `ORCHESTRA_SESSION`, `ORCHESTRA_SOCKET`, and the selected launch settings.
4. The launcher reads and deletes the buffer, adds the player-skill invocation, records the selected agent CLI, and starts it.

Worktrees live under the main checkout in `.claude/worktrees/`, with `/` in the branch name replaced by `-`: branch `feature/search` uses `.claude/worktrees/feature-search`. The assignment travels in the temporary buffer; coordination metadata lives in session options. The player reads its reporting target from the session each time it reports.

If tmux refuses to launch a newly created pane, `spawn.sh` removes its placeholder session and keeps the worktree for a retry. If the agent CLI exits, the pane remains available for inspection.

Session options disappear when the tmux session ends. `kill.sh` stops the session and leaves its branch and worktree in place. The agent CLI manages its own conversation history, which resume uses to continue work.

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

## Session tags

Read a session option directly with tmux:

```bash
tmux -u show-options -qv -t '=shop-feature-search:' @orchestra-agent
```

`sessions.sh` summarizes each player's branch, agent, reporting target, and last accepted report. Add `--json` for full values or `--all` to list players across repositories. The complete session schema is:

| Tag | Value |
| --- | --- |
| `@orchestra-spawner` | Program that created the session; `spawn.sh` writes `orchestra`. |
| `@orchestra-repo` | Absolute, symlink-resolved path of the main checkout. |
| `@orchestra-session-type` | `worktree` for every player. Sessions with other types, such as `shell` or `agent`, are outside player management. |
| `@orchestra-branch` | The branch the session was spawned under, unsanitized (`feature/x`). |
| `@orchestra-orchestrator` | Reporting target: `codex:<thread-id>` or `tmux:<session>`. Set by `spawn.sh`, replaced by `adopt.sh`. |
| `@orchestra-agent` | Harness in the pane: `claude`, `codex`, `gemini`, `copilot`, `opencode` or `custom`. The launcher records what actually started. |
| `@orchestra-launching` | `1` only while the placeholder pane exists. |
| `@orchestra-last-report` | `<KIND> <ISO-8601 UTC timestamp>` of the last report a transport accepted. |

The first four tags record the session's origin and are written at creation. Spawning or adopting a player sets its supervisor independently.

The pane receives `ORCHESTRA_SESSION` and `ORCHESTRA_SOCKET` so the launcher and reporting script can reach its session. Other `ORCHESTRA_*` variables supply launch settings such as CLI, model, effort, and player-skill invocation; see the [launcher header](skills/orchestrator/scripts/_launch.sh). A pane without the injected session variables can discover its session from its existing tmux environment.

## Reporting

The player calls `report.sh KIND "message"`. The script reads `@orchestra-orchestrator` on every call and sends `[player SESSION] KIND: message`, where `SESSION` is the player's tmux session name. `report.sh --orchestrator` prints the target; changing it is the responsibility of the spawn and adoption scripts.

Reports go to either a Codex conversation through `codex queue` or a Claude orchestrator's tmux pane, reached through `ORCHESTRA_SOCKET`. An explicit `--orchestrator codex:<thread-id>` or `--orchestrator tmux:<session>` selects the target when spawning or adopting. Otherwise, the scripts detect the orchestrator from the current session. A player's own Codex ID is never used as its parent target.

Players send four kinds of report:

| Report | Meaning |
| --- | --- |
| `PROGRESS` | A meaningful milestone. |
| `QUESTION` | A decision that needs input. |
| `BLOCKED` | Something prevents further progress. |
| `DONE` | The task is complete, with results and any limitations. |

Successful delivery prints `queued for …` or `sent to …` and sets `@orchestra-last-report` to the kind and timestamp. This confirms transport acceptance; it does not confirm that the supervising agent has read the report.

A failed delivery exits nonzero and prints the destination, reason, and complete original report to stderr:

```text
report.sh: delivery failed
Target: tmux:planning
Reason: orchestrator session planning is gone or unreachable
Report: [player shop-feature-search] DONE: Search is implemented…
```

The player surfaces the failure and quotes the full report in its response. There is no automatic retry. If a paste succeeds but submission fails, inspect the destination before trying again to avoid duplicate messages. When a player appears finished but no report arrived, the supervising agent can inspect its pane with `screen.sh` and ask for the result.

## Resume or hand off a player

### Resume a stopped player

Resume restores a conversation in its existing worktree:

```bash
spawn.sh --repo PATH --branch feature/search --resume
spawn.sh --repo PATH --branch feature/search --resume --prompt "Next, add keyboard navigation."
```

The player receives a restart note and no task body; the reporting target tag is set again from the current orchestrator. You can supply a new message with `--prompt` or `--prompt-file`; the original task is not replayed.

The script chooses the CLI from `--agent`, then the session's `@orchestra-agent` tag. If neither is available, it tries Claude `--continue`. Only the specific no-conversation diagnostic triggers a fallback to the newest Codex conversation recorded for that worktree. Other errors stop the launch and leave a dead pane to inspect.

### Hand off a running player

Run `adopt.sh SESSION` to connect an existing player to the current supervising agent. The player must be idle at its input prompt. The script changes `@orchestra-orchestrator` and sends the player-skill invocation into the pane. The player continues in the same process, conversation, and worktree.

With no assignment text, the player reports its current task, completed work, remaining work, and questions; a finished player repeats its completion report. With assignment text, it takes on that task. Dead panes and bare shells cannot be adopted.

This example hands a player to the agent running in the `planning` tmux session:

```mermaid
sequenceDiagram
    participant Parent as Supervising agent in tmux:planning
    participant Adopt as adopt.sh
    participant Tags as Player's tmux session options
    participant Player as Running player agent
    participant Report as report.sh

    Parent->>Adopt: Run adopt.sh shop-feature-search
    Adopt->>Tags: set-option @orchestra-orchestrator tmux:planning
    Adopt->>Player: Send player-skill invocation
    Note over Player: Same agent process, conversation, and worktree

    Player->>Report: Run report.sh PROGRESS with handoff summary
    Report->>Tags: show-options @orchestra-orchestrator
    Tags-->>Report: tmux:planning
    Report->>Parent: Paste report into planning session and submit
    alt Transport accepts report
        Report->>Tags: set-option @orchestra-last-report to kind + timestamp
    else Delivery fails
        Report-->>Player: Exit nonzero; print target, reason, and full report to stderr
    end
```

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
