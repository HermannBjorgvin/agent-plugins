# Shared by the orchestrator scripts, the launcher and report.sh. Harness-neutral: bash + tmux
# + coreutils only. Owns the names of the tmux session user options ("tags") and the exact
# targeting rules; every other script reads the names from here.

# --- Session user options: the contract shared with Kirby ------------------------------------
# Every fact about a player session lives on the session itself, as a user option that dies with
# the session and is readable by anyone who can reach the server: no files. Set with
# `set-option -t '=name:' @orchestra-agent claude`; read with `show-options -qv` (empty when unset)
# or as #{@orchestra-agent} in a format. Absent means unset; no sentinels. Values contain no
# tabs or newlines.
TAG_SPAWNER=@orchestra-spawner            # kirby | orchestra: whichever program created the session
TAG_REPO=@orchestra-repo                  # main checkout, absolute and symlink-resolved
TAG_SESSION_TYPE=@orchestra-session-type  # worktree (players) | shell | agent (Kirby's terminal tabs)
TAG_BRANCH=@orchestra-branch              # worktree sessions: the branch, unsanitized (feature/x)
TAG_ORCHESTRATOR=@orchestra-orchestrator  # reporting target: codex:<uuid> | tmux:<session>
TAG_AGENT=@orchestra-agent                # claude | codex | gemini | copilot | opencode | custom
TAG_LAUNCHING=@orchestra-launching        # 1 while the placeholder pane exists; unset once the harness started
TAG_LAST_REPORT=@orchestra-last-report    # "<KIND> <ISO-8601 UTC>" of the last report a transport accepted
SESSION_TYPE_WORKTREE=worktree            # a session's name is a label; spawner + session-type say whose it is
nl=$'\n'                                  # assigned once: ANSI-C quoting inside ${x:+...} is not portable

# Exact tmux targeting. `=name` is exact for has-session, but pane/window commands (send-keys,
# display-message, respawn-pane, set-option, capture-pane) reject it; `=name:` is exact for all.
tmux_target() { printf '=%s:' "$1"; }

# tmux sanitizes what it prints unless the client is in UTF-8 mode, which it infers from the names
# of LC_ALL/LC_CTYPE/LANG: outside a UTF-8 locale control characters (such as the tabs between
# listing fields) and non-ASCII come back as "_". `tmux -u` forces UTF-8 output whatever the locale, so every call goes through it.
# tmux_on <socket> <args…>: tmux on one server. An empty socket means the current server (the
# one $TMUX names, else the default); a path is passed as -S so a process whose tmux environment
# is redirected (every player pane) still reaches the server that holds its session.
tmux_on() {
  local sock="$1"; shift
  if [ -n "$sock" ]; then tmux -u -S "$sock" "$@"; else tmux -u "$@"; fi
}
# tag_get <socket> <session> <tag>: the value, empty when unset or unreachable; never fails.
tag_get()   { tmux_on "$1" show-options -qv -t "$(tmux_target "$2")" "$3" 2>/dev/null || :; }
tag_set()   { tmux_on "$1" set-option -t "$(tmux_target "$2")" "$3" "$4"; }
tag_unset() { tmux_on "$1" set-option -u -t "$(tmux_target "$2")" "$3"; }

# player_session_context: the player's own session name and the socket of the server holding it,
# into player_session and player_socket (lowercase: not environment). spawn.sh injects
# ORCHESTRA_SESSION/ORCHESTRA_SOCKET into the panes it starts. A pane it did not start (a Kirby
# session adopted by adopt.sh) keeps tmux's own TMUX variable, so the session comes from
# `display-message -p '#S'` and the socket from TMUX. The name is used as is (it is a label,
# never parsed). Fails when neither source is available.
player_session_context() {
  player_session="${ORCHESTRA_SESSION:-}"; player_socket="${ORCHESTRA_SOCKET:-}"
  if [ -z "$player_session" ] && [ -n "${TMUX:-}" ]; then
    player_socket="${TMUX%%,*}"
    player_session="$(tmux_on "$player_socket" display-message -p '#S' 2>/dev/null)" || player_session=""
  fi
  [ -n "$player_session" ]
}

