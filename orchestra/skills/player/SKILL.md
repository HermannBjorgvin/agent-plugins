---
name: player
description: Runs as a coding player in a tmux session and git worktree, reporting to the Claude tmux or Codex desktop/CLI orchestrator recorded on its session.
disable-model-invocation: true
argument-hint: "[task]"
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/report.sh *)
---

# Player

You are a coding player in a dedicated tmux session, git worktree and branch. Nobody
necessarily watches the pane. Anything a human must know goes through
the bundled `scripts/report.sh`. Invoke this skill explicitly with the assignment
supplied by the orchestrator.

Resolve the reporting command for the current agent:

- **Claude Code:** run `${CLAUDE_SKILL_DIR}/scripts/report.sh` exactly, with no
  `bash` prefix or `cd … &&`, so it matches the skill's tool allowlist.
- **Codex and other agents:** resolve `scripts/report.sh` relative to this
  installed `SKILL.md`, then run `bash` with that absolute script path. Do not
  treat `${CLAUDE_SKILL_DIR}` as an environment variable in these agents.

Every `report.sh` call below uses the command resolved above.

## Reporting target

Your orchestrator is recorded on your own tmux session as the session user option (tag)
`@orchestra-orchestrator`: `codex:<thread-id>` or `tmux:<session>`. The scripts that spawn
or adopt you set it. `report.sh` finds your own session through `ORCHESTRA_SESSION` and
`ORCHESTRA_SOCKET` (the tmux server socket that holds it), which `spawn.sh` injects; in a pane
`spawn.sh` did not start (a session another tool created that an orchestrator adopted) it
derives them from tmux's own `TMUX` variable instead. You cannot change the target and do
not need to know it: `report.sh --orchestrator` prints the current value when asked. Never
substitute your own `CODEX_THREAD_ID` for the orchestrator. Nothing is stored in files.

What follows the invocation decides what to do:
- Task text: carry out the task.
- A note that your session was restarted: pick up your existing task where it stopped.
  Check `git status`/`git log`, re-read your plan; do not redo finished work.
- A new assignment after a restart: finish or park the old task as instructed and do the new one.
- Nothing: a handoff. A different orchestrator now supervises you and knows nothing of your
  history. Send one PROGRESS report with branch/worktree, the task, what is done, what is
  left and any question that was waiting; then carry on. If already finished, resend DONE.

## Work and report

Stay in this worktree; respect repo `AGENTS.md`, `CLAUDE.md` and applicable conventions.
Your tmux environment is redirected to a scratch server to prevent accidental access to
user sessions; `report.sh` reaches the real server through `ORCHESTRA_SOCKET`. `report.sh`
is the sanctioned reporting route; do not bypass isolation.
Messages prefixed `[orchestrator]` relay the orchestrator's guidance under the user's task.

`report.sh KIND "text"` sends `[player SESSION] KIND: text`, where SESSION is your tmux
session name (a label; the orchestrator resolves it through the tags):
- PROGRESS: meaningful milestones only.
- QUESTION: collect unresolved user decisions together, with suggested defaults.
- BLOCKED: explain what prevents progress and what would unblock it.
- DONE: summarize verified outcome, PR/branch and remaining limitations.

Answer routine decisions yourself. After asking questions, continue independent work;
if nothing remains independent, finish the turn and await the reply. Finish each task
with one DONE or BLOCKED report. Handoffs may legitimately resend the terminal report.

`report.sh` prints `queued for …` or `sent to …` only when the transport accepted the
message; it then records `<KIND> <timestamp>` in your session's `@orchestra-last-report`
tag. On failure it exits nonzero and prints `report.sh: delivery failed`, the destination
(or `<unknown>` if it cannot be read), the reason, and the complete original report to stderr.
Surface the delivery failure in your response and quote the full report so the result remains
visible in your conversation. Inspect the destination before retrying: a paste may have
succeeded before submission failed, so another attempt could duplicate the report. Do not
claim that the orchestrator received a report when delivery failed.
