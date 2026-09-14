# Shared helpers for the orchestrator scripts. Harness-neutral: git + tmux + coreutils only.
set -u

# The repo a script acts on: --repo <path> (parsed by each script into ORCH_REPO) or the
# current directory. Every git call goes through g so both cases behave the same.
ORCH_REPO="${ORCH_REPO:-}"
g() { if [ -n "$ORCH_REPO" ]; then git -C "$ORCH_REPO" "$@"; else git "$@"; fi; }
in_repo() { g rev-parse --git-dir >/dev/null 2>&1; }

# Root of the MAIN checkout, even when run from inside a linked worktree: the
# common git dir lives in the main checkout, so its parent is the main root.
# Falling back to --show-toplevel covers repos too old for --path-format.
repo_root() {
  local common
  if common="$(g rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
    dirname "$common"
  else
    g rev-parse --show-toplevel 2>/dev/null || { [ -n "$ORCH_REPO" ] && printf %s "$ORCH_REPO" || pwd; }
  fi
}

# The repository's default branch as a remote ref (origin/master, origin/main, …),
# freshly fetched when possible; empty string when it cannot be determined.
default_branch_ref() {
  local ref
  ref="$(g rev-parse --abbrev-ref origin/HEAD 2>/dev/null)" ||
    [ "${DRY:-0}" = 1 ] || ref="$(g remote show origin 2>/dev/null | sed -n 's/^ *HEAD branch: /origin\//p')"
  [ -n "${ref:-}" ] || for b in master main; do
    g rev-parse -q --verify "origin/$b" >/dev/null 2>&1 && { ref="origin/$b"; break; }
  done
  [ "${DRY:-0}" = 1 ] || [ -z "${ref:-}" ] || g fetch -q origin "${ref#origin/}" 2>/dev/null
  printf %s "${ref:-}"
}

# tmux sessions are namespaced by repo: sha256(absolute repo root)[0:16]. The prefix and
# hash are identifiers shared with an external session manager (Kirby): printf %s hashes
# exactly the bytes its createHash().update(root) does (no newline). Do not change them.
project_key() { printf %s "$1" | sha256sum | cut -c1-16; }
session_prefix() { printf 'kirby-%s-' "$(project_key "$(repo_root)")"; }
# Any repo's player session (kirby-<16 hex>-<name>); kirby-term-shell-* are the user's own.
PLAYER_RE='^kirby-[0-9a-f]{16}-'
is_player_session() { printf %s "$1" | grep -Eq "$PLAYER_RE"; }
all_player_sessions() { tmux ls -F '#{session_name}' 2>/dev/null | grep -E "$PLAYER_RE" || true; }

# Branch → session name replaces "/" with "-"; tmux then forbids "." and ":".
session_name_for_branch() { local s="${1//\//-}"; s="${s//./-}"; printf %s "${s//:/-}"; }
tmux_name_for_branch() { printf '%s%s' "$(session_prefix)" "$(session_name_for_branch "$1")"; }
# Worktree location under the main checkout.
worktree_dir_for_branch() { printf '.claude/worktrees/%s' "${1//\//-}"; }

# Accept the full tmux name (kirby-<key>-feature-x) for any repo, or the short name
# (feature-x): first in this repo (--repo or cwd), otherwise wherever it is unique. Matching is
# exact: tmux prefix matching would otherwise let "feature" hit "feature-2".
resolve_session() {
  local name="$1" cand
  case "$name" in kirby-*) printf %s "$name"; return;; esac
  if in_repo; then cand="$(session_prefix)$name"; tmux has-session -t "=$cand" 2>/dev/null && { printf %s "$cand"; return; }; fi
  cand="$(all_player_sessions | grep -E -- "-$(printf %s "$name" | sed 's/[][\.*^$]/\\&/g')\$" || true)"
  case "$(printf '%s\n' "$cand" | grep -c .)" in
    1) printf %s "$cand";;
    0) in_repo && printf %s "$(session_prefix)$name" || { echo "resolve_session: no player session named $name on this machine" >&2; exit 1; };;
    *) echo "resolve_session: $name is ambiguous, use the full name:" >&2; printf '  %s\n' $cand >&2; exit 1;;
  esac
}
# Exact-match check for a resolved name; prints a uniform error.
session_exists() { tmux has-session -t "=$1" 2>/dev/null || { echo "no such session: $1" >&2; return 1; }; }

