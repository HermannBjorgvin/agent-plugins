#!/usr/bin/env bash
# Real-tmux smoke test for the orchestrator/player scripts. Uses a temporary git repository,
# an isolated tmux socket and fake claude/codex binaries; never touches user sessions or
# real repositories, and never calls a model.
#
# Usage: smoke_tmux.sh [skills-root]   default: this plugin's skills/ directory. The root may
# also be a personal installation (~/.claude/skills); the expected Claude player invocation
# follows the layout (/<plugin>:player under a plugin manifest, /player otherwise).
set -u
ROOT="${1:-$(dirname "$(realpath "$0")")/../skills}"
O="$ROOT/orchestrator/scripts"; P="$ROOT/player/scripts"
INV=/player
[ -f "$ROOT/../.claude-plugin/plugin.json" ] && INV="/$(sed -nE 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$ROOT/../.claude-plugin/plugin.json" | head -n1):player"
T="$(mktemp -d /tmp/orch-smoke.XXXXXX)"; SOCK="$T/tmux.sock"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
cleanup() { tmux -S "$SOCK" kill-server 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
tm() { tmux -S "$SOCK" "$@"; }

# Fake harnesses: record argv and environment, then behave per FAKE_* files in $T.
mkdir -p "$T/bin" "$T/codex-home/sessions/2026/09/13"
for cli in claude codex; do cat > "$T/bin/$cli" <<FAKE
#!/usr/bin/env bash
T="$T"
{ printf 'cli=%s\n' "$cli"; for a in "\$@"; do printf 'arg=%s\n' "\$a"; done; printf 'env CLAUDECODE=%s CLAUDE_CONFIG_DIR=%s ANTHROPIC_API_KEY=%s CODEX_THREAD_ID=%s TMUX=%s TMUX_TMPDIR=%s\n' "\${CLAUDECODE:-}" "\${CLAUDE_CONFIG_DIR:-}" "\${ANTHROPIC_API_KEY:-}" "\${CODEX_THREAD_ID:-}" "\${TMUX:-}" "\${TMUX_TMPDIR:-}"; } > "\$T/last-$cli"
cp "\$T/last-$cli" "\$T/last-call"
if [ -f "\$T/fake-$cli-noconv" ]; then echo 'No conversation found to continue'; exit 1; fi
if [ -f "\$T/fake-$cli-exit" ]; then exit "\$(cat "\$T/fake-$cli-exit")"; fi
exec cat >> "\$T/received-$cli"
FAKE
chmod +x "$T/bin/$cli"; done
export PATH="$T/bin:$PATH"
export CLAUDECODE=1 CLAUDE_CODE_CHILD_SESSION=1 CODEX_THREAD_ID=11111111-2222-3333-4444-555555555555
export CLAUDE_CONFIG_DIR="$T/claude-config" ANTHROPIC_API_KEY=fake-key CODEX_HOME="$T/codex-home"
export ORCHESTRATOR_MAIL_DIR="$T/mail"
unset ORCHESTRATOR_TARGET ORCHESTRATOR_SESSION ORCHESTRATOR_THREAD_ID PLAYER_NAME

# Temporary repository and an orchestrator session on the scratch server.
git init -q "$T/repo"; git -C "$T/repo" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
(unset TMUX TMUX_PANE; tm new-session -d -s parent -x 120 -y 30 -- "$T/bin/claude")
export TMUX="$SOCK,0,0"; unset TMUX_PANE
key="$(printf %s "$(cd "$T/repo" && pwd -P)" | sha256sum | cut -c1-16)"
S1="kirby-$key-feature-x"; S2="kirby-$key-feature-x-2"; W1="$T/repo/.claude/worktrees/feature-x"

echo "# fresh launch with a 40 KiB prompt"
big="$(head -c 40000 /dev/zero | tr '\0' 'x')"; printf 'Task: %s\nEND-OF-TASK\n' "$big" > "$T/task.txt"
bash "$O/spawn.sh" --repo "$T/repo" --branch feature/x --from HEAD --prompt-file "$T/task.txt" --no-node-modules --agent claude --model fable >"$T/spawn.out" 2>&1
check "spawn exits 0" "[ $? = 0 ]"
sleep 1.5
check "session exists" "tm has-session -t '=$S1'"
check "pane alive" "[ \"\$(tm display-message -p -t '=$S1:' '#{pane_dead}')\" = 0 ]"
check "prompt reached claude intact" "grep -q 'END-OF-TASK' '$T/last-claude' && grep -c x '$T/last-claude' >/dev/null && grep -q '^arg=$INV tmux:parent' '$T/last-claude'"
check "explicit model/effort passed" "grep -q '^arg=fable' '$T/last-claude' && grep -q '^arg=high' '$T/last-claude'"
check "parent markers stripped" "grep -q 'env CLAUDECODE= ' '$T/last-claude' && grep -q 'CODEX_THREAD_ID= ' '$T/last-claude'"
check "config/auth preserved" "grep -q 'CLAUDE_CONFIG_DIR=$T/claude-config' '$T/last-claude' && grep -q 'ANTHROPIC_API_KEY=fake-key' '$T/last-claude'"
check "tmux isolated" "grep -q 'TMUX= TMUX_TMPDIR=/tmp/kirby-agent-tmux' '$T/last-claude'"
check "harness tag" "[ \"\$(tm show-options -v -t '=$S1:' @player-agent)\" = claude ]"
check "launching flag cleared" "[ -z \"\$(tm show-options -v -t '=$S1:' @player-launching 2>/dev/null)\" ]"
check "spawn refuses running session" "! bash '$O/spawn.sh' --repo '$T/repo' --branch feature/x --prompt x --no-node-modules 2>/dev/null"

echo "# report.sh from the worktree to tmux:parent"
(cd "$W1" && bash "$P/report.sh" PROGRESS "hello from smoke") >"$T/report.out" 2>&1
check "report exits 0" "[ $? = 0 ] && grep -q 'sent to parent' '$T/report.out'"
sleep 0.5
check "parent received report" "grep -q 'PROGRESS: hello from smoke' '$T/received-claude'"
check "no global binding written" "[ ! -e '$HOME/.claude/orchestrator-mail/targets/player-orchestrator' ]"
(cd "$T" && bash "$P/report.sh" --orchestrator tmux:parent >/dev/null 2>&1); check "bind outside a worktree refused" "[ $? = 2 ]"
(unset TMUX; tm kill-session -t "=parent")
(cd "$W1" && bash "$P/report.sh" DONE "gone parent") >"$T/report2.out" 2>&1
check "gone parent -> nonzero, saved" "[ $? = 1 ] && grep -q 'NOT DELIVERED' '$T/report2.out' && grep -q 'DONE: gone parent' '$T/mail/tmux_parent.log'"
ORCHESTRATOR_MAIL_DIR=/proc/nowhere bash -c "cd '$W1' && bash '$P/report.sh' DONE unsavable" >"$T/report3.out" 2>&1
check "unwritable mailbox -> NOT SAVED surfaced" "grep -q 'NOT SAVED' '$T/report3.out' && grep -q 'DONE: unsavable' '$T/report3.out'"
(unset TMUX TMUX_PANE; tm new-session -d -s parent -x 120 -y 30 -- "$T/bin/claude")

echo "# exact session targeting"
bash "$O/spawn.sh" --repo "$T/repo" --branch feature/x-2 --from HEAD --prompt "second" --no-node-modules >/dev/null 2>&1
sleep 1
bash "$O/send.sh" feature-x --repo "$T/repo" --raw "ping-one" >/dev/null && sleep 0.6
check "send.sh hits exact session" "grep -q ping-one '$T/received-claude'"
bash "$O/send.sh" "$S1" "$(head -c 30000 /dev/zero | tr '\0' y)END" >/dev/null 2>&1; check "send.sh accepts 30 KiB" "[ $? = 0 ]"
check "screen.sh exact" "bash '$O/screen.sh' feature-x --repo '$T/repo' >/dev/null"
check "screen.sh rejects missing" "! bash '$O/screen.sh' feature --repo '$T/repo' 2>/dev/null"
check "kill.sh rejects missing prefix" "! bash '$O/kill.sh' feature --repo '$T/repo' 2>/dev/null"
bash "$O/kill.sh" feature-x-2 --repo "$T/repo" >/dev/null
check "kill.sh killed only feature-x-2" "! tm has-session -t '=$S2' 2>/dev/null && tm has-session -t '=$S1'"

echo "# adopt"
bash "$O/adopt.sh" feature-x --repo "$T/repo" --orchestrator tmux:parent "new assignment text" >"$T/adopt.out" 2>&1
check "adopt with text" "[ $? = 0 ] && sleep 0.6 && grep -q -F '$INV tmux:parent new assignment text' '$T/received-claude'"
check "adopt persisted binding" "[ \"\$(cd '$W1' && bash '$P/report.sh' --orchestrator)\" = tmux:parent ]"
# A plain shell at its prompt inside a player worktree (never the caller's cwd: a refused adopt
# must not rebind whatever repository this test happens to run from). /bin/sh has no startup
# files, so the pane is settled before adopt.sh inspects it.
(unset TMUX TMUX_PANE; tm new-session -d -s shellonly -c "$W1" -x 80 -y 20 -- /bin/sh)
tm rename-session -t '=shellonly' "kirby-$key-shellonly"; sleep 0.5
check "adopt refuses shell pane" "! bash '$O/adopt.sh' shellonly --repo '$T/repo' --orchestrator tmux:other 2>/dev/null"
check "refused adopt left the binding alone" "[ \"\$(cd '$W1' && bash '$P/report.sh' --orchestrator)\" = tmux:parent ]"
tm kill-session -t "=kirby-$key-shellonly"

echo "# resume: dead pane, default continue, no task replay"
tm send-keys -t "=$S1:" C-d; sleep 0.8
check "pane dead after exit" "[ \"\$(tm display-message -p -t '=$S1:' '#{pane_dead}')\" = 1 ]"
bash "$O/spawn.sh" --repo "$T/repo" --branch feature/x --resume >"$T/resume.out" 2>&1; rc=$?
sleep 1
check "resume exits 0" "[ $rc = 0 ]"
check "claude --continue with 'continue' only" "grep -q '^arg=--continue' '$T/last-claude' && grep -q 'continue$' '$T/last-claude' && ! grep -q 'END-OF-TASK' '$T/last-claude'"
check "no model/effort on plain resume" "! grep -q '^arg=--model' '$T/last-claude' && ! grep -q '^arg=--effort' '$T/last-claude'"
check "resume names the target" "grep -q 'Your orchestrator reporting target is: tmux:parent' '$T/last-claude'"

echo "# resume with a new assignment and explicit overrides"
tm send-keys -t "=$S1:" C-d; sleep 0.8
bash "$O/spawn.sh" --repo "$T/repo" --branch feature/x --resume --prompt "Now do the follow-up" --model opus --effort max >/dev/null 2>&1
sleep 1
check "new assignment sent" "grep -q 'Now do the follow-up' '$T/last-claude' && ! grep -q 'END-OF-TASK' '$T/last-claude'"
check "explicit overrides applied" "grep -q '^arg=opus' '$T/last-claude' && grep -q '^arg=max' '$T/last-claude'"

echo "# resume: auto chain (no tag, no record) -> claude says no conversation -> codex by cwd"
tm send-keys -t "=$S1:" C-d; sleep 0.8
tm set-option -u -t "=$S1:" @player-agent; rm -f "$(git -C "$W1" rev-parse --absolute-git-dir)/player-agent"
touch "$T/fake-claude-noconv"; rm -f "$T/last-call"
uuid=0199a000-1111-7000-8000-000000000042
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$uuid" "$(cd "$W1" && pwd -P)" > "$T/codex-home/sessions/2026/09/13/rollout-2026-09-13T10-00-00-$uuid.jsonl"
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"/elsewhere"}}\n' 0199a000-1111-7000-8000-000000000099 > "$T/codex-home/sessions/2026/09/13/rollout-2026-09-13T11-00-00-0199a000-1111-7000-8000-000000000099.jsonl"
bash "$O/spawn.sh" --repo "$T/repo" --branch feature/x --resume >"$T/auto.out" 2>&1
sleep 2.5
[ -n "${SMOKE_DEBUG:-}" ] && { echo "--- auto.out ---"; cat "$T/auto.out"; echo "--- screen ---"; bash "$O/screen.sh" "$S1" --lines 12 | cut -c1-160; echo "--- last-call ---"; cat "$T/last-call" 2>/dev/null | head -5; }
check "codex resume with worktree uuid and prompt" "grep -q '^cli=codex' '$T/last-call' && grep -q '^arg=resume' '$T/last-call' && grep -q \"^arg=$uuid\" '$T/last-call' && grep -q '^arg=\$player tmux:parent' '$T/last-call'"
check "codex harness recorded" "[ \"\$(cat \"\$(git -C '$W1' rev-parse --absolute-git-dir)/player-agent\")\" = codex ]"
rm -f "$T/fake-claude-noconv"

echo "# resume: claude fails for another reason -> no codex fallback"
tm send-keys -t "=$S1:" C-d; sleep 0.8
tm set-option -u -t "=$S1:" @player-agent; rm -f "$(git -C "$W1" rev-parse --absolute-git-dir)/player-agent"
echo 1 > "$T/fake-claude-exit"; rm -f "$T/last-call"
bash "$O/spawn.sh" --repo "$T/repo" --branch feature/x --resume >/dev/null 2>&1
sleep 2
check "claude ran, codex did not" "grep -q '^cli=claude' '$T/last-call' && ! grep -q '^cli=codex' '$T/last-call'"
check "pane left dead for inspection" "[ \"\$(tm display-message -p -t '=$S1:' '#{pane_dead}')\" = 1 ]"
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

echo; echo "passed $pass, failed $fail"; [ $fail = 0 ]
