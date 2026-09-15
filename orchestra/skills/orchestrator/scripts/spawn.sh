#!/usr/bin/env bash
# Create a git worktree + tmux session and start an agent in it, or resume a stopped one.
#
# Usage: spawn.sh --branch <name> (--prompt-file <f> | --prompt <text>)      fresh launch
#        spawn.sh --branch <name> --resume [--prompt <text> | --prompt-file <f>]
#                 [--repo <path>]             the repo to spawn into; defaults to the
#                                             cwd's repo. Any path inside it will do.
#                 [--agent claude|codex|gemini|copilot|opencode]  (fresh default claude)
#                 [--effort low|medium|high|xhigh|max] (Claude/Codex)
#                 [--model M]                 Claude: opus; Codex: gpt-6-astra
#                 [--permission-mode MODE]    Claude only; otherwise CLI settings apply
#                 [--cmd "COMMAND"]           custom harness; receives $PROMPT
#                 [--from REF]                base for a new branch; default origin/HEAD
#                 [--orchestrator TARGET]     codex:<thread-id> or tmux:<session>
#                                             auto: current Codex ID, then current tmux
#                 [--no-node-modules] [--dry-run]
# Fresh defaults: Claude opus/high (fable/high for --model fable), Codex gpt-6-astra/medium,
# other Codex models high. --dry-run resolves local refs without fetching or writing.
#
# --resume restarts the player's conversation in its existing worktree; the session may be
# a dead pane or gone entirely. The launcher adds a restart note; give --prompt for a new
# assignment. The original task is never replayed. Harness: --agent, else the session's
# @orchestra-agent tag, else Claude --continue and, only when Claude reports "No conversation
# found to continue", Codex (the newest recorded Codex conversation whose cwd is this
# worktree). Any other failure stops with a dead pane for inspection; nothing starts a fresh
# conversation silently. --model/--effort are applied on resume only when given; otherwise the
# CLI's restored/configured settings apply.
#
# Naming (see _lib.sh): worktree at <main checkout>/.claude/worktrees/<branch with / → ->;
# the tmux session is a label, <repo basename>-<branch> with "/", "." and ":" replaced by "-"
# and a -2, -3, … suffix when any session already has that name. The name is chosen once and
# never parsed: the session is found again through its tags (repo + branch), so --resume works
# whatever the label. Worktrees always land under the MAIN checkout, even when spawn.sh is
# invoked from inside another worktree.
#
# Session state lives on the tmux session as user options (see _routing.sh for the names):
# @orchestra-spawner/-repo/-session-type/-branch (identity, written once at creation),
# @orchestra-orchestrator (reporting target), @orchestra-agent (harness) and
# @orchestra-launching (placeholder marker), all set before anything else sees the session. The task body is
# loaded into the paste buffer orchestra-prompt-<session> from stdin and read by _launch.sh
# inside the pane, so prompt size is not bounded by tmux's ~16 KiB command limit and nothing
# is written to disk. The launcher prefixes it with the player invocation: $player for Codex,
# and for Claude the plugin-namespaced skill (/<plugin>:player), with ORCHESTRA_CLAUDE_SKILL=/player
# for a standalone Claude skill install. Only the known parent-session markers are removed from
# the player's environment (see _lib.sh); CLAUDE_CONFIG_DIR, ANTHROPIC_API_KEY and CODEX_HOME
# are inherited. The agent runs with TMUX unset and TMUX_TMPDIR on a scratch directory, so
# tests it runs cannot reach the user's tmux; ORCHESTRA_SOCKET names the real server for
# the launcher and report.sh.
. "$(dirname "$(realpath "$0")")/_lib.sh"
AGENT=""; MODEL=""; EFFORT=""; PERM=""; CMD=""; FROM=""; LINK_NM=1; DRY=0; RESUME=0; BRANCH=""; PROMPT=""; PFILE=""; ORCH=""
while [ $# -gt 0 ]; do case "$1" in
  --branch) BRANCH="$2"; shift;; --prompt-file) PFILE="$2"; shift;; --prompt) PROMPT="$2"; shift;;
  --agent) AGENT="$2"; shift;; --model) MODEL="$2"; shift;; --effort) EFFORT="$2"; shift;; --permission-mode) PERM="$2"; shift;;
  --cmd) CMD="$2"; shift;; --from) FROM="$2"; shift;; --no-node-modules) LINK_NM=0;;
  --orchestrator) ORCH="$2"; shift;; --repo) ORCH_REPO="$2"; shift;;
  --dry-run) DRY=1;; --resume) RESUME=1;; -h|--help) sed -n '2,48p' "$0"; exit 0;;
  *) echo "spawn.sh: unknown argument $1" >&2; exit 2;; esac; shift; done
