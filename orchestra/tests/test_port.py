"""Isolated integration tests for the orchestrator/player scripts.

Real temporary git repositories; tmux, claude and codex are stateful mocks. The tmux mock
enforces tmux's ~16 KiB command limit, exact `=name`/`=name:` targeting and remain-on-exit
(a pane goes dead when its command exits). Run: python3 test_port.py  (SKILLS_ROOT selects
the installation to test; default is this plugin's skills/ directory). The expected Claude
player invocation follows the layout: /<plugin>:player under a plugin manifest, else /player.
"""
import os, json, re, subprocess, tempfile, unittest
from pathlib import Path
ROOT = Path(os.environ.get('SKILLS_ROOT', Path(__file__).resolve().parent.parent/'skills'))
def player_invocation():
    m = ROOT.parent/'.claude-plugin/plugin.json'
    if m.exists():
        found = re.search(r'"name"\s*:\s*"([^"]+)"', m.read_text())
        if found: return '/%s:player' % found.group(1)
    return '/player'
INV = player_invocation()
ID = '11111111-2222-3333-4444-555555555555'
UUID = '0199a000-1111-7000-8000-000000000042'
TMUX_MOCK = r'''#!/usr/bin/env python3
import os, sys, json, subprocess
from pathlib import Path
b = Path(os.environ['ORCH_TEST_TMP']); a = sys.argv[1:]
with (b/'tmux-log').open('a') as f: f.write(json.dumps(a)+'\n')
if a[:1] == ['-S']: a = a[2:]
state_file = b/'tmux-state.json'
state = json.loads(state_file.read_text()) if state_file.exists() else {}
def save(): state_file.write_text(json.dumps(state))
def target(i):
    t = a[i]
    if t.startswith('='):
        name = t[1:].rstrip(':')
        if name in state: return name
        sys.stderr.write("can't find session: %s\n" % t); sys.exit(1)
    sys.stderr.write('mock tmux: non-exact target %s\n' % t); sys.exit(3)   # prefix matching is a bug
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
if c == 'kill-server': state.clear(); save(); sys.exit(0)
if c == 'display-message':
    n = target(a.index('-t')+1) if '-t' in a else None; key = a[-1]; s = state.get(n, {})
    print({'#S': 'parent', '#{pane_dead}': str(s.get('dead', 1)), '#{pane_current_path}': s.get('path', ''),
           '#{socket_path}': '/tmp/test-socket', '#{pane_current_command}': os.environ.get('TEST_PANE_COMMAND', 'claude'),
           '#{pane_pid}': str(os.getpid())}.get(key, '')); sys.exit(0)
if c == 'show-options':
    n = target(a.index('-t')+1); v = state[n]['options'].get(a[-1])
    if v is None: sys.exit(1)
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
    state = json.loads(state_file.read_text()); state[n]['dead'] = 0 if os.environ.get('TEST_PANE_ALIVE') else 1; state[n]['status'] = rc; save()
    sys.exit(0)
if c == 'load-buffer':
    (b/'buffer').write_bytes(sys.stdin.buffer.read()); sys.exit(0)
if c in ('paste-buffer', 'send-keys', 'capture-pane'):
    if '-t' in a: target(a.index('-t')+1)
    sys.exit(0)
if c == 'list-panes':
    for n, s in state.items(): print('|'.join([n, str(s.get('dead', 1)), 'bash', '0', s.get('path', ''), '']))
    sys.exit(0)
sys.exit(0)
'''
CLI_MOCK = r'''#!/usr/bin/env python3
import os, sys, json
from pathlib import Path
b = Path(os.environ['ORCH_TEST_TMP']); me = Path(sys.argv[0]).name
keep = ['CODEX_THREAD_ID', 'ORCHESTRATOR_TARGET', 'CLAUDECODE', 'CLAUDE_CODE_CHILD_SESSION', 'CLAUDE_CONFIG_DIR', 'ANTHROPIC_API_KEY', 'CODEX_HOME', 'TMUX', 'TMUX_TMPDIR', 'PROMPT']
with (b/'calls').open('a') as f:
    f.write(json.dumps({'cli': me, 'args': sys.argv[1:], 'env': {k: os.environ.get(k) for k in keep}, 'cwd': os.getcwd()})+'\n')
if me == 'claude' and os.environ.get('TEST_CLAUDE_NOCONV'): print('No conversation found to continue'); sys.exit(1)
sys.exit(int(os.environ.get('TEST_%s_EXIT' % me.upper(), os.environ.get('TEST_CLI_EXIT', '0'))))
'''

class PortTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='orch-test.')
        self.base = Path(self.tmp.name); self.repo = self.base/'repo'; self.repo.mkdir(); self.bin = self.base/'bin'; self.bin.mkdir()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(('CLAUDE', 'CODEX', 'ORCHESTRATOR', 'TMUX', 'ANTHROPIC', 'PLAYER'))}
        self.env.update(PATH=str(self.bin)+':'+self.env['PATH'], CODEX_THREAD_ID=ID, CODEX_SESSION_ID=ID, ORCH_TEST_TMP=str(self.base),
                        ORCHESTRATOR_MAIL_DIR=str(self.base/'mail'), CODEX_HOME=str(self.base/'codex-home'), CLAUDE_CONFIG_DIR=str(self.base/'claude-config'))
        self.run_cmd(['git', 'init', '-q', str(self.repo)])
        self.run_cmd(['git', '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '--allow-empty', '-qm', 'initial'])
        self.stub('tmux', TMUX_MOCK); self.stub('codex', CLI_MOCK); self.stub('claude', CLI_MOCK)
        self.wt = self.repo/'.claude/worktrees/feature-test'
        self.session = 'kirby-%s-feature-test' % self.project_key()
    def tearDown(self): self.tmp.cleanup()
    def project_key(self):
        import hashlib; return hashlib.sha256(str(self.repo.resolve()).encode()).hexdigest()[:16]
    def stub(self, name, text): p = self.bin/name; p.write_text(text); p.chmod(0o755)
    def run_cmd(self, args, cwd=None, ok=True, env=None):
        x = subprocess.run(args, cwd=cwd or self.repo, env=env or self.env, text=True, capture_output=True)
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
    def report(self, *args, ok=True, cwd=None, env=None): return self.run_cmd(['bash', self.script('report.sh'), *args], ok=ok, cwd=cwd or self.wt, env=env)
    def gitdir(self): return Path(self.run_cmd(['git', 'rev-parse', '--absolute-git-dir'], cwd=self.wt).stdout.strip())
    def rollout(self, cwd, uuid=UUID, stamp='2026-09-13T10-00-00'):
        d = self.base/'codex-home/sessions/2026/09/13'; d.mkdir(parents=True, exist_ok=True)
        (d/('rollout-%s-%s.jsonl' % (stamp, uuid))).write_text(json.dumps({'type': 'session_meta', 'payload': {'id': uuid, 'cwd': cwd}})+'\n')
    def kill_pane(self):
        s = self.state(); s[self.session]['dead'] = 1; (self.base/'tmux-state.json').write_text(json.dumps(s))

    # --- fresh launches -------------------------------------------------------------
    def test_codex_spawn_prompt_and_isolation(self):
        self.spawn('--agent', 'codex'); c = self.calls()[-1]
        self.assertEqual(c['args'][:4], ['-m', 'gpt-6-astra', '-c', 'model_reasoning_effort="medium"'])
        self.assertTrue(c['args'][-1].startswith('$player codex:'+ID+'\n\nYour orchestrator reporting target is: codex:'+ID))
        self.assertIn('$(touch BAD)', c['args'][-1]); self.assertFalse((self.wt/'BAD').exists())
        self.assertIsNone(c['env']['CODEX_THREAD_ID']); self.assertEqual(c['env']['ORCHESTRATOR_TARGET'], 'codex:'+ID)
        self.assertEqual(c['env']['TMUX_TMPDIR'], '/tmp/kirby-agent-tmux'); self.assertIsNone(c['env']['TMUX'])
        self.assertEqual(self.state()[self.session]['options'], {'status': 'off', 'remain-on-exit': 'on', '@player-agent': 'codex'})
    def test_claude_fable_and_explicit_tmux(self):
        self.spawn('--agent', 'claude', '--model', 'fable', '--orchestrator', 'tmux:parent')
        c = self.calls()[-1]; self.assertEqual(c['args'][:4], ['--model', 'fable', '--effort', 'high'])
        self.assertTrue(c['args'][-1].startswith(INV+' tmux:parent'))
    def test_sol_override(self):
        self.spawn('--agent', 'codex', '--model', 'gpt-5.6-sol', '--effort', 'xhigh'); self.assertEqual(self.calls()[-1]['args'][3], 'model_reasoning_effort="xhigh"')
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
        self.assertNotIn('kirby-%s-feature-two' % self.project_key(), self.state())
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
    def test_resume_default_continue_no_replay_no_overrides(self):
        self.spawn('--agent', 'claude', '--model', 'fable'); self.kill_pane()
        self.spawn('--resume', prompt=False); c = self.calls()[-1]
        self.assertEqual(c['cli'], 'claude'); self.assertEqual(c['args'][0], '--continue'); self.assertNotIn('--model', c['args']); self.assertNotIn('--effort', c['args'])
        self.assertTrue(c['args'][-1].endswith('\n\ncontinue')); self.assertNotIn('END-OF-TASK', c['args'][-1])
        self.assertIn('Your orchestrator reporting target is: codex:'+ID, c['args'][-1]); self.assertIn('restarted', c['args'][-1])
    def test_resume_new_assignment_and_explicit_overrides(self):
        self.spawn('--agent', 'claude'); self.kill_pane()
        self.spawn('--resume', '--prompt', 'Next: the follow-up', '--model', 'opus', '--effort', 'max', prompt=False); c = self.calls()[-1]
        self.assertEqual(c['args'][:5], ['--continue', '--model', 'opus', '--effort', 'max']); self.assertTrue(c['args'][-1].endswith('Next: the follow-up')); self.assertNotIn('END-OF-TASK', c['args'][-1])
    def test_resume_codex_by_tag_uses_worktree_conversation(self):
        self.spawn('--agent', 'codex'); self.kill_pane()
        self.rollout('/elsewhere', uuid='0199a000-1111-7000-8000-000000000099', stamp='2026-09-13T12-00-00'); self.rollout(str(self.wt.resolve()))
        self.spawn('--resume', prompt=False); c = self.calls()[-1]
        self.assertEqual(c['cli'], 'codex'); self.assertEqual(c['args'][:2], ['resume', UUID]); self.assertTrue(c['args'][-1].startswith('$player codex:'+ID)); self.assertNotIn('-m', c['args'])
        self.spawn('--resume', '--model', 'gpt-5.6-sol', '--effort', 'high', prompt=False)
        self.assertEqual(self.calls()[-1]['args'][:6], ['resume', '-m', 'gpt-5.6-sol', '-c', 'model_reasoning_effort="high"', UUID])
    def test_resume_codex_without_conversation_refuses(self):
        self.spawn('--agent', 'codex'); self.kill_pane(); n = len(self.calls())
        self.spawn('--resume', prompt=False)
        self.assertEqual(len(self.calls()), n); self.assertEqual(self.state()[self.session]['dead'], 1); self.assertEqual(self.state()[self.session]['status'], 1)
    def test_resume_auto_chain(self):
        self.spawn('--agent', 'claude'); self.kill_pane()
        s = self.state(); s[self.session]['options'].pop('@player-agent'); (self.base/'tmux-state.json').write_text(json.dumps(s)); (self.gitdir()/'player-agent').unlink()
        self.rollout(str(self.wt.resolve()))
        self.env['TEST_CLAUDE_NOCONV'] = '1'; self.spawn('--resume', prompt=False)
        seq = [c['cli'] for c in self.calls()[1:]]; self.assertEqual(seq, ['claude', 'codex'])
        self.assertEqual(self.calls()[-1]['args'][:2], ['resume', UUID]); self.assertEqual((self.gitdir()/'player-agent').read_text().strip(), 'codex')
        del self.env['TEST_CLAUDE_NOCONV']
        for exit_code in ('1', '0'):     # other failures and successes never fall through to Codex
            (self.gitdir()/'player-agent').unlink(missing_ok=True); s = self.state(); s[self.session]['options'].pop('@player-agent', None); s[self.session]['dead'] = 1; (self.base/'tmux-state.json').write_text(json.dumps(s))
            n = len(self.calls()); self.env['TEST_CLAUDE_EXIT'] = exit_code; self.spawn('--resume', prompt=False)
            self.assertEqual([c['cli'] for c in self.calls()[n:]], ['claude'])
    def test_resume_explicit_agent_wins_and_session_gone(self):
        self.spawn('--agent', 'codex'); self.run_cmd(['bash', self.script('kill.sh'), self.session, '--repo', str(self.repo)])
        self.spawn('--resume', '--agent', 'claude', prompt=False); c = self.calls()[-1]
        self.assertEqual(c['cli'], 'claude'); self.assertEqual(c['args'][0], '--continue'); self.assertIn(self.session, self.state())

    # --- reporting -------------------------------------------------------------------
    def test_report_codex_and_failure_mailbox(self):
        self.spawn('--agent', 'codex')
        self.report('--orchestrator', 'codex:'+ID); x = self.report('PROGRESS', 'one\ntwo $(touch BAD)')
        self.assertEqual(self.calls()[-1]['args'][:3], ['queue', '--thread', ID]); self.assertIn('queued for', x.stdout)
        self.env['TEST_CLI_EXIT'] = '1'; x = self.report('DONE', 'saved', ok=False)
        self.assertNotEqual(x.returncode, 0); self.assertIn('NOT DELIVERED', x.stderr); self.assertIn('DONE: saved', next((self.base/'mail').glob('*.log')).read_text())
    def test_mailbox_unwritable_is_surfaced(self):
        self.spawn('--agent', 'codex'); self.env['TEST_CLI_EXIT'] = '1'; self.env['ORCHESTRATOR_MAIL_DIR'] = '/proc/no-such-dir'
        x = self.report('DONE', 'lost text', ok=False); self.assertEqual(x.returncode, 1); self.assertIn('NOT SAVED', x.stderr); self.assertIn('DONE: lost text', x.stderr)
    def test_no_binding_outside_worktree(self):
        outside = self.base/'outside'; outside.mkdir()
        x = self.report('--orchestrator', 'tmux:parent', cwd=outside, ok=False); self.assertEqual(x.returncode, 2)
        self.assertFalse((self.base/'mail/targets').exists()); self.assertFalse((Path.home()/'.claude/orchestrator-mail/targets/player-orchestrator').exists())
        env = dict(self.env, ORCHESTRATOR_TARGET='codex:'+ID); self.report('PROGRESS', 'env only', cwd=outside, env=env)
        self.assertEqual(self.calls()[-1]['args'][:3], ['queue', '--thread', ID])
    def test_legacy_tmux_and_socket_preservation(self):
        self.spawn('--agent', 'claude', '--orchestrator', 'tmux:parent')
        self.report('--orchestrator', 'parent', '--socket', '/tmp/custom-socket'); self.report('--orchestrator', 'tmux:parent')
        self.run_cmd(['tmux', 'new-session', '-d', '-s', 'parent']); (self.base/'tmux-log').unlink()
        self.report('PROGRESS', 'legacy delivery'); log = self.tmux_log()
        self.assertIn('/tmp/custom-socket', log); self.assertIn('load-buffer', log); self.assertIn('paste-buffer', log); self.assertIn('"=parent:"', log)
        self.assertIn('PROGRESS: legacy delivery', (self.base/'buffer').read_text())
    def test_shell_owned_parent_falls_back(self):
        self.spawn('--agent', 'claude', '--orchestrator', 'tmux:parent'); self.run_cmd(['tmux', 'new-session', '-d', '-s', 'parent'])
        self.env['TEST_PANE_COMMAND'] = 'bash'; x = self.report('QUESTION', 'decision', ok=False)
        self.assertNotEqual(x.returncode, 0); self.assertNotIn('paste-buffer', self.tmux_log()); self.assertIn('a shell owns', x.stderr)
    def test_no_parent_never_uses_player_id(self):
        self.spawn('--agent', 'claude'); self.gitdir().joinpath('player-orchestrator').unlink(); n = len(self.calls())
        x = self.report('DONE', 'no parent', ok=False); self.assertNotEqual(x.returncode, 0); self.assertEqual(len(self.calls()), n)

    # --- routing, adoption, exact targeting ------------------------------------------------
    def test_detection(self):
        script = '. "$1"; resolve_orchestrator "${2:-}"'
        def resolve(explicit=''): return self.run_cmd(['bash', '-c', script, 'test', str(ROOT/'player/scripts/_routing.sh'), explicit], ok=False)
        self.env['TMUX'] = '/tmp/custom,1,1'; self.assertEqual(resolve().stdout, 'codex:'+ID)
        self.assertEqual(resolve('parent').stdout, 'tmux:parent')
        self.env['CLAUDECODE'] = '1'; self.assertEqual(resolve().stdout, 'tmux:parent')      # a Claude orchestrator ignores inherited Codex IDs
        del self.env['TMUX']; self.assertNotEqual(resolve().returncode, 0)
        self.assertEqual(resolve('codex:'+ID).stdout, 'codex:'+ID)
        del self.env['CLAUDECODE']; self.env.pop('CODEX_THREAD_ID'); self.env.pop('CODEX_SESSION_ID'); self.assertNotEqual(resolve().returncode, 0)
    def test_adopt_codex_player_with_and_without_text(self):
        self.env['TEST_PANE_ALIVE'] = '1'; self.spawn('--agent', 'codex')
        self.run_cmd(['bash', self.script('adopt.sh'), self.session, '--orchestrator', 'tmux:new-parent'])
        self.assertIn('"$player tmux:new-parent"', self.tmux_log()); self.assertEqual((self.gitdir()/'player-orchestrator').read_text(), 'tmux:new-parent\n/tmp/test-socket\n')
        self.run_cmd(['bash', self.script('adopt.sh'), 'feature-test', '--repo', str(self.repo), '--orchestrator', 'tmux:new-parent', 'Now', 'do', 'this'])
        self.assertIn('"$player tmux:new-parent Now do this"', self.tmux_log())
    def test_adopt_refuses_dead_or_shell_pane(self):
        self.spawn('--agent', 'claude')          # mock CLI exits, so the pane is dead
        x = self.run_cmd(['bash', self.script('adopt.sh'), self.session, '--orchestrator', 'tmux:p'], ok=False); self.assertIn('dead', x.stderr)
        self.env['TEST_PANE_ALIVE'] = '1'; self.env['TEST_PANE_COMMAND'] = 'bash'; self.kill_pane(); self.spawn('--resume', prompt=False)
        (self.base/'tmux-log').unlink(); x = self.run_cmd(['bash', self.script('adopt.sh'), self.session, '--orchestrator', 'tmux:p'], ok=False)
        self.assertIn('shell owns', x.stderr); self.assertNotIn('send-keys', self.tmux_log()); self.assertEqual((self.gitdir()/'player-orchestrator').read_text().splitlines()[0], 'codex:'+ID)
    def test_exact_session_targeting(self):
        self.env['TEST_PANE_ALIVE'] = '1'; self.spawn('--agent', 'claude')
        self.run_cmd(['bash', self.script('spawn.sh'), '--repo', str(self.repo), '--branch', 'feature/test-2', '--from', 'HEAD', '--prompt', 'p', '--no-node-modules'])
        (self.base/'tmux-log').unlink(); self.run_cmd(['bash', self.script('send.sh'), 'feature-test', '--repo', str(self.repo), 'hello'])
        self.assertIn('"=%s:"' % self.session, self.tmux_log()); self.assertNotIn('feature-test-2', self.tmux_log()); self.assertEqual((self.base/'buffer').read_text(), '[orchestrator] hello')
        for s in ('screen.sh', 'kill.sh'):
            x = self.run_cmd(['bash', self.script(s), 'feature', '--repo', str(self.repo)], ok=False); self.assertNotEqual(x.returncode, 0)
        self.run_cmd(['bash', self.script('send.sh'), self.session, 'y'*30000])          # over tmux's command limit: goes through load-buffer
        self.run_cmd(['bash', self.script('kill.sh'), 'feature-test-2', '--repo', str(self.repo)])
        self.assertEqual(sorted(self.state()), [self.session])

if __name__ == '__main__': unittest.main(verbosity=2)
