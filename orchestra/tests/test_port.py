"""Isolated integration tests for the orchestrator/player scripts.

Real temporary git repositories; tmux, claude and codex are stateful mocks. The tmux mock
enforces tmux's ~16 KiB command limit, exact `=name`/`=name:` targeting and remain-on-exit
(a pane goes dead when its command exits). It models session user options ("tags":
set-option, set-option -u, show-options -qv and `#{@tag}` expansion in -F formats) and named
paste buffers (load-buffer from stdin, show-buffer, delete-buffer, paste-buffer -d), which the
scripts use instead of files for every piece of session state.
Run: python3 test_port.py  (SKILLS_ROOT selects the installation to test; default is this
plugin's skills/ directory). The expected Claude player invocation defaults to the Claude
plugin in both layouts, with an explicit ORCHESTRA_CLAUDE_SKILL override for standalone
Claude installations.
"""
import os, json, re, subprocess, tempfile, unittest
from pathlib import Path
ROOT = Path(os.environ.get('SKILLS_ROOT', Path(__file__).resolve().parent.parent/'skills'))
def player_invocation():
    m = ROOT.parent/'.claude-plugin/plugin.json'
    if m.exists():
        found = re.search(r'"name"\s*:\s*"([^"]+)"', m.read_text())
        if found: return '/%s:player' % found.group(1)
    return '/orchestra:player'
INV = player_invocation()
ID = '11111111-2222-3333-4444-555555555555'
UUID = '0199a000-1111-7000-8000-000000000042'
RESTART = 'Your session was restarted in this worktree'
STAMP = r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ'
TAGS = ['@orchestra-spawner', '@orchestra-repo', '@orchestra-branch', '@orchestra-orchestrator', '@orchestra-agent',
        '@orchestra-launching', '@orchestra-last-report', '@orchestra-undelivered']