[ -n "$BRANCH" ] || { echo "spawn.sh: --branch is required" >&2; exit 2; }
git check-ref-format --branch "$BRANCH" >/dev/null || exit 2
in_repo || { echo "spawn.sh: ${ORCH_REPO:-$PWD} is not inside a git repo; pass --repo <path>" >&2; exit 1; }
if [ -n "$PFILE" ]; then PROMPT="$(cat "$PFILE")" || exit 1; fi
if [ -z "$PROMPT" ] && [ $RESUME = 0 ]; then echo "spawn.sh: task prompt is required (--prompt or --prompt-file)" >&2; exit 2; fi
command -v tmux >/dev/null || { echo "spawn.sh: tmux is not installed" >&2; exit 1; }
case "$AGENT" in ""|claude|codex|gemini|copilot|opencode) ;; *) echo "spawn.sh: unknown --agent $AGENT (use --cmd for other harnesses)" >&2; exit 2;; esac
if [ -n "$EFFORT" ]; then
  case "$EFFORT" in low|medium|high|xhigh|max) ;; *) echo "spawn.sh: invalid --effort: $EFFORT" >&2; exit 2;; esac
  case "${AGENT:-claude}" in claude|codex) ;; *) echo "spawn.sh: --effort only supports claude and codex" >&2; exit 2;; esac
fi

# Resolve before stripping parent identity from the player's environment.
ORCH="$(resolve_orchestrator "$ORCH")" || exit 2
ORCH_SOCK="${TMUX:-}"; ORCH_SOCK="${ORCH_SOCK%%,*}"
ORCH_SOCK="${ORCH_SOCK:-${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/default}"
t() { tmux_on "$ORCH_SOCK" "$@"; }        # -u -S: reads are exact in any locale
tag() { tag_set "$ORCH_SOCK" "$name" "$@"; }

LAUNCHER="$(realpath "$ORCH_SCRIPTS/_launch.sh")"
CLAUDE_INVOCATION="$(claude_player_invocation)"
root="$(repo_root)"
dir="$(worktree_dir_for_branch "$BRANCH")"

# Resolve first: the session for (repo, branch) is whatever carries those tags, under any name.
# What already exists: a dead pane (resumable), a live placeholder from a failed launch
# (reusable), a running player (refuse), or nothing (a name is chosen at creation).
EXISTING=none
if name="$(find_player_session "$root" "$BRANCH")"; then      # before TMUX is unset: the same server ORCH_SOCK names
  tt="$(tmux_target "$name")"
  if [ "$(t display-message -p -t "$tt" '#{pane_dead}')" = 1 ]; then EXISTING=dead
  elif [ "$(tag_get "$ORCH_SOCK" "$name" "$TAG_LAUNCHING")" = 1 ]; then EXISTING=placeholder
  else EXISTING=running; fi
fi
case "$EXISTING" in
  running) echo "spawn.sh: session already exists and is running: $name (kill.sh it first, or adopt.sh it)" >&2; exit 1;;
  dead) [ $RESUME = 1 ] || { echo "spawn.sh: $name has a dead player; use --resume, or kill.sh it for a fresh start" >&2; exit 1; };;
esac
if [ $RESUME = 1 ] && [ ! -d "$root/$dir" ]; then
  echo "spawn.sh: nothing to resume: worktree $root/$dir does not exist" >&2; exit 1
fi

# New branches start from the repository's default branch (freshly fetched), never
# from whatever the invoking checkout happens to have as HEAD — the orchestrator
# often runs inside a feature worktree whose commits must not leak into the agent's
# branch. --from overrides for deliberate stacking. Resume never creates a branch.
if [ -z "$FROM" ] && [ $RESUME = 0 ] && [ ! -d "$root/$dir" ]; then
  FROM="$(default_branch_ref)"
  [ -n "$FROM" ] || { echo "spawn.sh: could not resolve the default branch; pass --from <ref>" >&2; exit 1; }