# A pane's repo, for listing: a player worktree lives at <root>/.claude/worktrees/<x>,
# so strip that; otherwise the path itself. Printed relative to $HOME.
repo_of_path() { local p="${1%%/.claude/worktrees/*}"; printf %s "${p/#$HOME\//}"; }

# Visible pane text, trailing whitespace trimmed, runs of blank lines collapsed.
screen_text() { tmux capture-pane -p -t "$1" 2>/dev/null | sed -e 's/[[:space:]]*$//' | awk 'NF{blank=0} !NF{blank++} blank<2'; }

# Every agent runs with TMUX unset and TMUX_TMPDIR on a scratch dir, so nothing it runs —
# tests included — can reach the socket that hosts the user's live sessions.
AGENT_TMUX_TMPDIR=/tmp/kirby-agent-tmux

# Parent-session markers that must not reach a player. A Claude started under its parent's
# CLAUDECODE/CLAUDE_CODE_CHILD_SESSION treats itself as a nested child and stops saving its
# transcript (so --continue later finds nothing); CODEX_THREAD_ID would masquerade as the player's
# parent. Only these known markers are removed: configuration and credentials such as
# CLAUDE_CONFIG_DIR (selected per directory by the user's claude wrapper), ANTHROPIC_API_KEY and
# CODEX_HOME are deliberately inherited.
PARENT_SESSION_MARKERS=(CLAUDECODE CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID CLAUDE_CODE_SESSION_ATTENDED
  CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_CODE_EXECPATH
  CLAUDE_CODE_NO_FLICKER CLAUDE_PID CLAUDE_EFFORT CODEX_THREAD_ID CODEX_SESSION_ID)

# Deliver multi-line text to a pane as one bracketed paste. The text goes through load-buffer on
# stdin: tmux rejects command lines over ~16 KiB, which set-buffer/-e/send-keys all count against.
# Usage: paste_into <session> <text> [tmux args…]   (extra args select a socket: -S PATH)
paste_into() {
  local session="$1" text="$2"; shift 2
  printf '%s' "$text" | tmux "$@" load-buffer -b "orch-$$" - || return 1
  tmux "$@" paste-buffer -p -d -b "orch-$$" -t "$(tmux_target "$session")" || return 1
  sleep 0.3
  tmux "$@" send-keys -t "$(tmux_target "$session")" Enter
}

# Where these scripts really live: entry points reached through a symlink (the Codex
# installation links here) resolve to the same files, so the sibling player skill is found
# next to this one in every layout. Both skills install together.
ORCH_SCRIPTS="$(dirname "$(realpath "$0")")"
PLAYER_SCRIPTS="$ORCH_SCRIPTS/../../player/scripts"
[ -f "$PLAYER_SCRIPTS/_routing.sh" ] || { echo "orchestrator: the player skill's scripts are missing at $PLAYER_SCRIPTS (install both skills)" >&2; exit 1; }
. "$PLAYER_SCRIPTS/_routing.sh"

# The Claude skill that turns a pane into a player: /<plugin>:player when these scripts run
# from a Claude Code plugin (skills/*/scripts under a .claude-plugin manifest), /player for a
# personal skill. Codex players are always activated with the $orchestra:player mention.
claude_player_invocation() {
  local manifest="$ORCH_SCRIPTS/../../../.claude-plugin/plugin.json" name=""
  [ -f "$manifest" ] && name="$(sed -nE 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$manifest" | head -n1)"
  if [ -n "$name" ]; then printf '/%s:player' "$name"; else printf '/player'; fi
}
