# Shared routing for Claude and Codex orchestrators. Never infer a parent from a player's own ID.
# tmux session names: tmux itself rewrites "." and ":" but otherwise allows most characters.
normalize_target() {
  case "$1" in
    codex:*) [[ "${1#codex:}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || { echo "invalid Codex thread ID: ${1#codex:}" >&2; return 2; };;
    tmux:*) [[ -n "${1#tmux:}" && ! "${1#tmux:}" =~ [:[:cntrl:]] ]] || { echo "invalid tmux session name: ${1#tmux:}" >&2; return 2; };;
    *) normalize_target "tmux:$1"; return;;
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
    normalize_target "tmux:$(tmux display-message -p '#S')"
  else
    echo 'Cannot identify orchestrator; pass --orchestrator codex:<thread-id> or tmux:<session>.' >&2
    return 2
  fi
}

# Exact tmux targeting. `=name` is exact for has-session, but pane/window commands (send-keys,
# display-message, respawn-pane, set-option, capture-pane) reject it; `=name:` is exact for all.
tmux_target() { printf '=%s:' "$1"; }

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
# pane_owned_by_agent <tmux-cmd-prefix...> <session>: true when the session's pane is alive and an
# agent (not a shell) is at the terminal. The prefix lets callers pick a socket (tmux -S PATH).
pane_owned_by_agent() {
  local session="${@: -1}" cmd pid
  set -- "${@:1:$#-1}"
  [ "$("$@" display-message -p -t "$(tmux_target "$session")" '#{pane_dead}' 2>/dev/null)" = 0 ] || return 1
  cmd="$("$@" display-message -p -t "$(tmux_target "$session")" '#{pane_current_command}' 2>/dev/null)"
  case "$cmd" in
    sh|bash|zsh|fish|dash|"")
      pid="$("$@" display-message -p -t "$(tmux_target "$session")" '#{pane_pid}' 2>/dev/null)"
      pane_has_agent "$pid";;
    *) return 0;;
  esac
}
