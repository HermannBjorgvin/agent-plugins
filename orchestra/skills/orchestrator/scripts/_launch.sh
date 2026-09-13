#!/usr/bin/env bash
# Runs inside the player's pane (started by spawn.sh): builds the prompt from the persisted task
# body and starts or resumes the harness. Everything arrives through the environment, so no
# prompt text ever passes through a tmux or shell command line.
#
#   PLAYER_MODE         fresh | resume
#   PLAYER_HARNESS      claude | codex | gemini | copilot | opencode | custom | auto (resume only)
#   PLAYER_MODEL, PLAYER_EFFORT, PLAYER_PERM   empty = not given (resume: CLI settings apply)
#   PLAYER_CMD          custom harness command; receives the composed prompt as $PROMPT
#   PLAYER_PROMPT_FILE  task body written by spawn.sh
#   PLAYER_CLAUDE_SKILL Claude player invocation (/player, or /<plugin>:player from a plugin)
#   ORCHESTRATOR_TARGET reporting destination named in the preamble
#
# Resume never starts a fresh conversation: a harness that cannot find one exits nonzero and the
# pane stays for inspection (spawn.sh sets remain-on-exit). In auto mode Claude runs first under
# script(1) so its output can be checked for the exact "No conversation found to continue"
# diagnostic; only then is Codex tried, with the newest recorded conversation for this worktree.
set -u
mode="${PLAYER_MODE:-fresh}"; harness="${PLAYER_HARNESS:-claude}"
model="${PLAYER_MODEL:-}"; effort="${PLAYER_EFFORT:-}"; perm="${PLAYER_PERM:-}"
orch="${ORCHESTRATOR_TARGET:?ORCHESTRATOR_TARGET is required}"
body="$(cat "${PLAYER_PROMPT_FILE:?PLAYER_PROMPT_FILE is required}")" || exit 1
gitdir="$(git rev-parse --absolute-git-dir 2>/dev/null || true)"
NO_CONVERSATION='No conversation found to continue'

fail() { echo "player launch: $*" >&2; exit 1; }
remember() { [ -n "$gitdir" ] && printf '%s\n' "$1" > "$gitdir/player-agent" 2>/dev/null; true; }
preamble() {
  local inv; case "$1" in codex) inv='$player';; *) inv="${PLAYER_CLAUDE_SKILL:-/player}";; esac
  if [ "$mode" = resume ]; then
    printf '%s %s\n\nYour orchestrator reporting target is: %s. Your session was restarted in this worktree; files and commits are intact, so do not redo finished work.\n\n%s' "$inv" "$orch" "$orch" "$body"
  else
    printf '%s %s\n\nYour orchestrator reporting target is: %s\n\n%s' "$inv" "$orch" "$orch" "$body"
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
  log="$(mktemp /tmp/kirby-resume-probe.XXXXXX)" || fail "cannot create a probe log in /tmp"
  # The prompt and options travel in the environment; the sh -c string contains no user text.
  # script(1) runs the command through $SHELL: pin /bin/sh so a login shell's rc files cannot
  # reorder PATH or otherwise change which claude binary starts.
  PLAYER_FULL_PROMPT="$(preamble claude)" SHELL=/bin/sh script -qefc \
    'exec claude --continue ${PLAYER_PERM:+--permission-mode "$PLAYER_PERM"} ${PLAYER_MODEL:+--model "$PLAYER_MODEL"} ${PLAYER_EFFORT:+--effort "$PLAYER_EFFORT"} "$PLAYER_FULL_PROMPT"' "$log"
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
  PROMPT="$(preamble claude)"; export PROMPT
  exec bash -c "${PLAYER_CMD:?PLAYER_CMD is required for the custom harness}"
fi
if [ "$mode" = fresh ]; then fresh "$harness"; fi
case "$harness" in
  claude)   resume_claude;;
  codex)    resume_codex;;
  auto)     resume_auto;;
  opencode) remember opencode; exec opencode --continue --prompt "$(preamble opencode)";;
  *)        fail "--resume is not supported for $harness; use a fresh spawn";;
esac