TMUX_MOCK = r'''#!/usr/bin/env python3
import os, sys, json, re, subprocess
from pathlib import Path
b = Path(os.environ['ORCH_TEST_TMP']); a = sys.argv[1:]
with (b/'tmux-log').open('a') as f: f.write(json.dumps(a)+'\n')
while a[:1] in (['-u'], ['-S']): a = a[1:] if a[0] == '-u' else a[2:]     # -u: UTF-8 output; -S: server socket
state_file = b/'tmux-state.json'; buffers_file = b/'tmux-buffers.json'
def load():
    return (json.loads(state_file.read_text()) if state_file.exists() else {},
            json.loads(buffers_file.read_text()) if buffers_file.exists() else {})
state, buffers = load()
def save(): state_file.write_text(json.dumps(state)); buffers_file.write_text(json.dumps(buffers))
def target(i):
    t = a[i]
    if t.startswith('='):
        name = t[1:].rstrip(':')
        if name in state: return name
        sys.stderr.write("can't find session: %s\n" % t); sys.exit(1)
    sys.stderr.write('mock tmux: non-exact target %s\n' % t); sys.exit(3)   # prefix matching is a bug
def buffer_name(): return a[a.index('-b')+1]
if sum(len(x)+1 for x in sys.argv) > 16384: sys.stderr.write('command too long\n'); sys.exit(1)
c = a[0]
if c == 'has-session':
    t = a[a.index('-t')+1]
    sys.exit(0 if t.startswith('=') and t[1:] in state else 1)
if c == 'ls':
    for n in state: print(n)
    sys.exit(0)
if c == 'show-environment': sys.exit(0)
if c == 'new-session':
    n = a[a.index('-s')+1]; state[n] = {'dead': 0, 'options': {}, 'path': a[a.index('-c')+1] if '-c' in a else ''}; save(); sys.exit(0)
if c == 'kill-session': del state[target(a.index('-t')+1)]; save(); sys.exit(0)
if c == 'kill-server': state.clear(); buffers.clear(); save(); sys.exit(0)
if c == 'display-message':
    n = target(a.index('-t')+1) if '-t' in a else None; key = a[-1]; s = state.get(n, {})
    print({'#S': os.environ.get('TEST_TMUX_SESSION', 'parent'), '#{pane_dead}': str(s.get('dead', 1)), '#{pane_current_path}': s.get('path', ''),
           '#{socket_path}': '/tmp/test-socket', '#{pane_current_command}': os.environ.get('TEST_PANE_COMMAND', 'claude'),
           '#{pane_pid}': str(os.getpid())}.get(key, '')); sys.exit(0)
if c == 'show-options':
    # Session user option: `show-options -qv -t =name: @tag`. Without -q an unset option is an error.
    n = target(a.index('-t')+1); v = state[n]['options'].get(a[-1])
    quiet = any(f.startswith('-') and 'q' in f for f in a[1:-1])
    if v is None: sys.exit(0 if quiet else 1)
    print(v); sys.exit(0)
if c == 'set-option':
    n = target(a.index('-t')+1)
    if '-u' in a: state[n]['options'].pop(a[-1], None)
    else: state[n]['options'][a[-2]] = a[-1]
    save(); sys.exit(0)
if c == 'respawn-pane':
    n = target(a.index('-t')+1)
    if os.environ.get('TEST_RESPAWN_FAIL'): sys.stderr.write('mock respawn failure\n'); sys.exit(1)
    env = os.environ.copy(); cwd = None
    for i, arg in enumerate(a[:a.index('--')]):
        if arg == '-e': k, v = a[i+1].split('=', 1); env[k] = v
        if arg == '-c': cwd = a[i+1]
    rc = subprocess.call(a[a.index('--')+1:], env=env, cwd=cwd)
    state, buffers = load()      # the command may have called this mock itself
    state[n]['dead'] = 0 if os.environ.get('TEST_PANE_ALIVE') else 1; state[n]['status'] = rc; save()
    sys.exit(0)
if c == 'load-buffer':
    data = sys.stdin.buffer.read().decode(); (b/'buffer').write_text(data)
    if data and '-b' in a: buffers[buffer_name()] = data; save()     # tmux silently drops an empty buffer
    sys.exit(0)
if c == 'show-buffer':
    n = buffer_name()
    if n not in buffers: sys.stderr.write('no buffer %s\n' % n); sys.exit(1)
    sys.stdout.write(buffers[n]); sys.exit(0)
if c == 'delete-buffer':
    n = buffer_name()
    if n not in buffers: sys.stderr.write('unknown buffer: %s\n' % n); sys.exit(1)
    del buffers[n]; save(); sys.exit(0)
if c == 'paste-buffer':
    target(a.index('-t')+1)
    if '-d' in a and '-b' in a: buffers.pop(buffer_name(), None); save()
    sys.exit(0)
if c in ('send-keys', 'capture-pane'):
    if '-t' in a: target(a.index('-t')+1)
    sys.exit(0)
if c == 'list-panes':
    fmt = a[a.index('-F')+1] if '-F' in a else '#{session_name}'
    for n, s in state.items():
        vals = {'session_name': n, 'pane_dead': str(s.get('dead', 1)), 'pane_current_command': 'bash', 'window_activity': '0',
                'pane_current_path': s.get('path', ''), 'pane_title': os.environ.get('TEST_PANE_TITLE', '')}
        print(re.sub(r'#\{([^}]+)\}', lambda m: s['options'].get(m.group(1), '') if m.group(1).startswith('@') else vals.get(m.group(1), ''), fmt))
    sys.exit(0)
sys.exit(0)
'''
CLI_MOCK = r'''#!/usr/bin/env python3
import os, sys, json
from pathlib import Path
b = Path(os.environ['ORCH_TEST_TMP']); me = Path(sys.argv[0]).name
keep = ['CODEX_THREAD_ID', 'CLAUDECODE', 'CLAUDE_CODE_CHILD_SESSION', 'CLAUDE_CONFIG_DIR', 'ANTHROPIC_API_KEY', 'CODEX_HOME', 'TMUX', 'TMUX_TMPDIR', 'PROMPT']
env = {k: os.environ.get(k) for k in keep}
env.update({k: v for k, v in os.environ.items() if k.startswith('ORCHESTRA_')})
env['legacy'] = sorted(k for k in os.environ if k.startswith(('PLAYER_', 'ORCHESTRATOR_')))
with (b/'calls').open('a') as f:
    f.write(json.dumps({'cli': me, 'args': sys.argv[1:], 'env': env, 'cwd': os.getcwd()})+'\n')
if me == 'claude' and os.environ.get('TEST_CLAUDE_NOCONV'): print('No conversation found to continue'); sys.exit(1)
sys.exit(int(os.environ.get('TEST_%s_EXIT' % me.upper(), os.environ.get('TEST_CLI_EXIT', '0'))))
'''

class PortTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='orch-test.')
        self.base = Path(self.tmp.name); self.repo = self.base/'repo'; self.repo.mkdir(); self.bin = self.base/'bin'; self.bin.mkdir()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(('CLAUDE', 'CODEX', 'ORCHESTRA', 'TMUX', 'ANTHROPIC', 'PLAYER'))}
        self.env.update(PATH=str(self.bin)+':'+self.env['PATH'], CODEX_THREAD_ID=ID, CODEX_SESSION_ID=ID, ORCH_TEST_TMP=str(self.base),
                        CODEX_HOME=str(self.base/'codex-home'), CLAUDE_CONFIG_DIR=str(self.base/'claude-config'))
        self.run_cmd(['git', 'init', '-q', str(self.repo)])
        self.run_cmd(['git', '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '--allow-empty', '-qm', 'initial'])
        self.stub('tmux', TMUX_MOCK); self.stub('codex', CLI_MOCK); self.stub('claude', CLI_MOCK)
        self.wt = self.repo/'.claude/worktrees/feature-test'
        self.session = 'kirby-%s-feature-test' % self.project_key()
        self.sock = '/tmp/tmux-%d/default' % os.getuid()      # spawn.sh's default server when TMUX is unset
    def tearDown(self): self.tmp.cleanup()
    def project_key(self):
        import hashlib; return hashlib.sha256(str(self.repo.resolve()).encode()).hexdigest()[:16]
    def stub(self, name, text): p = self.bin/name; p.write_text(text); p.chmod(0o755)
    def run_cmd(self, args, cwd=None, ok=True, env=None, stdin=None):
        x = subprocess.run(args, cwd=cwd or self.repo, env=env or self.env, text=True, capture_output=True, input=stdin)
        if ok: self.assertEqual(x.returncode, 0, x.stderr+'\n'+x.stdout)
        return x
    def script(self, name): return str(ROOT/('player/scripts/report.sh' if name == 'report.sh' else 'orchestrator/scripts/'+name))
    def spawn(self, *extra, ok=True, prompt=True):
        p = ['--prompt', "Task with $player, 'quotes', `touch BAD`, $(touch BAD), and\na newline END-OF-TASK"] if prompt else []
        return self.run_cmd(['bash', self.script('spawn.sh'), '--repo', str(self.repo), '--branch', 'feature/test', '--from', 'HEAD', *p, '--no-node-modules', *extra], ok=ok)
    def calls(self):
        f = self.base/'calls'
        return [json.loads(x) for x in f.read_text().splitlines()] if f.exists() else []
    def tmux_log(self): return (self.base/'tmux-log').read_text()
    def state(self): return json.loads((self.base/'tmux-state.json').read_text())
    def buffers(self):
        f = self.base/'tmux-buffers.json'
        return json.loads(f.read_text()) if f.exists() else {}
    def tag(self, name, session=None): return self.state()[session or self.session]['options'].get(name)
    def last_report(self):
        v = self.tag('@orchestra-last-report'); self.assertIsNotNone(v, '@orchestra-last-report is unset'); return v
    def set_state(self, s): (self.base/'tmux-state.json').write_text(json.dumps(s))
    def drop_tag(self, name):
        s = self.state(); s[self.session]['options'].pop(name, None); self.set_state(s)
    # Environment of a process inside the player's pane: what spawn.sh injects through respawn-pane -e.
    def player_env(self, **extra):
        env = dict(self.env, ORCHESTRA_SESSION=self.session, ORCHESTRA_SOCKET=self.sock, ORCHESTRA_PLAYER='feature-test'); env.update(extra); return env
    def report(self, *args, ok=True, cwd=None, env=None): return self.run_cmd(['bash', self.script('report.sh'), *args], ok=ok, cwd=cwd or self.wt, env=env or self.player_env())
    def gitdir(self): return Path(self.run_cmd(['git', 'rev-parse', '--absolute-git-dir'], cwd=self.wt).stdout.strip())
    def rollout(self, cwd, uuid=UUID, stamp='2026-09-13T10-00-00'):
        d = self.base/'codex-home/sessions/2026/09/13'; d.mkdir(parents=True, exist_ok=True)
        (d/('rollout-%s-%s.jsonl' % (stamp, uuid))).write_text(json.dumps({'type': 'session_meta', 'payload': {'id': uuid, 'cwd': cwd}})+'\n')
    def kill_pane(self):
        s = self.state(); s[self.session]['dead'] = 1; self.set_state(s)
    def assert_no_state_files(self):
        for f in ('player-orchestrator', 'player-prompt', 'player-agent'): self.assertFalse((self.gitdir()/f).exists(), f)
        self.assertFalse((self.base/'mail').exists())
        self.assertEqual([p.name for p in self.gitdir().glob('player-*')], [])

    # --- fresh launches -------------------------------------------------------------
    def test_codex_spawn_prompt_and_isolation(self):
        self.spawn('--agent', 'codex'); c = self.calls()[-1]
        self.assertEqual(c['args'][:4], ['-m', 'gpt-6-astra', '-c', 'model_reasoning_effort="medium"'])
        self.assertTrue(c['args'][-1].startswith('$player Task with $player,'), c['args'][-1])
        self.assertIn('$(touch BAD)', c['args'][-1]); self.assertTrue(c['args'][-1].endswith('\na newline END-OF-TASK')); self.assertFalse((self.wt/'BAD').exists())
        self.assertNotIn('reporting target', c['args'][-1])
        self.assertIsNone(c['env']['CODEX_THREAD_ID']); self.assertEqual(c['env']['legacy'], [])
        self.assertEqual(c['env']['ORCHESTRA_SESSION'], self.session); self.assertEqual(c['env']['ORCHESTRA_SOCKET'], self.sock)
        self.assertEqual(c['env']['ORCHESTRA_PLAYER'], 'feature-test'); self.assertEqual(c['env']['ORCHESTRA_MODE'], 'fresh'); self.assertEqual(c['env']['ORCHESTRA_HARNESS'], 'codex')
        self.assertEqual(c['env']['TMUX_TMPDIR'], '/tmp/kirby-agent-tmux'); self.assertIsNone(c['env']['TMUX'])
        self.assertEqual(self.state()[self.session]['options'], {
            'status': 'off', 'remain-on-exit': 'on', '@orchestra-agent': 'codex', '@orchestra-spawner': 'orchestra',
            '@orchestra-repo': str(self.repo.resolve()), '@orchestra-branch': 'feature/test', '@orchestra-orchestrator': 'codex:'+ID})
        self.assertEqual(self.buffers(), {})            # the prompt buffer was consumed by the launcher
        self.assertIn('"orchestra-prompt-%s"' % self.session, self.tmux_log())
        self.assert_no_state_files()
    def test_claude_fable_and_explicit_tmux(self):
        self.spawn('--agent', 'claude', '--model', 'fable', '--orchestrator', 'tmux:parent')
        c = self.calls()[-1]; self.assertEqual(c['args'][:4], ['--model', 'fable', '--effort', 'high'])
        self.assertTrue(c['args'][-1].startswith(INV+' Task with')); self.assertEqual(self.tag('@orchestra-orchestrator'), 'tmux:parent')
    def test_standalone_claude_override_spawn_resume_and_adopt(self):
        self.env['ORCHESTRA_CLAUDE_SKILL'] = '/player'
        self.spawn('--agent', 'claude')
        self.assertTrue(self.calls()[-1]['args'][-1].startswith('/player Task with'))
        self.env['TEST_PANE_ALIVE'] = '1'
        self.spawn('--resume', '--agent', 'claude', prompt=False)
        self.assertTrue(self.calls()[-1]['args'][-1].startswith('/player '+RESTART))
        self.run_cmd(['bash', self.script('adopt.sh'), self.session, '--agent', 'claude', '--orchestrator', 'tmux:new-parent'])
        self.assertIn('"-l", "/player"]', self.tmux_log())
    def test_claude_default_adopt_from_either_installation(self):
        self.env['TEST_PANE_ALIVE'] = '1'
        self.spawn('--agent', 'claude')
        self.run_cmd(['bash', self.script('adopt.sh'), self.session, '--agent', 'claude', '--orchestrator', 'tmux:new-parent'])
        self.assertIn('"-l", "'+INV+'"]', self.tmux_log())
    def test_sol_override(self):
        self.spawn('--agent', 'codex', '--model', 'gpt-5.6-sol', '--effort', 'xhigh'); self.assertEqual(self.calls()[-1]['args'][3], 'model_reasoning_effort="xhigh"')
    def test_custom_harness_tag(self):
        self.spawn('--cmd', 'claude "$PROMPT"'); c = self.calls()[-1]
        self.assertTrue(c['args'][-1].startswith(INV+' Task with')); self.assertEqual(self.tag('@orchestra-agent'), 'custom')
    def test_env_markers_stripped_config_kept(self):
        self.env.update(CLAUDECODE='1', CLAUDE_CODE_CHILD_SESSION='1', ANTHROPIC_API_KEY='secret', TMUX='')
        self.spawn('--agent', 'claude', '--orchestrator', 'tmux:parent'); e = self.calls()[-1]['env']
        self.assertIsNone(e['CLAUDECODE']); self.assertIsNone(e['CLAUDE_CODE_CHILD_SESSION']); self.assertIsNone(e['CODEX_THREAD_ID'])
        self.assertEqual(e['CLAUDE_CONFIG_DIR'], str(self.base/'claude-config')); self.assertEqual(e['ANTHROPIC_API_KEY'], 'secret'); self.assertEqual(e['CODEX_HOME'], str(self.base/'codex-home'))
    def test_large_prompt_and_failed_launch_retry(self):
        big = 'x'*40000; pf = self.base/'task.txt'; pf.write_text('Task: '+big+'\nEND')
        self.run_cmd(['bash', self.script('spawn.sh'), '--repo', str(self.repo), '--branch', 'feature/test', '--from', 'HEAD', '--prompt-file', str(pf), '--no-node-modules', '--agent', 'claude'])
        self.assertTrue(self.calls()[-1]['args'][-1].endswith(big+'\nEND'))
        self.env['TEST_RESPAWN_FAIL'] = '1'
        x = self.run_cmd(['bash', self.script('spawn.sh'), '--repo', str(self.repo), '--branch', 'feature/two', '--from', 'HEAD', '--prompt', 'p', '--no-node-modules'], ok=False)
        self.assertNotEqual(x.returncode, 0); self.assertIn('placeholder session removed', x.stderr)
        self.assertNotIn('kirby-%s-feature-two' % self.project_key(), self.state()); self.assertEqual(self.buffers(), {})
        del self.env['TEST_RESPAWN_FAIL']
        self.run_cmd(['bash', self.script('spawn.sh'), '--repo', str(self.repo), '--branch', 'feature/two', '--from', 'HEAD', '--prompt', 'p', '--no-node-modules'])
        self.assertEqual(self.calls()[-1]['cli'], 'claude')
    def test_refuses_running_session(self):
        self.env['TEST_PANE_ALIVE'] = '1'; self.spawn()
        x = self.spawn(ok=False); self.assertIn('running', x.stderr)
        x = self.spawn('--resume', ok=False); self.assertIn('running', x.stderr)
    def test_dry_run_and_empty_json(self):
        self.spawn('--agent', 'codex', '--dry-run'); self.assertFalse((self.repo/'.claude').exists()); self.assertFalse((self.base/'tmux-state.json').exists())
        x = self.run_cmd(['bash', self.script('sessions.sh'), '--all', '--json']); self.assertEqual(json.loads(x.stdout), [])

    # --- resume ----------------------------------------------------------------------
    def test_resume_default_restart_note_only_no_replay_no_overrides(self):
        self.spawn('--agent', 'claude', '--model', 'fable'); self.kill_pane()
        self.spawn('--resume', prompt=False); c = self.calls()[-1]
        self.assertEqual(c['cli'], 'claude'); self.assertEqual(c['args'][0], '--continue'); self.assertNotIn('--model', c['args']); self.assertNotIn('--effort', c['args'])
        self.assertTrue(c['args'][-1].startswith(INV+' '+RESTART), c['args'][-1]); self.assertTrue(c['args'][-1].endswith('finished work.'))
        self.assertNotIn('END-OF-TASK', c['args'][-1]); self.assertNotIn('reporting target', c['args'][-1])
        self.assertEqual(c['env']['ORCHESTRA_MODE'], 'resume'); self.assertEqual(self.buffers(), {})
    def test_resume_new_assignment_and_explicit_overrides(self):
        self.spawn('--agent', 'claude'); self.kill_pane()
        self.spawn('--resume', '--prompt', 'Next: the follow-up', '--model', 'opus', '--effort', 'max', prompt=False); c = self.calls()[-1]
        self.assertEqual(c['args'][:5], ['--continue', '--model', 'opus', '--effort', 'max'])
        self.assertTrue(c['args'][-1].startswith(INV+' '+RESTART)); self.assertTrue(c['args'][-1].endswith('\n\nNext: the follow-up')); self.assertNotIn('END-OF-TASK', c['args'][-1])
    def test_resume_codex_by_tag_uses_worktree_conversation(self):
        self.spawn('--agent', 'codex'); self.kill_pane()
        self.rollout('/elsewhere', uuid='0199a000-1111-7000-8000-000000000099', stamp='2026-09-13T12-00-00'); self.rollout(str(self.wt.resolve()))
        self.spawn('--resume', prompt=False); c = self.calls()[-1]
        self.assertEqual(c['cli'], 'codex'); self.assertEqual(c['args'][:2], ['resume', UUID]); self.assertTrue(c['args'][-1].startswith('$player '+RESTART)); self.assertNotIn('-m', c['args'])
        self.spawn('--resume', '--model', 'gpt-5.6-sol', '--effort', 'high', prompt=False)
        self.assertEqual(self.calls()[-1]['args'][:6], ['resume', '-m', 'gpt-5.6-sol', '-c', 'model_reasoning_effort="high"', UUID])
    def test_resume_codex_without_conversation_refuses(self):
        self.spawn('--agent', 'codex'); self.kill_pane(); n = len(self.calls())
        self.spawn('--resume', prompt=False)
        self.assertEqual(len(self.calls()), n); self.assertEqual(self.state()[self.session]['dead'], 1); self.assertEqual(self.state()[self.session]['status'], 1)
    def test_resume_auto_chain(self):
        self.spawn('--agent', 'claude'); self.kill_pane(); self.drop_tag('@orchestra-agent')
        self.rollout(str(self.wt.resolve()))
        self.env['TEST_CLAUDE_NOCONV'] = '1'; self.spawn('--resume', prompt=False)
        seq = [c['cli'] for c in self.calls()[1:]]; self.assertEqual(seq, ['claude', 'codex'])
        self.assertEqual(self.calls()[-1]['args'][:2], ['resume', UUID]); self.assertEqual(self.tag('@orchestra-agent'), 'codex')   # the launcher records what started
        self.assertEqual(self.calls()[-1]['env']['ORCHESTRA_HARNESS'], 'auto')
        del self.env['TEST_CLAUDE_NOCONV']
        for exit_code in ('1', '0'):     # other failures and successes never fall through to Codex
            self.drop_tag('@orchestra-agent'); self.kill_pane()
            n = len(self.calls()); self.env['TEST_CLAUDE_EXIT'] = exit_code; self.spawn('--resume', prompt=False)
            self.assertEqual([c['cli'] for c in self.calls()[n:]], ['claude'])
        self.assertEqual(self.tag('@orchestra-agent'), 'claude')
    def test_resume_explicit_agent_wins_and_session_gone(self):
        self.spawn('--agent', 'codex'); self.run_cmd(['bash', self.script('kill.sh'), self.session, '--repo', str(self.repo)])
        self.spawn('--resume', '--agent', 'claude', prompt=False); c = self.calls()[-1]
        self.assertEqual(c['cli'], 'claude'); self.assertEqual(c['args'][0], '--continue'); self.assertIn(self.session, self.state())
        self.assertEqual(self.tag('@orchestra-spawner'), 'orchestra'); self.assertEqual(self.tag('@orchestra-branch'), 'feature/test')

    # --- reporting -------------------------------------------------------------------
    def test_report_codex_records_last_report_and_undelivered(self):
        self.spawn('--agent', 'codex')
        x = self.report('PROGRESS', 'one\ntwo $(touch BAD)')
        self.assertEqual(self.calls()[-1]['args'][:3], ['queue', '--thread', ID]); self.assertIn('queued for', x.stdout)
        self.assertRegex(self.last_report(), '^PROGRESS '+STAMP+'$'); self.assertIsNone(self.tag('@orchestra-undelivered'))
        self.env['TEST_CLI_EXIT'] = '1'; x = self.report('DONE', 'saved', ok=False)
        self.assertEqual(x.returncode, 1); self.assertIn('NOT DELIVERED', x.stderr); self.assertIn('recorded on session '+self.session, x.stderr)
        self.assertRegex(self.tag('@orchestra-undelivered'), '^'+STAMP+r' \[player feature-test\] DONE: saved$')
        self.assertRegex(self.last_report(), '^PROGRESS ')            # refused reports are not "last accepted"
        self.report('BLOCKED', 'two\nlines\twith tab', ok=False)
        lines = self.tag('@orchestra-undelivered').split('\n'); self.assertEqual(len(lines), 2)
        self.assertRegex(lines[1], '^'+STAMP+r' \[player feature-test\] BLOCKED: two lines with tab$')
        self.assertNotIn('\t', self.tag('@orchestra-undelivered'))
        self.assert_no_state_files()
    def test_undelivered_is_bounded_newest_kept(self):
        self.spawn('--agent', 'codex'); self.env['TEST_CLI_EXIT'] = '1'
        for i in range(4): self.report('PROGRESS', 'msg%d ' % i + 'p'*3000, ok=False)
        v = self.tag('@orchestra-undelivered'); self.assertLess(len(v.encode()), 8192)
        self.assertIn('msg3 ', v); self.assertIn('msg2 ', v); self.assertNotIn('msg0 ', v)
        self.assertTrue(all(re.match(STAMP, line) for line in v.split('\n')))
        self.report('PROGRESS', 'huge ' + 'h'*9000, ok=False)
        v = self.tag('@orchestra-undelivered'); self.assertLess(len(v.encode()), 8192); self.assertIn('huge ', v)
    def test_report_outside_player_pane_is_not_recorded(self):
        self.spawn('--agent', 'codex'); n = len(self.calls())
        x = self.report('DONE', 'lost text', env=self.env, ok=False)      # no ORCHESTRA_SESSION / ORCHESTRA_SOCKET
        self.assertEqual(x.returncode, 1); self.assertIn('NOT DELIVERED', x.stderr); self.assertIn('NOT RECORDED', x.stderr); self.assertIn('DONE: lost text', x.stderr)
        self.assertEqual(len(self.calls()), n); self.assertIsNone(self.tag('@orchestra-undelivered'))
    def test_report_from_pane_without_orchestra_env_uses_tmux(self):
        self.spawn('--agent', 'codex')      # a session with the tags but, for this test, a pane Kirby started
        inside = dict(self.env, TMUX='/tmp/custom-socket,7,0', TEST_TMUX_SESSION=self.session)
        self.assertEqual(self.report('--orchestrator', env=inside).stdout.strip(), 'codex:'+ID)
        (self.base/'tmux-log').unlink(); x = self.report('PROGRESS', 'derived', env=inside); self.assertIn('queued for', x.stdout)
        self.assertEqual(self.calls()[-1]['args'][:5], ['queue', '--thread', ID, '--message', '[player feature-test] PROGRESS: derived'])
        self.assertRegex(self.last_report(), '^PROGRESS '+STAMP+'$'); self.assertIn('"-S", "/tmp/custom-socket", "set-option"', self.tmux_log())
        self.env['TEST_CLI_EXIT'] = '1'; x = self.report('DONE', 'derived fail', env=inside, ok=False)
        self.assertIn('recorded on session '+self.session, x.stderr); self.assertIn('DONE: derived fail', self.tag('@orchestra-undelivered'))
    def test_help_text_is_comment_only(self):
        x = self.run_cmd(['bash', self.script('spawn.sh'), '--help']); self.assertIn('Usage: spawn.sh', x.stdout)
        self.assertFalse([l for l in x.stdout.splitlines() if l.startswith(('.', 'set ', 'AGENT='))], x.stdout[-200:])
        x = self.run_cmd(['bash', self.script('report.sh')], ok=False); self.assertEqual(x.returncode, 2); self.assertIn('Usage: report.sh', x.stderr)
        self.assertFalse([l for l in x.stderr.splitlines() if l.startswith(('set ', '.'))], x.stderr[-200:])
    def test_orchestrator_query_is_read_only(self):
        self.spawn('--agent', 'codex')
        self.assertEqual(self.report('--orchestrator').stdout.strip(), 'codex:'+ID)
        x = self.report('--orchestrator', 'tmux:elsewhere', ok=False); self.assertEqual(x.returncode, 2)
        x = self.report('--orchestrator', 'tmux:elsewhere', '--socket', '/tmp/x', ok=False); self.assertEqual(x.returncode, 2)
        self.assertEqual(self.tag('@orchestra-orchestrator'), 'codex:'+ID)
        x = self.report('--orchestrator', env=self.env, ok=False); self.assertNotEqual(x.returncode, 0)
    def test_tmux_delivery_uses_socket_and_sets_last_report(self):
        self.env['TMUX'] = '/tmp/custom-socket,1,1'
        self.spawn('--agent', 'claude', '--orchestrator', 'tmux:parent')
        self.assertEqual(self.calls()[-1]['env']['ORCHESTRA_SOCKET'], '/tmp/custom-socket')
        self.run_cmd(['tmux', 'new-session', '-d', '-s', 'parent']); (self.base/'tmux-log').unlink()
        self.report('PROGRESS', 'tmux delivery', env=self.player_env(ORCHESTRA_SOCKET='/tmp/custom-socket')); log = self.tmux_log()
        self.assertIn('"-S", "/tmp/custom-socket", "load-buffer"', log); self.assertIn('paste-buffer', log); self.assertIn('"=parent:"', log)
        self.assertIn('PROGRESS: tmux delivery', (self.base/'buffer').read_text())
        self.assertRegex(self.last_report(), '^PROGRESS '+STAMP+'$')
        self.run_cmd(['tmux', 'kill-session', '-t', '=parent'])
        x = self.report('DONE', 'gone', env=self.player_env(ORCHESTRA_SOCKET='/tmp/custom-socket'), ok=False)
        self.assertIn('is gone', x.stderr); self.assertIn('DONE: gone', self.tag('@orchestra-undelivered'))
    def test_shell_owned_parent_falls_back(self):
        self.spawn('--agent', 'claude', '--orchestrator', 'tmux:parent'); self.run_cmd(['tmux', 'new-session', '-d', '-s', 'parent'])
        self.env['TEST_PANE_COMMAND'] = 'bash'; x = self.report('QUESTION', 'decision', ok=False)
        self.assertNotEqual(x.returncode, 0); self.assertNotIn('paste-buffer', self.tmux_log()); self.assertIn('a shell owns', x.stderr)
        self.assertIn('QUESTION: decision', self.tag('@orchestra-undelivered'))
    def test_no_parent_never_uses_player_id(self):
        self.spawn('--agent', 'claude'); self.drop_tag('@orchestra-orchestrator'); n = len(self.calls())
        x = self.report('DONE', 'no parent', ok=False); self.assertNotEqual(x.returncode, 0); self.assertEqual(len(self.calls()), n)
        self.assertIn('not set', x.stderr); self.assertIn('DONE: no parent', self.tag('@orchestra-undelivered'))

    # --- routing, adoption, listing, exact targeting -----------------------------------------
    def test_detection(self):
        script = '. "$1"; resolve_orchestrator "${2:-}"'
        def resolve(explicit=''): return self.run_cmd(['bash', '-c', script, 'test', str(ROOT/'player/scripts/_routing.sh'), explicit], ok=False)
        self.env['TMUX'] = '/tmp/custom,1,1'; self.assertEqual(resolve().stdout, 'codex:'+ID)
        self.assertEqual(resolve('tmux:parent').stdout, 'tmux:parent')
        self.assertNotEqual(resolve('parent').returncode, 0)                                  # bare names are not accepted
        self.env['CLAUDECODE'] = '1'; self.assertEqual(resolve().stdout, 'tmux:parent')      # a Claude orchestrator ignores inherited Codex IDs
        del self.env['TMUX']; self.assertNotEqual(resolve().returncode, 0)
        self.assertEqual(resolve('codex:'+ID).stdout, 'codex:'+ID)
        del self.env['CLAUDECODE']; self.env.pop('CODEX_THREAD_ID'); self.env.pop('CODEX_SESSION_ID'); self.assertNotEqual(resolve().returncode, 0)
    def test_adopt_codex_player_with_and_without_text(self):
        self.env['TEST_PANE_ALIVE'] = '1'; self.spawn('--agent', 'codex')
        self.run_cmd(['bash', self.script('adopt.sh'), self.session, '--orchestrator', 'tmux:new-parent'])
        self.assertIn('"-l", "$player"]', self.tmux_log()); self.assertEqual(self.tag('@orchestra-orchestrator'), 'tmux:new-parent')
        self.assertEqual(self.report('--orchestrator').stdout.strip(), 'tmux:new-parent')
        self.run_cmd(['bash', self.script('adopt.sh'), 'feature-test', '--repo', str(self.repo), '--orchestrator', 'tmux:new-parent', 'Now', 'do', 'this'])
        self.assertIn('"-l", "$player Now do this"]', self.tmux_log()); self.assert_no_state_files()
    def test_adopt_refuses_dead_or_shell_pane(self):
        self.spawn('--agent', 'claude')          # mock CLI exits, so the pane is dead
        x = self.run_cmd(['bash', self.script('adopt.sh'), self.session, '--orchestrator', 'tmux:p'], ok=False); self.assertIn('dead', x.stderr)
        self.env['TEST_PANE_ALIVE'] = '1'; self.env['TEST_PANE_COMMAND'] = 'bash'; self.kill_pane(); self.spawn('--resume', prompt=False)
        (self.base/'tmux-log').unlink(); x = self.run_cmd(['bash', self.script('adopt.sh'), self.session, '--orchestrator', 'tmux:p'], ok=False)
        self.assertIn('shell owns', x.stderr); self.assertNotIn('send-keys', self.tmux_log()); self.assertEqual(self.tag('@orchestra-orchestrator'), 'codex:'+ID)
    def test_sessions_lists_tags(self):
        self.env['TEST_PANE_ALIVE'] = '1'; self.spawn('--agent', 'codex')
        for extra, shown in (([], 'feature-test'), (['--all'], self.session)):       # --all prints full names
            rows = json.loads(self.run_cmd(['bash', self.script('sessions.sh'), '--json', *extra]).stdout); self.assertEqual(len(rows), 1); r = rows[0]
            self.assertEqual((r['session'], r['tmux'], r['agent'], r['orchestrator'], r['last_report'], r['branch'], r['repo']),
                             (shown, self.session, 'codex', 'codex:'+ID, '', 'feature/test', str(self.repo.resolve())))
        self.report('DONE', 'finished')
        r = json.loads(self.run_cmd(['bash', self.script('sessions.sh'), '--all', '--json']).stdout)[0]; self.assertRegex(r['last_report'], '^DONE '+STAMP+'$')
        self.env['TEST_PANE_TITLE'] = 'left\tright'
        r = json.loads(self.run_cmd(['bash', self.script('sessions.sh'), '--all', '--json']).stdout)[0]; self.assertEqual(r['title'], 'left\tright'); del self.env['TEST_PANE_TITLE']
        text = self.run_cmd(['bash', self.script('sessions.sh'), '--all']).stdout.splitlines()
        self.assertIn('AGENT', text[0]); self.assertIn('ORCHESTRATOR', text[0]); self.assertIn('LAST-REPORT', text[0])
        self.assertIn('codex', text[1]); self.assertIn('codex:'+ID, text[1]); self.assertIn('DONE ', text[1])
    def test_exact_session_targeting(self):
        self.env['TEST_PANE_ALIVE'] = '1'; self.spawn('--agent', 'claude')
        self.run_cmd(['bash', self.script('spawn.sh'), '--repo', str(self.repo), '--branch', 'feature/test-2', '--from', 'HEAD', '--prompt', 'p', '--no-node-modules'])
        (self.base/'tmux-log').unlink(); self.run_cmd(['bash', self.script('send.sh'), 'feature-test', '--repo', str(self.repo), 'hello'])
        self.assertIn('"=%s:"' % self.session, self.tmux_log()); self.assertNotIn('feature-test-2', self.tmux_log()); self.assertEqual((self.base/'buffer').read_text(), '[orchestrator] hello')
        for s in ('screen.sh', 'kill.sh'):
            x = self.run_cmd(['bash', self.script(s), 'feature', '--repo', str(self.repo)], ok=False); self.assertNotEqual(x.returncode, 0)
        self.run_cmd(['bash', self.script('send.sh'), self.session, 'y'*30000])          # over tmux's command limit: goes through load-buffer
        s2 = 'kirby-%s-feature-test-2' % self.project_key()
        self.run_cmd(['tmux', 'load-buffer', '-b', 'orchestra-prompt-'+s2, '-'], stdin='leftover\n'); self.assertIn('orchestra-prompt-'+s2, self.buffers())
        self.run_cmd(['bash', self.script('kill.sh'), 'feature-test-2', '--repo', str(self.repo)])
        self.assertEqual(sorted(self.state()), [self.session]); self.assertEqual(self.buffers(), {})

    # --- the contract itself ------------------------------------------------------------
    def test_scripts_carry_no_legacy_names(self):
        scripts = list(ROOT.glob('*/scripts/*.sh')); self.assertGreaterEqual(len(scripts), 9)
        text = '\n'.join(p.read_text() for p in scripts)
        for old in ('player-orchestrator', 'player-prompt', 'player-agent', 'orchestrator-mail', '@player-', 'ORCHESTRATOR_'):
            self.assertNotIn(old, text, old)
        # Internal shell variables may keep the PLAYER_ prefix; nothing environment-shaped may.
        self.assertEqual(sorted(set(re.findall(r'\bPLAYER_[A-Z_]+', text))), ['PLAYER_RE', 'PLAYER_SCRIPTS'])
        for tag in TAGS: self.assertIn(tag, text, tag)
        self.assertEqual(sorted(set(re.findall(r'@orchestra-[a-z-]+', text))), sorted(TAGS))
        self.assertEqual(sorted(set(re.findall(r'\bORCHESTRA_[A-Z_]+', text))),
                         ['ORCHESTRA_CLAUDE_SKILL', 'ORCHESTRA_COMMAND', 'ORCHESTRA_EFFORT', 'ORCHESTRA_HARNESS', 'ORCHESTRA_MODE', 'ORCHESTRA_MODEL',
                          'ORCHESTRA_PERMISSION_MODE', 'ORCHESTRA_PLAYER', 'ORCHESTRA_SESSION', 'ORCHESTRA_SOCKET'])

if __name__ == '__main__': unittest.main(verbosity=2)
