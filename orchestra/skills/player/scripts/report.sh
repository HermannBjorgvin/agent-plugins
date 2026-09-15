#!/usr/bin/env bash
# Send one message to the orchestrator as `[player <session>] KIND: text`, where <session> is
# this player's tmux session name (a label chosen at spawn; never parsed).
#
# Usage: report.sh PROGRESS|QUESTION|BLOCKED|DONE <text…>
#        report.sh --orchestrator          print the current reporting target
#
# The target (codex:<thread-id> or tmux:<session>) is the @orchestra-orchestrator tag on this
# player's own tmux session, set by spawn.sh and adopt.sh; a player cannot change it. The
# session and the socket of the server holding it come from ORCHESTRA_SESSION and
# ORCHESTRA_SOCKET (injected by spawn.sh; the pane's own tmux environment points at a scratch
# server, so every call here passes -S), or from TMUX in a pane spawn.sh did not start (a
# Kirby session adopted by adopt.sh). No file is read or written.
# Delivery is reported only when the transport accepted the message; then @orchestra-last-report
# is set to "<KIND> <ISO-8601 UTC>". Failed delivery exits nonzero and prints the target, reason,
# and complete original report to stderr so the player can handle the failure. A failed submit
# may follow a successful paste; inspect before retrying to avoid duplicates. Nothing retries.
set -eu
. "$(dirname "$(realpath "$0")")/_routing.sh"
player_session_context || { player_session=""; player_socket=""; }
session="$player_session"; sock="$player_socket"; name="${session:-$(basename "$(pwd)")}"
if [ "${1:-}" = "--orchestrator" ]; then
  [ $# -eq 1 ] || { echo 'report.sh: the reporting target is the @orchestra-orchestrator tag on this session, set by spawn.sh and adopt.sh; a player cannot rebind itself' >&2; exit 2; }
  [ -n "$session" ] || { echo 'report.sh: neither ORCHESTRA_SESSION nor TMUX names a player session; not running in a player pane' >&2; exit 2; }
  target="$(tag_get "$sock" "$session" "$TAG_ORCHESTRATOR")"; printf '%s\n' "${target:-<unset>}"; exit
fi
[ $# -ge 2 ] || { sed -n '2,17p' "$0" >&2; exit 2; }
kind="$1"; shift
case "$kind" in PROGRESS|QUESTION|BLOCKED|DONE) ;; *) echo "report.sh: KIND must be PROGRESS, QUESTION, BLOCKED or DONE" >&2; exit 2;; esac
msg="[player $name] $kind: $*"
destination=""
# Keep the full destination and report intact even when tmux is unreachable; never retries.
delivery_failed() {
  printf 'report.sh: delivery failed\nTarget: %s\nReason: %s\nReport: %s\n' \
    "${destination:-<unknown>}" "$1" "$msg" >&2
  exit 1
}
delivered() {
  tag_set "$sock" "$session" "$TAG_LAST_REPORT" "$kind $(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null ||
    echo "report.sh: delivered, but could not set $TAG_LAST_REPORT on $session" >&2
}
[ -n "$session" ] || delivery_failed 'neither ORCHESTRA_SESSION nor TMUX names a player session; not running in a player pane'
destination="$(tag_get "$sock" "$session" "$TAG_ORCHESTRATOR")"
# No fallback to CODEX_THREAD_ID: that is the player's own conversation, not its parent.
[ -n "$destination" ] || delivery_failed "orchestrator target is unset or unreachable ($TAG_ORCHESTRATOR on $session)"
normalize_target "$destination" >/dev/null 2>&1 || delivery_failed 'invalid orchestrator target'
target="$destination"
case "$target" in
  codex:*)
    if codex queue --thread "${target#codex:}" --message "$msg"; then delivered; echo "queued for $target"; exit 0; fi
    delivery_failed 'Codex queue refused the message; inspect before retrying to avoid duplicate reports';;
  tmux:*) target="${target#tmux:}";;
esac
t() { tmux_on "$sock" "$@"; }
t has-session -t "=$target" 2>/dev/null || delivery_failed "orchestrator session $target is gone or unreachable"
# Would the paste be run as a shell command? Only an agent at the terminal may receive it.
pane_owned_by_agent "$sock" "$target" || delivery_failed "a shell owns $target now, not an agent"
# One bracketed paste (-p) keeps embedded newlines from submitting early; the buffer is loaded
# from stdin because tmux rejects command lines over ~16 KiB. The pause lets a slow UI ingest
# the paste before Enter.
tt="$(tmux_target "$target")"
printf '%s' "$msg" | t load-buffer -b "player-$$" - || delivery_failed "tmux could not load the message"
# errexit is live inside the brace group: cleanup must not exit before the error is printed.
t paste-buffer -p -d -b "player-$$" -t "$tt" || { t delete-buffer -b "player-$$" 2>/dev/null || :; delivery_failed "tmux could not paste into $target"; }
sleep 0.3
t send-keys -t "$tt" Enter || delivery_failed "tmux could not submit the message in $target; the paste succeeded, inspect before retrying"
delivered
echo "sent to $target"