# --- Reporting targets -----------------------------------------------------------------------
# codex:<thread-id> or tmux:<session>; nothing else. Never infer a parent from a player's own ID.
# tmux session names: tmux itself rewrites "." and ":" but otherwise allows most characters.
normalize_target() {
  case "$1" in
    codex:*) [[ "${1#codex:}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || { echo "invalid Codex thread ID: ${1#codex:}" >&2; return 2; };;
    tmux:*) [[ -n "${1#tmux:}" && ! "${1#tmux:}" =~ [:[:cntrl:]] ]] || { echo "invalid tmux session name: ${1#tmux:}" >&2; return 2; };;
    *) echo "invalid orchestrator target: $1 (use codex:<thread-id> or tmux:<session>)" >&2; return 2;;
  esac
  printf '%s' "$1"
}
# An explicit target wins. A Codex ID identifies the orchestrator only when the caller is not a
# Claude session: Claude marks itself with CLAUDECODE, and any CODEX_* ID it sees is inherited from
# some unrelated Codex ancestor, so its players would otherwise report to the wrong conversation.
resolve_orchestrator() {
  if [[ -n "${1:-}" ]]; then normalize_target "$1"
  elif [[ -z "${CLAUDECODE:-}" && -n "${CODEX_THREAD_ID:-${CODEX_SESSION_ID:-}}" ]]; then
    normalize_target "codex:${CODEX_THREAD_ID:-$CODEX_SESSION_ID}"
  elif [[ -n "${TMUX:-}" ]]; then
    normalize_target "tmux:$(tmux_on "" display-message -p '#S')"
  else
    echo 'Cannot identify orchestrator; pass --orchestrator codex:<thread-id> or tmux:<session>.' >&2
    return 2
  fi
}

# --- Pane ownership --------------------------------------------------------------------------
# Is an agent reading that pane, or would typed text land in a shell? `pane_current_command`
# reports the pane's process leader, which stays `bash`/`sh` when the agent runs under a wrapper
# shell (spawn.sh launches every player that way), so inspect the process tree: only a known agent
# binary in the foreground process group counts. A suspended agent (STAT T) or one in the
# background leaves the shell reading the tty.
is_agent_name() { case "$1" in claude|codex|gemini|copilot|opencode) return 0;; *) return 1;; esac; }
pane_has_agent() {
  local pid="$1" child comm argv0 stat
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    comm="$(ps -o comm= -p "$child" 2>/dev/null)"
    argv0="$(ps -o args= -p "$child" 2>/dev/null | awk '{print $1}')"
    stat="$(ps -o stat= -p "$child" 2>/dev/null)"
    case "$stat" in
      T*) ;;
      *+*) is_agent_name "$comm" && return 0
           is_agent_name "${argv0##*/}" && return 0;;
    esac
    pane_has_agent "$child" && return 0
  done
  return 1
}
# pane_owned_by_agent <socket> <session>: true when the session's pane is alive and an agent (not a
# shell) is at the terminal. The socket selects the server as in tmux_on.
pane_owned_by_agent() {
  local sock="$1" session="$2" cmd pid
  [ "$(tmux_on "$sock" display-message -p -t "$(tmux_target "$session")" '#{pane_dead}' 2>/dev/null)" = 0 ] || return 1
  cmd="$(tmux_on "$sock" display-message -p -t "$(tmux_target "$session")" '#{pane_current_command}' 2>/dev/null)"
  case "$cmd" in
    sh|bash|zsh|fish|dash|"")
      pid="$(tmux_on "$sock" display-message -p -t "$(tmux_target "$session")" '#{pane_pid}' 2>/dev/null)"
      pane_has_agent "$pid";;
    *) return 0;;
  esac
}
