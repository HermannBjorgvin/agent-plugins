#!/usr/bin/env bash
# Real-tmux smoke test for the orchestrator/player scripts. Uses a temporary git repository,
# an isolated tmux socket and fake claude/codex binaries; never touches user sessions or
# real repositories, and never calls a model. Session state is checked where the scripts keep
# it: session user options (tags) and paste buffers on the scratch server, never files. Session
# names are labels (<repo basename>-<branch>, suffixed when taken); foreign sessions wearing
# such a name are planted to check that only the tags identify a player.
#
# Usage: smoke_tmux.sh [skills-root]   default: this plugin's skills/ directory. The root may
# also be a personal installation (~/.claude/skills); the expected Claude player invocation
# defaults to the plugin namespace in both layouts.
set -u
ROOT="${1:-$(dirname "$(realpath "$0")")/../skills}"
O="$ROOT/orchestrator/scripts"; P="$ROOT/player/scripts"
INV=/orchestra:player
[ -f "$ROOT/../.claude-plugin/plugin.json" ] && INV="/$(sed -nE 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$ROOT/../.claude-plugin/plugin.json" | head -n1):player"
T="$(mktemp -d /tmp/orch-smoke.XXXXXX)"; SOCK="$T/tmux.sock"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
cleanup() { tmux -S "$SOCK" kill-server 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
tm() { tmux -S "$SOCK" "$@"; }
tag() { tm show-options -qv -t "=$1:" "$2"; }
STAMP='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'

# Fake harnesses: record argv and environment, then behave per FAKE_* files in $T.
mkdir -p "$T/bin" "$T/codex-home/sessions/2026/09/13"
for cli in claude codex; do cat > "$T/bin/$cli" <<FAKE
#!/usr/bin/env bash
T="$T"
{ printf 'cli=%s\n' "$cli"; for a in "\$@"; do printf 'arg=%s\n' "\$a"; done; printf 'env CLAUDECODE=%s CLAUDE_CONFIG_DIR=%s ANTHROPIC_API_KEY=%s CODEX_THREAD_ID=%s TMUX=%s TMUX_TMPDIR=%s\n' "\${CLAUDECODE:-}" "\${CLAUDE_CONFIG_DIR:-}" "\${ANTHROPIC_API_KEY:-}" "\${CODEX_THREAD_ID:-}" "\${TMUX:-}" "\${TMUX_TMPDIR:-}"; env | grep -E '^(ORCHESTRA_|PLAYER_|ORCHESTRATOR_)' | sed 's/^/env /'; } > "\$T/last-$cli"
cp "\$T/last-$cli" "\$T/last-call"
if [ -f "\$T/fake-$cli-noconv" ]; then echo 'No conversation found to continue'; exit 1; fi
if [ -f "\$T/fake-$cli-exit" ]; then exit "\$(cat "\$T/fake-$cli-exit")"; fi
exec cat >> "\$T/received-$cli"
FAKE
chmod +x "$T/bin/$cli"; done
export PATH="$T/bin:$PATH"
export CLAUDECODE=1 CLAUDE_CODE_CHILD_SESSION=1 CODEX_THREAD_ID=11111111-2222-3333-4444-555555555555
export CLAUDE_CONFIG_DIR="$T/claude-config" ANTHROPIC_API_KEY=fake-key CODEX_HOME="$T/codex-home"
for v in $(env | grep -oE '^(ORCHESTRA_|ORCHESTRATOR_|PLAYER_)[A-Z_]+'); do unset "$v"; done

# Temporary repository and an orchestrator session on the scratch server.
git init -q "$T/repo"; git -C "$T/repo" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
(unset TMUX TMUX_PANE; tm new-session -d -s parent -x 120 -y 30 -- "$T/bin/claude")
export TMUX="$SOCK,0,0"; unset TMUX_PANE
REPO="$(git -C "$T/repo" rev-parse --show-toplevel)"
S1="repo-feature-x"; S2="repo-feature-x-2"; W1="$T/repo/.claude/worktrees/feature-x"
GITDIR1() { git -C "$W1" rev-parse --absolute-git-dir; }
# A session some other program created, optionally tagged: `foreign NAME [tag value]...`.
foreign() { local n="$1"; shift; (unset TMUX TMUX_PANE; tm new-session -d -s "$n" -c "$T" -x 80 -y 20 -- sleep 300); while [ $# -ge 2 ]; do tm set-option -t "=$n:" "$1" "$2"; shift 2; done; }
# report.sh runs inside the player's pane in real use; here it is called from this shell with the
# same environment spawn.sh injects there.
player() { ORCHESTRA_SESSION="$S1" ORCHESTRA_SOCKET="$SOCK" bash "$P/report.sh" "$@"; }

echo "# fresh launch with a 40 KiB prompt"
big="$(head -c 40000 /dev/zero | tr '\0' 'x')"; printf 'Task: %s\nsecond line\nEND-OF-TASK\n' "$big" > "$T/task.txt"
bash "$O/spawn.sh" --repo "$T/repo" --branch feature/x --from HEAD --prompt-file "$T/task.txt" --no-node-modules --agent claude --model fable >"$T/spawn.out" 2>&1
check "spawn exits 0" "[ $? = 0 ]"
sleep 1.5
check "session exists" "tm has-session -t '=$S1'"
check "pane alive" "[ \"\$(tm display-message -p -t '=$S1:' '#{pane_dead}')\" = 0 ]"
check "prompt reached claude intact" "grep -q '^END-OF-TASK' '$T/last-claude' && grep -q '^second line' '$T/last-claude' && grep -q '^arg=$INV Task: x' '$T/last-claude'"
check "prompt does not name the orchestrator" "! grep -q 'reporting target' '$T/last-claude'"
check "explicit model/effort passed" "grep -q '^arg=fable' '$T/last-claude' && grep -q '^arg=high' '$T/last-claude'"
check "parent markers stripped" "grep -q 'env CLAUDECODE= ' '$T/last-claude' && grep -q 'CODEX_THREAD_ID= ' '$T/last-claude'"
check "config/auth preserved" "grep -q 'CLAUDE_CONFIG_DIR=$T/claude-config' '$T/last-claude' && grep -q 'ANTHROPIC_API_KEY=fake-key' '$T/last-claude'"
check "tmux isolated" "grep -q 'TMUX= TMUX_TMPDIR=/tmp/orchestra-agent-tmux' '$T/last-claude'"
check "ORCHESTRA_* environment injected" "grep -qx 'env ORCHESTRA_SESSION=$S1' '$T/last-claude' && grep -qx 'env ORCHESTRA_SOCKET=$SOCK' '$T/last-claude' && grep -qx 'env ORCHESTRA_MODE=fresh' '$T/last-claude'"
check "no PLAYER_/ORCHESTRATOR_/ORCHESTRA_PLAYER environment" "! grep -qE '^env (PLAYER_|ORCHESTRATOR_|ORCHESTRA_PLAYER)' '$T/last-claude'"
check "identity tags" "[ \"\$(tag $S1 @orchestra-spawner)\" = orchestra ] && [ \"\$(tag $S1 @orchestra-repo)\" = '$REPO' ] && [ \"\$(tag $S1 @orchestra-session-type)\" = worktree ] && [ \"\$(tag $S1 @orchestra-branch)\" = feature/x ]"
check "orchestrator tag" "[ \"\$(tag $S1 @orchestra-orchestrator)\" = tmux:parent ]"
check "harness tag" "[ \"\$(tag $S1 @orchestra-agent)\" = claude ]"
check "launching flag cleared" "[ -z \"\$(tag $S1 @orchestra-launching)\" ]"
check "prompt buffer consumed" "! tm list-buffers -F '#{buffer_name}' | grep -q '^orchestra-prompt-'"
check "no state files in the worktree git dir" "[ -z \"\$(ls \"\$(GITDIR1)\" | grep -E '^player-')\" ]"
check "spawn refuses running session" "! bash '$O/spawn.sh' --repo '$T/repo' --branch feature/x --prompt x --no-node-modules 2>/dev/null"

echo "# report.sh from the player to tmux:parent"
(cd "$W1" && player PROGRESS "hello from smoke") >"$T/report.out" 2>&1
check "report exits 0" "[ $? = 0 ] && grep -q 'sent to parent' '$T/report.out'"
sleep 0.5
check "parent received report under the session name" "grep -q '\[player $S1\] PROGRESS: hello from smoke' '$T/received-claude'"
check "last-report tag set" "tag $S1 @orchestra-last-report | grep -Eq '^PROGRESS $STAMP\$'"
check "--orchestrator prints the tag" "[ \"\$(player --orchestrator)\" = tmux:parent ]"
(cd "$W1" && player --orchestrator tmux:other >/dev/null 2>&1); check "player cannot rebind itself" "[ $? = 2 ] && [ \"\$(tag $S1 @orchestra-orchestrator)\" = tmux:parent ]"
(unset TMUX; tm kill-session -t "=parent")
tm show-options -t "=$S1:" > "$T/options-before-report"
(cd "$W1" && player DONE "gone parent") >"$T/report2.out" 2>"$T/report2.err"
check "gone parent -> nonzero, error on stderr" "[ $? = 1 ] && grep -qx 'report.sh: delivery failed' '$T/report2.err' && [ ! -s '$T/report2.out' ]"
check "error includes target, reason and report" "grep -qx 'Target: tmux:parent' '$T/report2.err' && grep -q '^Reason: orchestrator session parent is gone' '$T/report2.err' && grep -qF 'Report: [player $S1] DONE: gone parent' '$T/report2.err'"
(cd "$W1" && player BLOCKED "second"$'\n'"line") >"$T/report-multiline.out" 2>"$T/report-multiline.err"
check "failed report preserves multiple lines" "[ $? = 1 ] && grep -qF 'Report: [player $S1] BLOCKED: second' '$T/report-multiline.err' && grep -qx 'line' '$T/report-multiline.err'"
check "last-report unchanged by refused reports" "tag $S1 @orchestra-last-report | grep -q '^PROGRESS '"
tm show-options -t "=$S1:" > "$T/options-after-report"
check "failed deliveries do not change session options" "cmp -s '$T/options-before-report' '$T/options-after-report'"
(cd "$W1" && unset TMUX TMUX_PANE && ORCHESTRA_SOCKET="$SOCK" bash "$P/report.sh" DONE "no session") >"$T/report3.out" 2>"$T/report3.err"   # neither ORCHESTRA_SESSION nor TMUX
check "no player session -> error still includes original report" "[ $? = 1 ] && grep -qx 'Target: <unknown>' '$T/report3.err' && grep -q 'DONE: no session' '$T/report3.err'"
check "no mailbox written" "[ ! -e '$HOME/.claude/orchestrator-mail' ] || [ -z \"\$(find '$HOME/.claude/orchestrator-mail' -newer '$T/task.txt' -type f 2>/dev/null)\" ]"
(unset TMUX TMUX_PANE; tm new-session -d -s parent -x 120 -y 30 -- "$T/bin/claude")

echo "# listing"
bash "$O/sessions.sh" --all --json > "$T/sessions.json" 2>/dev/null
check "sessions.sh --json shows tags" "jq -e '.[] | select(.session == \"$S1\") | .name == \"$S1\" and .agent == \"claude\" and .orchestrator == \"tmux:parent\" and .branch == \"feature/x\" and .repo == \"$REPO\" and (.last_report | test(\"^PROGRESS $STAMP\$\"))' '$T/sessions.json' >/dev/null"
check "sessions.sh --json never lists the untagged parent" "! jq -e '.[] | select(.session == \"parent\")' '$T/sessions.json' >/dev/null"
check "sessions.sh columns" "bash '$O/sessions.sh' --repo '$T/repo' | head -n1 | grep -q 'SESSION *BRANCH *AGENT' && bash '$O/sessions.sh' --repo '$T/repo' | grep -q '$S1 *feature/x .*tmux:parent'"

echo "# targeting: by branch in a repo, by exact tagged name anywhere; never by prefix or sanitized form"
bash "$O/spawn.sh" --repo "$T/repo" --branch feature/x-2 --from HEAD --prompt "second" --no-node-modules >/dev/null 2>&1
sleep 1
bash "$O/send.sh" feature/x --repo "$T/repo" --raw "ping-one" >/dev/null && sleep 0.6
check "send.sh by branch hits the right session" "grep -q ping-one '$T/received-claude'"
bash "$O/send.sh" "$S1" "$(head -c 30000 /dev/zero | tr '\0' y)END" >/dev/null 2>&1; check "send.sh by exact name accepts 30 KiB" "[ $? = 0 ]"
check "screen.sh by branch" "bash '$O/screen.sh' feature/x --repo '$T/repo' >/dev/null"
check "screen.sh rejects a prefix" "! bash '$O/screen.sh' feature --repo '$T/repo' 2>/dev/null"
check "screen.sh rejects the sanitized branch" "! bash '$O/screen.sh' feature-x --repo '$T/repo' 2>/dev/null"
check "kill.sh rejects an unknown branch" "! bash '$O/kill.sh' feature --repo '$T/repo' 2>/dev/null && tm has-session -t '=$S1' && tm has-session -t '=$S2'"
printf 'leftover\n' | tm load-buffer -b "orchestra-prompt-$S2" -
bash "$O/kill.sh" feature/x-2 --repo "$T/repo" >/dev/null
check "kill.sh killed only feature/x-2" "! tm has-session -t '=$S2' 2>/dev/null && tm has-session -t '=$S1'"
check "kill.sh removed the leftover prompt buffer" "! tm list-buffers -F '#{buffer_name}' | grep -qx 'orchestra-prompt-$S2'"
check "spawn.sh --help prints comments only" "bash '$O/spawn.sh' --help | grep -q 'Usage: spawn.sh' && ! bash '$O/spawn.sh' --help | grep -qE '^(\\.|set |AGENT=)'"
check "report.sh usage prints comments only" "bash '$P/report.sh' 2>&1 | grep -q 'Usage: report.sh' && ! bash '$P/report.sh' 2>&1 | grep -qE '^(\\.|set )'"

echo "# labels collide, tags decide"
foreign repo-feature-y                                             # a stranger already wears the label feature/y would get
bash "$O/spawn.sh" --repo "$T/repo" --branch feature/y --from HEAD --prompt "collide" --no-node-modules --agent claude >"$T/spawn-y.out" 2>&1; sleep 1
check "spawn takes the next free suffix" "grep -q '^started *repo-feature-y-2\$' '$T/spawn-y.out' && [ \"\$(tag repo-feature-y-2 @orchestra-branch)\" = feature/y ] && grep -qx 'env ORCHESTRA_SESSION=repo-feature-y-2' '$T/last-claude'"
check "stranger left untagged" "[ -z \"\$(tag repo-feature-y @orchestra-spawner)\" ] && [ -z \"\$(tag repo-feature-y @orchestra-session-type)\" ]"
check "spawn again sees the player, not the label" "bash '$O/spawn.sh' --repo '$T/repo' --branch feature/y --prompt x --no-node-modules 2>&1 | grep -q 'running: repo-feature-y-2'"
bash "$O/send.sh" feature/y --repo "$T/repo" --raw "ping-y" >/dev/null && sleep 0.6
check "branch resolves to the suffixed session" "grep -q ping-y '$T/received-claude'"
check "kill.sh refuses the stranger by exact name" "! bash '$O/kill.sh' repo-feature-y --repo '$T/repo' 2>/dev/null && tm has-session -t '=repo-feature-y'"
check "send.sh and screen.sh refuse the stranger" "! bash '$O/send.sh' repo-feature-y --raw x 2>/dev/null && ! bash '$O/screen.sh' repo-feature-y 2>/dev/null"
bash "$O/sessions.sh" --all --json > "$T/sessions-y.json" 2>/dev/null
check "listing shows the player by tags and not the stranger" "jq -e '(map(.session) | index(\"repo-feature-y-2\")) and (map(.session) | index(\"repo-feature-y\") | not)' '$T/sessions-y.json' >/dev/null"
bash "$O/spawn.sh" --repo "$T/repo" --branch feature/y-2 --from HEAD --prompt "collide-2" --no-node-modules --agent claude >"$T/spawn-y2.out" 2>&1; sleep 1
check "suffix goes on the preferred label" "grep -q '^started *repo-feature-y-2-2\$' '$T/spawn-y2.out' && [ \"\$(tag repo-feature-y-2-2 @orchestra-branch)\" = feature/y-2 ]"
bash "$O/kill.sh" feature/y --repo "$T/repo" >/dev/null; bash "$O/kill.sh" feature/y-2 --repo "$T/repo" >/dev/null
check "kills by branch hit only the tagged sessions" "! tm has-session -t '=repo-feature-y-2' 2>/dev/null && ! tm has-session -t '=repo-feature-y-2-2' 2>/dev/null && tm has-session -t '=repo-feature-y'"
tm kill-session -t '=repo-feature-y'

echo "# adopt"
bash "$O/adopt.sh" feature/x --repo "$T/repo" --orchestrator tmux:parent "new assignment text" >"$T/adopt.out" 2>&1
check "adopt with text" "[ $? = 0 ] && sleep 0.6 && grep -q -F '$INV new assignment text' '$T/received-claude' && ! grep -q -F '$INV tmux:parent' '$T/received-claude'"
check "adopt set the orchestrator tag" "[ \"\$(tag $S1 @orchestra-orchestrator)\" = tmux:parent ] && [ \"\$(player --orchestrator)\" = tmux:parent ]"
# A plain shell at its prompt inside a player worktree, tagged as a player. /bin/sh has no startup
# files, so the pane is settled before adopt.sh inspects it.
(unset TMUX TMUX_PANE; tm new-session -d -s repo-shellonly -c "$W1" -x 80 -y 20 -- /bin/sh)
for kv in "@orchestra-spawner orchestra" "@orchestra-repo $REPO" "@orchestra-session-type worktree" "@orchestra-branch shellonly"; do tm set-option -t '=repo-shellonly:' $kv; done; sleep 0.5
check "adopt refuses shell pane" "! bash '$O/adopt.sh' shellonly --repo '$T/repo' --orchestrator tmux:other 2>/dev/null"
check "refused adopt left the tag alone" "[ -z \"\$(tag repo-shellonly @orchestra-orchestrator)\" ] && [ \"\$(tag $S1 @orchestra-orchestrator)\" = tmux:parent ]"
tm kill-session -t "=repo-shellonly"
# An agent-like pane (awk, not a shell) that nobody tagged: not ours, whatever its name says.
(unset TMUX TMUX_PANE; tm new-session -d -s repo-untagged -c "$W1" -x 80 -y 20 -- awk '{ print }'); sleep 0.5
check "adopt refuses an untagged session" "! bash '$O/adopt.sh' repo-untagged --repo '$T/repo' --orchestrator tmux:other 2>/dev/null && [ -z \"\$(tag repo-untagged @orchestra-orchestrator)\" ]"
check "kill refuses an untagged session" "! bash '$O/kill.sh' repo-untagged --repo '$T/repo' 2>/dev/null && tm has-session -t '=repo-untagged'"
tm kill-session -t "=repo-untagged"

echo "# adopt a pane Kirby created; report.sh inside it resolves the session from TMUX"
# Kirby tags its worktree sessions with spawner/repo/session-type/branch under its own label. The
# pane leader is awk (not a shell), so adopt.sh treats it as an agent; a REPORT line makes it run
# report.sh from inside the pane, where only TMUX/TMUX_PANE identify the session.
SA="repo-adopted"
(unset TMUX TMUX_PANE; tm new-session -d -s "$SA" -c "$W1" -x 100 -y 20 -- awk -v P="$P" -v T="$T" '/REPORT/ { system("bash \"" P "/report.sh\" DONE \"from inside\" > \"" T "/inside.out\" 2>&1"); next } { print >> (T "/received-inside") }')
for kv in "@orchestra-spawner kirby" "@orchestra-repo $REPO" "@orchestra-session-type worktree" "@orchestra-branch adopted"; do tm set-option -t "=$SA:" $kv; done
sleep 0.5
bash "$O/adopt.sh" adopted --repo "$T/repo" --orchestrator tmux:parent >/dev/null 2>&1; check "adopt of a Kirby pane by branch" "[ $? = 0 ] && [ \"\$(tag $SA @orchestra-orchestrator)\" = tmux:parent ]"
bash "$O/send.sh" adopted --repo "$T/repo" --raw "REPORT" >/dev/null 2>&1; sleep 1.5
check "report.sh inside the pane delivered under the session name" "grep -q 'sent to parent' '$T/inside.out' && grep -q '\[player $SA\] DONE: from inside' '$T/received-claude'"
check "last-report on the adopted session" "tag $SA @orchestra-last-report | grep -Eq '^DONE $STAMP\$'"
tm kill-session -t "=$SA"

echo "# resume: dead pane, restart note only, no task replay"
tm send-keys -t "=$S1:" C-d; sleep 0.8
check "pane dead after exit" "[ \"\$(tm display-message -p -t '=$S1:' '#{pane_dead}')\" = 1 ]"
bash "$O/spawn.sh" --repo "$T/repo" --branch feature/x --resume >"$T/resume.out" 2>&1; rc=$?
sleep 1
check "resume exits 0" "[ $rc = 0 ]"
check "claude --continue with the restart note only" "grep -q '^arg=--continue' '$T/last-claude' && grep -q \"^arg=$INV Your session was restarted\" '$T/last-claude' && grep -q 'finished work\\.\$' '$T/last-claude' && ! grep -q 'END-OF-TASK' '$T/last-claude'"
check "no model/effort on plain resume" "! grep -q '^arg=--model' '$T/last-claude' && ! grep -q '^arg=--effort' '$T/last-claude'"
check "resume does not name the target" "! grep -q 'reporting target' '$T/last-claude' && grep -qx 'env ORCHESTRA_MODE=resume' '$T/last-claude'"
check "resume keeps the orchestrator tag" "[ \"\$(tag $S1 @orchestra-orchestrator)\" = tmux:parent ]"

echo "# resume with a new assignment and explicit overrides"
tm send-keys -t "=$S1:" C-d; sleep 0.8
bash "$O/spawn.sh" --repo "$T/repo" --branch feature/x --resume --prompt "Now do the follow-up" --model opus --effort max >/dev/null 2>&1
sleep 1
check "new assignment sent" "grep -q 'Now do the follow-up' '$T/last-claude' && ! grep -q 'END-OF-TASK' '$T/last-claude'"
check "explicit overrides applied" "grep -q '^arg=opus' '$T/last-claude' && grep -q '^arg=max' '$T/last-claude'"

echo "# resume: auto chain (no agent tag) -> claude says no conversation -> codex by cwd"
tm send-keys -t "=$S1:" C-d; sleep 0.8
tm set-option -u -t "=$S1:" @orchestra-agent
touch "$T/fake-claude-noconv"; rm -f "$T/last-call"
uuid=0199a000-1111-7000-8000-000000000042
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$uuid" "$(cd "$W1" && pwd -P)" > "$T/codex-home/sessions/2026/09/13/rollout-2026-09-13T10-00-00-$uuid.jsonl"
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"/elsewhere"}}\n' 0199a000-1111-7000-8000-000000000099 > "$T/codex-home/sessions/2026/09/13/rollout-2026-09-13T11-00-00-0199a000-1111-7000-8000-000000000099.jsonl"
bash "$O/spawn.sh" --repo "$T/repo" --branch feature/x --resume >"$T/auto.out" 2>&1
sleep 2.5
[ -n "${SMOKE_DEBUG:-}" ] && { echo "--- auto.out ---"; cat "$T/auto.out"; echo "--- screen ---"; bash "$O/screen.sh" "$S1" --lines 12 | cut -c1-160; echo "--- last-call ---"; cat "$T/last-call" 2>/dev/null | head -5; }
check "codex resume with worktree uuid and prompt" "grep -q '^cli=codex' '$T/last-call' && grep -q '^arg=resume' '$T/last-call' && grep -q \"^arg=$uuid\" '$T/last-call' && grep -q '^arg=\$player Your session was restarted' '$T/last-call'"
check "codex harness recorded in the agent tag" "[ \"\$(tag $S1 @orchestra-agent)\" = codex ]"
rm -f "$T/fake-claude-noconv"

echo "# resume: claude fails for another reason -> no codex fallback"
tm send-keys -t "=$S1:" C-d; sleep 0.8
tm set-option -u -t "=$S1:" @orchestra-agent
echo 1 > "$T/fake-claude-exit"; rm -f "$T/last-call"
bash "$O/spawn.sh" --repo "$T/repo" --branch feature/x --resume >/dev/null 2>&1
sleep 2
check "claude ran, codex did not" "grep -q '^cli=claude' '$T/last-call' && ! grep -q '^cli=codex' '$T/last-call'"
check "pane left dead for inspection" "[ \"\$(tm display-message -p -t '=$S1:' '#{pane_dead}')\" = 1 ]"
check "failed launch leaves no agent tag" "[ -z \"\$(tag $S1 @orchestra-agent)\" ]"
rm -f "$T/fake-claude-exit"

echo "# resume: explicit --agent codex without any recorded conversation -> refuses, no fresh start"
rm -f "$T/codex-home/sessions/2026/09/13/rollout-2026-09-13T10-00-00-$uuid.jsonl"; rm -f "$T/last-call"
bash "$O/spawn.sh" --repo "$T/repo" --branch feature/x --resume --agent codex >/dev/null 2>&1
sleep 1.5
check "codex not invoked, pane dead" "[ ! -e '$T/last-call' ] && [ \"\$(tm display-message -p -t '=$S1:' '#{pane_dead}')\" = 1 ]"
check "diagnostic visible on screen" "bash '$O/screen.sh' '$S1' | grep -q 'no Codex conversation'"

echo "# resume after the session is gone entirely"
tm kill-session -t "=$S1"
bash "$O/spawn.sh" --repo "$T/repo" --branch feature/x --resume --agent claude >/dev/null 2>&1; rc=$?
sleep 1
check "resume recreates session" "[ $rc = 0 ] && tm has-session -t '=$S1' && grep -q '^arg=--continue' '$T/last-claude'"
check "recreated session carries the tags" "[ \"\$(tag $S1 @orchestra-spawner)\" = orchestra ] && [ \"\$(tag $S1 @orchestra-session-type)\" = worktree ] && [ \"\$(tag $S1 @orchestra-branch)\" = feature/x ] && [ \"\$(tag $S1 @orchestra-orchestrator)\" = tmux:parent ]"
check "still no state files" "[ -z \"\$(ls \"\$(GITDIR1)\" | grep -E '^player-')\" ]"

echo "# resume when a stranger has taken the label meanwhile"
tm kill-session -t "=$S1"; foreign "$S1"
bash "$O/spawn.sh" --repo "$T/repo" --branch feature/x --resume --agent claude >"$T/resume2.out" 2>&1; rc=$?
sleep 1
check "resume recreates under the next label" "[ $rc = 0 ] && grep -q '^started *$S2\$' '$T/resume2.out' && grep -qx 'env ORCHESTRA_SESSION=$S2' '$T/last-claude' && [ \"\$(tag $S2 @orchestra-branch)\" = feature/x ]"
check "stranger untouched" "tm has-session -t '=$S1' && [ -z \"\$(tag $S1 @orchestra-spawner)\" ]"

echo; echo "passed $pass, failed $fail"; [ $fail = 0 ]