fi

# Harness and settings. Fresh launches fill in the presets; resumes pass only what was given.
MODE=fresh; [ $RESUME = 1 ] && MODE=resume
HARNESS="$AGENT"
if [ $RESUME = 1 ] && [ -z "$HARNESS" ]; then
  [ "$EXISTING" = none ] || HARNESS="$(tag_get "$ORCH_SOCK" "$name" "$TAG_AGENT")"
  case "$HARNESS" in claude|codex|gemini|copilot|opencode) ;; *) HARNESS=auto;; esac
fi
[ $RESUME = 1 ] || HARNESS="${HARNESS:-claude}"
if [ $RESUME = 0 ]; then
  case "$HARNESS" in
    claude) MODEL="${MODEL:-opus}"; EFFORT="${EFFORT:-high}";;
    codex)  MODEL="${MODEL:-gpt-6-astra}"; EFFORT="${EFFORT:-$(case "$MODEL" in gpt-6-astra) echo medium;; *) echo high;; esac)}";;
  esac
fi
[ -n "$CMD" ] && HARNESS=custom
case "$HARNESS" in
  auto) command -v claude >/dev/null || command -v codex >/dev/null || { echo "spawn.sh: neither claude nor codex is on PATH" >&2; exit 1; };;
  custom) ;;
  *) command -v "$HARNESS" >/dev/null || { echo "spawn.sh: $HARNESS is not on PATH" >&2; exit 1; };;
esac

# Environment: the launcher runs under env(1) with the parent-session markers removed and
# tmux redirected to the scratch server. Nothing user-controlled enters this command string.
strip=(); for v in "${PARENT_SESSION_MARKERS[@]}"; do strip+=(-u "$v"); done
guard="$(printf '%q ' env -u TMUX -u TMUX_PANE "${strip[@]}" "TMUX_TMPDIR=$AGENT_TMUX_TMPDIR")"
shell_cmd="${guard}$(printf '%q' bash) $(printf '%q' "$LAUNCHER")"

desc="$HARNESS"
case "$HARNESS" in
  auto) desc="claude --continue, then codex resume if Claude finds no conversation";;
  custom) desc="$CMD";;
  *) [ $RESUME = 1 ] && desc="$HARNESS (resume)"; [ -n "$MODEL" ] && desc="$desc model=$MODEL"; [ -n "$EFFORT" ] && desc="$desc effort=$EFFORT"; [ -n "$PERM" ] && desc="$desc permission-mode=$PERM";;
esac
[ "$EXISTING" = none ] && name="$(session_label "$root" worktree "$BRANCH")"     # preferred label; the free one is picked at creation
printf 'repo      %s\nbranch    %s%s\nworktree  %s/%s\ntmux      %s (%s)\nreports   %s\nmode      %s\ncommand   %s\nprompt    %s\n' \
  "$root" "$BRANCH" "${FROM:+ (from $FROM)}" "$root" "$dir" "$name" "$EXISTING" "$ORCH" "$MODE" "$desc" "$(printf %s "$PROMPT" | head -c 80 | tr '\n' ' ')" | cut -c1-200
[ $DRY = 1 ] && exit 0

cd "$root" || exit 1
if [ -d "$dir" ]; then
  [ "$(git -C "$dir" rev-parse --show-toplevel)" = "$root/$dir" ] &&
  [ "$(git -C "$dir" branch --show-current)" = "$BRANCH" ] || {
    echo 'spawn.sh: existing worktree does not match requested branch' >&2; exit 1;
  }
else
  # New branch from FROM; if the branch already exists, check it out instead.
  git worktree add -b "$BRANCH" "$dir" "$FROM" 2>/dev/null || git worktree add "$dir" "$BRANCH" || exit 1
