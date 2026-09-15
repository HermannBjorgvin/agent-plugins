#!/usr/bin/env bash
# Runs inside the player's pane (started by spawn.sh): reads the task body from the session's
# paste buffer and starts or resumes the harness. Options arrive through the environment, so no
# prompt text ever passes through a tmux or shell command line. Environment (all injected by
# spawn.sh through respawn-pane -e):
#
#   ORCHESTRA_SESSION      this player's tmux session name (a label; the session is identified
#                          by its tags, so the name is used as is and never parsed)
#   ORCHESTRA_SOCKET       socket of the tmux server holding it (the pane's own tmux environment
#                          is redirected to a scratch server, so every call passes -S)
#   ORCHESTRA_MODE         fresh | resume
#   ORCHESTRA_HARNESS      claude | codex | gemini | copilot | opencode | custom | auto (resume only)
#   ORCHESTRA_MODEL, ORCHESTRA_EFFORT, ORCHESTRA_PERMISSION_MODE   empty = not given
#   ORCHESTRA_COMMAND      custom harness command; receives the composed prompt as $PROMPT
#   ORCHESTRA_CLAUDE_SKILL Claude player invocation (defaults to /orchestra:player)
#
# The task body is the paste buffer orchestra-prompt-<session>, deleted once read. The harness
# that actually starts is recorded in the session's @orchestra-agent tag. The orchestrator target
# is not part of the prompt: report.sh reads @orchestra-orchestrator from the session.
#
# Resume never starts a fresh conversation: a harness that cannot find one exits nonzero and the
# pane stays for inspection (spawn.sh sets remain-on-exit). In auto mode Claude runs first under
# script(1) so its output can be checked for the exact "No conversation found to continue"
# diagnostic; only then is Codex tried, with the newest recorded conversation for this worktree.
set -u
. "$(dirname "$(realpath "$0")")/_lib.sh"
mode="${ORCHESTRA_MODE:-fresh}"; harness="${ORCHESTRA_HARNESS:-claude}"
model="${ORCHESTRA_MODEL:-}"; effort="${ORCHESTRA_EFFORT:-}"; perm="${ORCHESTRA_PERMISSION_MODE:-}"
session="${ORCHESTRA_SESSION:?ORCHESTRA_SESSION is required}"; sock="${ORCHESTRA_SOCKET:?ORCHESTRA_SOCKET is required}"
NO_CONVERSATION='No conversation found to continue'
RESTART_NOTE='Your session was restarted in this worktree; files and commits are intact, so do not redo finished work.'

fail() { echo "player launch: $*" >&2; exit 1; }
buf="$(prompt_buffer_name "$session")"
# show-buffer writes the bytes as they are; the command substitution drops the trailing newline
# spawn.sh adds (tmux never creates an empty buffer, and an empty body is allowed).
body="$(tmux -S "$sock" show-buffer -b "$buf" 2>/dev/null)" || fail "no task buffer $buf on $sock (rerun spawn.sh)"
tmux -S "$sock" delete-buffer -b "$buf" 2>/dev/null
remember() { tag_set "$sock" "$session" "$TAG_AGENT" "$1" 2>/dev/null; true; }
# <invocation> [restart note] <body>
preamble() {
  local inv; case "$1" in codex) inv='$player';; *) inv="${ORCHESTRA_CLAUDE_SKILL:-/orchestra:player}";; esac
  if [ "$mode" = resume ]; then
    printf '%s %s%s' "$inv" "$RESTART_NOTE" "${body:+$nl$nl$body}"
  else
    printf '%s%s' "$inv" "${body:+ $body}"
  fi
}
codex_effort_args() { [ -n "$effort" ] && printf '%s\n' -c "model_reasoning_effort=\"$effort\""; true; }

fresh() {
  local prompt; prompt="$(preamble "$1")"; remember "$1"
  case "$1" in
    claude)   exec claude ${perm:+--permission-mode "$perm"} ${model:+--model "$model"} ${effort:+--effort "$effort"} "$prompt";;
    codex)    exec codex ${model:+-m "$model"} $(codex_effort_args) "$prompt";;
    gemini)   exec gemini ${model:+-m "$model"} -i "$prompt";;
    copilot)  exec copilot ${model:+--model "$model"} -i "$prompt";;
    opencode) exec opencode ${model:+-m "$model"} --prompt "$prompt";;
  esac
  fail "unknown harness $1"
}

# Newest recorded Codex conversation whose cwd is this worktree (rollout files carry it in
# their session_meta line). Prints the UUID; fails when none exists.
codex_session_here() {
  local home="${CODEX_HOME:-$HOME/.codex}" here real f
  here="$PWD"; real="$(pwd -P)"
  while IFS= read -r f; do
    case "$(head -c 4096 "$f" | tr -d ' ')" in
      *"\"cwd\":\"$here\""*|*"\"cwd\":\"$real\""*)
        printf '%s\n' "$f" | sed -nE 's/.*-([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\.jsonl$/\1/p'
        return 0;;
    esac
  done < <(find "$home/sessions" -name 'rollout-*.jsonl' 2>/dev/null | sort -r)
  return 1
}

resume_codex() {
  local prompt id; prompt="$(preamble codex)"
  id="$(codex_session_here)" || fail "no Codex conversation is recorded for $PWD; nothing to resume (use a fresh spawn for a new task)"
  remember codex
  exec codex resume ${model:+-m "$model"} $(codex_effort_args) "$id" "$prompt"
}
resume_claude() {
  local prompt; prompt="$(preamble claude)"; remember claude
  exec claude --continue ${perm:+--permission-mode "$perm"} ${model:+--model "$model"} ${effort:+--effort "$effort"} "$prompt"
}
resume_auto() {
  command -v script >/dev/null || fail "cannot detect the harness without util-linux script(1); rerun with --agent claude or --agent codex"
  local log rc
  log="$(mktemp /tmp/orchestra-resume-probe.XXXXXX)" || fail "cannot create a probe log in /tmp"
  # The prompt and options travel in the environment; the sh -c string contains no user text.
  # script(1) runs the command through $SHELL: pin /bin/sh so a login shell's rc files cannot
  # reorder PATH or otherwise change which claude binary starts.
  PROMPT="$(preamble claude)" SHELL=/bin/sh script -qefc \
    'exec claude --continue ${ORCHESTRA_PERMISSION_MODE:+--permission-mode "$ORCHESTRA_PERMISSION_MODE"} ${ORCHESTRA_MODEL:+--model "$ORCHESTRA_MODEL"} ${ORCHESTRA_EFFORT:+--effort "$ORCHESTRA_EFFORT"} "$PROMPT"' "$log"
  rc=$?
  if [ $rc -ne 0 ] && grep -aq "$NO_CONVERSATION" "$log"; then
    rm -f "$log"
    echo "player launch: Claude has no conversation for this worktree; trying Codex" >&2
    resume_codex
  fi
  rm -f "$log"
  [ $rc = 0 ] && remember claude
  exit $rc
}

if [ "$harness" = custom ]; then
  PROMPT="$(preamble claude)"; export PROMPT; remember custom
  exec bash -c "${ORCHESTRA_COMMAND:?ORCHESTRA_COMMAND is required for the custom harness}"
fi
if [ "$mode" = fresh ]; then fresh "$harness"; fi
case "$harness" in
  claude)   resume_claude;;
  codex)    resume_codex;;
  auto)     resume_auto;;
  opencode) remember opencode; exec opencode --continue --prompt "$(preamble opencode)";;
  *)        fail "--resume is not supported for $harness; use a fresh spawn";;
esac
