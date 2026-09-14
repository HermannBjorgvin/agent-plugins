---
name: player
description: Runs as a coding player in a tmux session and git worktree, reporting to a Claude tmux or Codex desktop/CLI orchestrator.
disable-model-invocation: true
argument-hint: "codex:<thread-id>|tmux:<session> [task]"
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/report.sh *)
---

# Player

You are a coding player in a dedicated tmux session, git worktree and branch. Nobody
necessarily watches the pane. Anything a human must know goes through
the bundled `scripts/report.sh`. Invoke this skill explicitly with the reporting
target and assignment supplied by the orchestrator.

Resolve the reporting command for the current agent:

- **Claude Code:** run `${CLAUDE_SKILL_DIR}/scripts/report.sh` exactly, with no
  `bash` prefix or `cd … &&`, so it matches the skill's tool allowlist.
- **Codex and other agents:** resolve `scripts/report.sh` relative to this
  installed `SKILL.md`, then run `bash` with that absolute script path. Do not
  treat `${CLAUDE_SKILL_DIR}` as an environment variable in these agents.

Every `report.sh` call below uses the command resolved above.

## Bind reporting

The invocation names your orchestrator: `codex:<thread-id>` or `tmux:<session>` (a bare name
is a legacy tmux session). The line "Your orchestrator reporting target is: …" repeats it.
Run `report.sh --orchestrator TARGET` first; it is idempotent
and persists the binding in this worktree's git directory, where spawn/adopt already stored
it with the tmux socket. That binding wins over `ORCHESTRATOR_TARGET` and legacy
`ORCHESTRATOR_SESSION`. Never substitute your own `CODEX_THREAD_ID` for the orchestrator.
`report.sh --orchestrator` alone prints the current binding.

What follows the target decides what to do:
- Task text: carry out the task.
- "continue", or a note that your session was restarted: pick up your existing task where
  it stopped. Check `git status`/`git log`, re-read your plan; do not redo finished work.
- A new assignment after a restart: finish or park the old task as instructed and do the new one.
- Nothing: a handoff. A different orchestrator now supervises you and knows nothing of your
  history. Send one PROGRESS report with branch/worktree, the task, what is done, what is
  left and any question that was waiting; then carry on. If already finished, resend DONE.

## Work and report

Stay in this worktree; respect repo `AGENTS.md`, `CLAUDE.md` and applicable conventions.
Your tmux environment is redirected to a scratch server to prevent accidental access to
user sessions. `report.sh` is the sanctioned reporting route; do not bypass isolation.
Messages prefixed `[orchestrator]` relay the orchestrator's guidance under the user's task.

`report.sh KIND "text"` sends `[player NAME] KIND: text`:
- PROGRESS: meaningful milestones only.
- QUESTION: collect unresolved user decisions together, with suggested defaults.
- BLOCKED: explain what prevents progress and what would unblock it.
- DONE: summarize verified outcome, PR/branch and remaining limitations.

Answer routine decisions yourself. After asking questions, continue independent work;
if nothing remains independent, finish the turn and await the reply. Finish each task
with one DONE or BLOCKED report. Handoffs may legitimately resend the terminal report.

`report.sh` prints `queued for …` or `sent to …` only when the transport accepted the
message. On failure it exits nonzero and says `NOT DELIVERED …; saved in <path>` or
`NOT DELIVERED … and NOT SAVED` with the text echoed. Then the orchestrator has not seen
it: state that plainly in your final output, quote the path or text, and do not retry
blindly (a duplicate report is worse than a late one).