fi
# Independent copy (reflinks when available); dependency writes cannot affect another checkout.
# npm keeps version-conflicting deps in per-workspace node_modules (apps/x/node_modules,
# libs/y/node_modules); missing those reads as a broken library, so copy them too.
if [ $LINK_NM = 1 ] && [ -d node_modules ]; then
  while IFS= read -r nm; do
    [ -e "$dir/$nm" ] || { mkdir -p "$dir/$(dirname "$nm")"; cp -a --reflink=auto "$nm" "$dir/$nm"; }
  done < <(find . -maxdepth 4 -type d -name node_modules -not -path './node_modules/*' -not -path './.claude/*' -not -path '*/node_modules/*/node_modules' | sed 's#^\./##')
fi
mkdir -p "$AGENT_TMUX_TMPDIR"

unset TMUX TMUX_PANE
# Created DETACHED under the first free label. 220x50 is only the initial size; whatever
# attaches later resizes the pane. If no server is running, this call starts one — with the
# markers stripped, so nothing of the orchestrator's own agent session leaks into every future
# pane. The identity tags go on before anything else can observe the session; they are written
# by the creator only, so a resume never rewrites them. The placeholder exists so remain-on-exit
# is already set when the real command starts and catches startup failures.
CREATED=0
if [ "$EXISTING" = none ]; then
  label="$name"
  while :; do
    name="$(free_session_name "$ORCH_SOCK" "$label")"
    env "${strip[@]}" tmux -S "$ORCH_SOCK" new-session -d -s "$name" -c "$root/$dir" -x 220 -y 50 && break
    # Lost a race for the name (it exists now): probe again from the preferred label, so a second
    # lost race yields -3, not -2-2. Anything else is fatal.
    t has-session -t "=$name" 2>/dev/null || { echo "spawn.sh: tmux could not create session $name" >&2; exit 1; }
  done
  CREATED=1
  tt="$(tmux_target "$name")"
  tag "$TAG_SPAWNER" orchestra && tag "$TAG_REPO" "$root" && tag "$TAG_SESSION_TYPE" "$SESSION_TYPE_WORKTREE" && tag "$TAG_BRANCH" "$BRANCH" ||
    { t kill-session -t "=$name" 2>/dev/null; echo "spawn.sh: could not tag session $name; removed" >&2; exit 1; }
fi
buf="$(prompt_buffer_name "$name")"
tag "$TAG_LAUNCHING" 1 || exit 1
tag "$TAG_ORCHESTRATOR" "$ORCH" || exit 1
case "$HARNESS" in auto) ;; *) tag "$TAG_AGENT" "$HARNESS";; esac
t set-option -t "$tt" status off
t set-option -t "$tt" remain-on-exit on
# The task body, from stdin. tmux never creates an empty buffer, so a newline is appended
# (the launcher's command substitution drops it again); an empty body is then still a buffer.
printf '%s\n' "$PROMPT" | t load-buffer -b "$buf" - || { echo "spawn.sh: tmux could not load the task prompt into buffer $buf" >&2; exit 1; }
if ! t respawn-pane -k -t "$tt" -c "$root/$dir" \
  -e "PATH=$PATH" -e "HOME=$HOME" \
  -e "ORCHESTRA_SESSION=$name" -e "ORCHESTRA_SOCKET=$ORCH_SOCK" \
  -e "ORCHESTRA_MODE=$MODE" -e "ORCHESTRA_HARNESS=$HARNESS" -e "ORCHESTRA_MODEL=$MODEL" -e "ORCHESTRA_EFFORT=$EFFORT" \
  -e "ORCHESTRA_PERMISSION_MODE=$PERM" -e "ORCHESTRA_COMMAND=$CMD" -e "ORCHESTRA_CLAUDE_SKILL=$CLAUDE_INVOCATION" \
  -- /bin/bash -c "$shell_cmd"; then
  t delete-buffer -b "$buf" 2>/dev/null
  if [ $CREATED = 1 ]; then
    t kill-session -t "=$name" 2>/dev/null
    echo "spawn.sh: tmux could not launch $name; placeholder session removed, worktree kept. Fix the cause and rerun." >&2
  else
    echo "spawn.sh: tmux could not launch $name; the previous pane is left as is. Fix the cause and rerun with --resume." >&2
  fi
  exit 1
fi
tag_unset "$ORCH_SOCK" "$name" "$TAG_LAUNCHING"
echo "started   $name"
