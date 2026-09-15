"""Isolated integration tests for the orchestrator/player scripts.

Real temporary git repositories; tmux, claude and codex are stateful mocks. The tmux mock
enforces tmux's ~16 KiB command limit, exact `=name`/`=name:` targeting, remain-on-exit
(a pane goes dead when its command exits) and new-session's refusal of a name that is already
in use. It models session user options ("tags": set-option, set-option -u, show-options -qv
and `#{@tag}` expansion in -F formats), session_created/session_path in list-sessions and
list-panes formats, and named paste buffers (load-buffer from stdin, show-buffer,
delete-buffer, paste-buffer -d), which the scripts use instead of files for every piece of
session state. A session's name is a label; its identity is its tags, so several tests plant
foreign sessions that wear the label a player would get.
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
TAGS = ['@orchestra-spawner', '@orchestra-repo', '@orchestra-session-type', '@orchestra-branch', '@orchestra-orchestrator',
        '@orchestra-agent', '@orchestra-launching', '@orchestra-last-report']
# Pinned with Kirby (CLAUDE.md carries the same table): sanitize() and the session labels built
# from it must agree byte for byte in both implementations.
SANITIZE = [('feature/x', 'feature-x'), ('release/v1.0:rc1', 'release-v1-0-rc1'), ('a/b_c-d', 'a-b_c-d'), ('plain', 'plain')]
LABELS = [  # (repo path, session type, branch, label)
    ('/home/u/Kirby', 'worktree', 'feature/x', 'Kirby-feature-x'),
    ('/srv/agent-plugins', 'worktree', 'fix/typo.v1.2:rc', 'agent-plugins-fix-typo-v1-2-rc'),
    ('/x/my.repo', 'worktree', 'main', 'my-repo-main'),
    ('/home/u/Kirby', 'shell', '', 'Kirby-shell'),
    ('/home/u/Kirby', 'agent', '', 'Kirby-agent'),
    # Overflow: 200 characters exactly, 195 of the sanitized label, "-" and the first 4 hex
    # characters of sha256 over the UNSANITIZED "<basename>-<branch>" string.
    ('/x/r', 'worktree', 'a'*250, 'r-' + 'a'*193 + '-0a22'),
    ('/x/agent-plugins', 'worktree', 'a'*250, 'agent-plugins-' + 'a'*181 + '-1fad'),
    # Same sanitized head, different unsanitized input: the tails differ only if the hash is over
    # the unsanitized string (hashing the sanitized one gives ec93 for both).
    ('/x/r', 'worktree', 'a/'*125, 'r-' + 'a-'*96 + 'a-6e0f'),
    ('/x/r', 'worktree', 'a.'*125, 'r-' + 'a-'*96 + 'a-b373'),
    # Terminal tabs hash "<basename>-shell" / "<basename>-agent" (the bare basename would give ae7b for both).
    ('/x/' + 'b'*220, 'shell', '', 'b'*195 + '-930d'),
    ('/x/' + 'b'*220, 'agent', '', 'b'*195 + '-9fb6'),
]
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
def create(n, path):
    state[n] = {'dead': 0, 'options': {}, 'path': path, 'created': 1 + max([s.get('created', 0) for s in state.values()] + [0])}
def expand(fmt, n, s):
    vals = {'session_name': n, 'session_created': str(s.get('created', 0)), 'session_path': s.get('path', ''),
            'pane_dead': str(s.get('dead', 1)), 'pane_current_command': os.environ.get('TEST_PANE_COMMAND', 'bash'), 'window_activity': '0',
            'pane_current_path': s.get('path', ''), 'pane_title': os.environ.get('TEST_PANE_TITLE', '')}
    return re.sub(r'#\{([^}]+)\}', lambda m: s['options'].get(m.group(1), '') if m.group(1).startswith('@') else vals.get(m.group(1), ''), fmt)
if sum(len(x)+1 for x in sys.argv) > 16384: sys.stderr.write('command too long\n'); sys.exit(1)
c = a[0]
if c == 'has-session':
    t = a[a.index('-t')+1]
    sys.exit(0 if t.startswith('=') and t[1:] in state else 1)
if c == 'show-environment': sys.exit(0)
if c == 'new-session':
    n = a[a.index('-s')+1]
    # TEST_NEW_SESSION_RACE=<name>[,<name>…]: another creator takes each such name just before this call lands.
    if n in os.environ.get('TEST_NEW_SESSION_RACE', '').split(',') and n not in state: create(n, '/elsewhere'); save()
    if n in state: sys.stderr.write('duplicate session: %s\n' % n); sys.exit(1)
    if '-d' not in a: sys.stderr.write('open terminal failed: not a terminal\n'); sys.exit(1)
    create(n, a[a.index('-c')+1] if '-c' in a else ''); save(); sys.exit(0)
if c == 'kill-session':
    n = target(a.index('-t')+1)
    if os.environ.get('TEST_KILL_FAIL'): sys.stderr.write('mock tmux: kill-session refused\n'); sys.exit(1)
    del state[n]; save(); sys.exit(0)
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
    if os.environ.get('TEST_LOAD_FAIL'): sys.stderr.write('mock tmux: load refused\n'); sys.exit(1)
    data = sys.stdin.buffer.read().decode(); (b/'buffer').write_text(data)
    if data and '-b' in a: buffers[buffer_name()] = data; save()     # tmux silently drops an empty buffer
    sys.exit(0)
if c == 'show-buffer':
    n = buffer_name()
    if n not in buffers: sys.stderr.write('no buffer %s\n' % n); sys.exit(1)
    sys.stdout.write(buffers[n]); sys.exit(0)
if c == 'delete-buffer':
    n = buffer_name()
    if os.environ.get('TEST_DELETE_FAIL'): sys.stderr.write('mock tmux: server gone\n'); sys.exit(1)
    if n not in buffers: sys.stderr.write('unknown buffer: %s\n' % n); sys.exit(1)
    del buffers[n]; save(); sys.exit(0)
if c == 'paste-buffer':
    target(a.index('-t')+1)
    if os.environ.get('TEST_PASTE_FAIL'): sys.stderr.write('mock tmux: paste refused\n'); sys.exit(1)     # the buffer stays, as in tmux
    if '-d' in a and '-b' in a: buffers.pop(buffer_name(), None); save()
    sys.exit(0)
if c in ('send-keys', 'capture-pane'):
    if c == 'send-keys' and os.environ.get('TEST_SEND_KEYS_FAIL'): sys.stderr.write('mock tmux: submission refused\n'); sys.exit(1)
    if '-t' in a: target(a.index('-t')+1)
    sys.exit(0)
if c in ('list-panes', 'list-sessions', 'ls'):
    if '-f' in a: sys.stderr.write('mock tmux: -f filters need tmux 3.1; match client-side\n'); sys.exit(3)
    fmt = a[a.index('-F')+1] if '-F' in a else '#{session_name}'
    for n, s in state.items(): print(expand(fmt, n, s))
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
        self.git_init(self.repo)
        self.stub('tmux', TMUX_MOCK); self.stub('codex', CLI_MOCK); self.stub('claude', CLI_MOCK)
        self.wt = self.repo/'.claude/worktrees/feature-test'
        self.session = 'repo-feature-test'                     # sanitize(basename(repo)) + "-" + sanitize(branch)
        self.sock = '/tmp/tmux-%d/default' % os.getuid()      # spawn.sh's default server when TMUX is unset
    def tearDown(self): self.tmp.cleanup()
    def git_init(self, path):
        path.mkdir(parents=True, exist_ok=True)
        self.run_cmd(['git', 'init', '-q', str(path)], cwd=self.base)
        self.run_cmd(['git', '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '--allow-empty', '-qm', 'initial'], cwd=path)
    def stub(self, name, text): p = self.bin/name; p.write_text(text); p.chmod(0o755)
    def run_cmd(self, args, cwd=None, ok=True, env=None, stdin=None):
        x = subprocess.run(args, cwd=cwd or self.repo, env=env or self.env, text=True, capture_output=True, input=stdin)
        if ok: self.assertEqual(x.returncode, 0, x.stderr+'\n'+x.stdout)
        return x
    def script(self, name): return str(ROOT/('player/scripts/report.sh' if name == 'report.sh' else 'orchestrator/scripts/'+name))
    def spawn(self, *extra, ok=True, prompt=True, repo=None, branch='feature/test'):
        p = ['--prompt', "Task with $player, 'quotes', `touch BAD`, $(touch BAD), and\na newline END-OF-TASK"] if prompt else []
        return self.run_cmd(['bash', self.script('spawn.sh'), '--repo', str(repo or self.repo), '--branch', branch, '--from', 'HEAD', *p, '--no-node-modules', *extra], ok=ok)
    def orch(self, name, *args, ok=True, cwd=None):
        return self.run_cmd(['bash', self.script(name), *args], ok=ok, cwd=cwd)
    def calls(self):
        f = self.base/'calls'
        return [json.loads(x) for x in f.read_text().splitlines()] if f.exists() else []
    def tmux_log(self): return (self.base/'tmux-log').read_text()
    def tmux_calls(self): return [json.loads(l) for l in self.tmux_log().splitlines()]
    def clear_log(self): (self.base/'tmux-log').unlink()
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
    def rename(self, old, new):
        s = self.state(); s[new] = s.pop(old); self.set_state(s)
    # A session some other program created: no tags unless given (mock tmux, so any name works).
    def foreign(self, name, tags=None):
        self.run_cmd(['tmux', 'new-session', '-d', '-s', name])
        for k, v in (tags or {}).items(): self.run_cmd(['tmux', 'set-option', '-t', '='+name+':', k, v])
    def player_tags(self, repo=None, branch='feature/test', spawner='kirby'):
        return {'@orchestra-spawner': spawner, '@orchestra-repo': str((repo or self.repo).resolve()), '@orchestra-session-type': 'worktree', '@orchestra-branch': branch}
    def sessions(self, *args): return json.loads(self.orch('sessions.sh', '--json', *args).stdout)
    # Environment of a process inside the player's pane: what spawn.sh injects through respawn-pane -e.
    def player_env(self, **extra):
        env = dict(self.env, ORCHESTRA_SESSION=self.session, ORCHESTRA_SOCKET=self.sock); env.update(extra); return env
    def report(self, *args, ok=True, cwd=None, env=None): return self.run_cmd(['bash', self.script('report.sh'), *args], ok=ok, cwd=cwd or self.wt, env=env or self.player_env())
    def gitdir(self): return Path(self.run_cmd(['git', 'rev-parse', '--absolute-git-dir'], cwd=self.wt).stdout.strip())
    def rollout(self, cwd, uuid=UUID, stamp='2026-09-13T10-00-00'):
        d = self.base/'codex-home/sessions/2026/09/13'; d.mkdir(parents=True, exist_ok=True)
        (d/('rollout-%s-%s.jsonl' % (stamp, uuid))).write_text(json.dumps({'type': 'session_meta', 'payload': {'id': uuid, 'cwd': cwd}})+'\n')
    def kill_pane(self, session=None):
        s = self.state(); s[session or self.session]['dead'] = 1; self.set_state(s)
    def assert_no_state_files(self):
        for f in ('player-orchestrator', 'player-prompt', 'player-agent'): self.assertFalse((self.gitdir()/f).exists(), f)
        self.assertFalse((self.base/'mail').exists())
        self.assertEqual([p.name for p in self.gitdir().glob('player-*')], [])
    def lib(self, snippet, *args):      # a snippet run with _lib.sh sourced ($0 must be one of its scripts)
        return self.run_cmd(['bash', '-c', '. "$0"; '+snippet, self.script('_lib.sh'), *args], cwd=self.base).stdout

    # --- fresh launches -------------------------------------------------------------
    def test_codex_spawn_prompt_and_isolation(self):
        self.spawn('--agent', 'codex'); c = self.calls()[-1]
        self.assertEqual(c['args'][:4], ['-m', 'gpt-6-astra', '-c', 'model_reasoning_effort="medium"'])
        self.assertTrue(c['args'][-1].startswith('$player Task with $player,'), c['args'][-1])
        self.assertIn('$(touch BAD)', c['args'][-1]); self.assertTrue(c['args'][-1].endswith('\na newline END-OF-TASK')); self.assertFalse((self.wt/'BAD').exists())
        self.assertNotIn('reporting target', c['args'][-1])
        self.assertIsNone(c['env']['CODEX_THREAD_ID']); self.assertEqual(c['env']['legacy'], [])
        self.assertEqual(c['env']['ORCHESTRA_SESSION'], self.session); self.assertEqual(c['env']['ORCHESTRA_SOCKET'], self.sock)
        self.assertNotIn('ORCHESTRA_PLAYER', c['env']); self.assertEqual(c['env']['ORCHESTRA_MODE'], 'fresh'); self.assertEqual(c['env']['ORCHESTRA_HARNESS'], 'codex')
        self.assertEqual(c['env']['TMUX_TMPDIR'], '/tmp/orchestra-agent-tmux'); self.assertIsNone(c['env']['TMUX'])
        self.assertEqual(self.state()[self.session]['options'], {
            'status': 'off', 'remain-on-exit': 'on', '@orchestra-agent': 'codex', '@orchestra-spawner': 'orchestra', '@orchestra-session-type': 'worktree',
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
        self.orch('adopt.sh', self.session, '--agent', 'claude', '--orchestrator', 'tmux:new-parent')
        self.assertIn('"-l", "/player"]', self.tmux_log())
    def test_claude_default_adopt_from_either_installation(self):
        self.env['TEST_PANE_ALIVE'] = '1'
        self.spawn('--agent', 'claude')
        self.orch('adopt.sh', self.session, '--agent', 'claude', '--orchestrator', 'tmux:new-parent')
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
        self.orch('spawn.sh', '--repo', str(self.repo), '--branch', 'feature/test', '--from', 'HEAD', '--prompt-file', str(pf), '--no-node-modules', '--agent', 'claude')
        self.assertTrue(self.calls()[-1]['args'][-1].endswith(big+'\nEND'))
        self.env['TEST_RESPAWN_FAIL'] = '1'
        x = self.spawn('--prompt', 'p', prompt=False, branch='feature/two', ok=False)
        self.assertNotEqual(x.returncode, 0); self.assertIn('placeholder session removed', x.stderr)
        self.assertNotIn('repo-feature-two', self.state()); self.assertEqual(self.buffers(), {})
        del self.env['TEST_RESPAWN_FAIL']
        self.spawn('--prompt', 'p', prompt=False, branch='feature/two')
        self.assertEqual(self.calls()[-1]['cli'], 'claude'); self.assertEqual(self.calls()[-1]['env']['ORCHESTRA_SESSION'], 'repo-feature-two')
    def test_refuses_running_session(self):
        self.env['TEST_PANE_ALIVE'] = '1'; self.spawn()
        x = self.spawn(ok=False); self.assertIn('running', x.stderr)
        x = self.spawn('--resume', ok=False); self.assertIn('running', x.stderr)
    def test_dry_run_and_empty_json(self):
        x = self.spawn('--agent', 'codex', '--dry-run'); self.assertFalse((self.repo/'.claude').exists()); self.assertFalse((self.base/'tmux-state.json').exists())
        self.assertRegex(x.stdout, r'(?m)^tmux +repo-feature-test ')          # the label it would get
        x = self.orch('sessions.sh', '--all', '--json'); self.assertEqual(json.loads(x.stdout), [])

    # --- names are labels, tags are identity --------------------------------------------
    def test_sanitize_and_label_table_pinned_with_kirby(self):
        for raw, out in SANITIZE: self.assertEqual(self.lib('sanitize "$1"', raw), out, raw)
        for repo, kind, branch, label in LABELS:
            self.assertEqual(self.lib('session_label "$1" "$2" "$3"', repo, kind, branch), label, (repo, kind, branch))
            self.assertLessEqual(len(label), 200)
    def test_collision_suffix_and_foreign_session_untouched(self):
        self.env['TEST_PANE_ALIVE'] = '1'
        self.foreign(self.session)                                       # a stranger already wears the label
        x = self.spawn('--agent', 'codex'); c = self.calls()[-1]
        self.assertEqual(c['env']['ORCHESTRA_SESSION'], self.session+'-2'); self.assertRegex(x.stdout, r'(?m)^started +repo-feature-test-2$')
        self.assertEqual(self.state()[self.session]['options'], {})      # never tagged, never touched
        self.assertEqual(self.tag('@orchestra-branch', self.session+'-2'), 'feature/test')
        self.assertIn('running', self.spawn(ok=False).stderr)            # the player exists: found by tags, not by name
        self.spawn('--prompt', 'p', prompt=False, branch='feature/test-2')   # its preferred label is now taken by our own -2: the suffix goes on the label
        self.assertEqual(sorted(self.state()), [self.session, self.session+'-2', self.session+'-2-2'])
        self.assertEqual(self.tag('@orchestra-branch', self.session+'-2-2'), 'feature/test-2')
        self.clear_log(); self.orch('send.sh', 'feature/test', '--repo', str(self.repo), 'hi')
        self.assertIn('"=%s-2:"' % self.session, self.tmux_log()); self.assertNotIn('"=%s:"' % self.session, self.tmux_log())
        self.clear_log(); self.orch('send.sh', 'feature/test-2', '--repo', str(self.repo), 'hi')
        self.assertIn('"=%s-2-2:"' % self.session, self.tmux_log()); self.assertNotIn('"=%s-2:"' % self.session, self.tmux_log())
        # the stranger's exact name is refused everywhere: it is not one of ours
        for args in (('send.sh', self.session, 'hi'), ('screen.sh', self.session), ('kill.sh', self.session), ('adopt.sh', self.session, '--orchestrator', 'tmux:p')):
            self.clear_log(); x = self.orch(*args, ok=False); self.assertNotEqual(x.returncode, 0, args)
            self.assertNotIn('"=%s:"' % self.session, self.tmux_log(), args); self.assertNotIn('kill-session', self.tmux_log(), args)
        self.assertEqual(sorted(self.state()), [self.session, self.session+'-2', self.session+'-2-2'])
        x = self.report('PROGRESS', 'named', env=self.player_env(ORCHESTRA_SESSION=self.session+'-2'))
        self.assertEqual(self.calls()[-1]['args'][-1], '[player %s-2] PROGRESS: named' % self.session)     # the report carries the session name
    def test_duplicate_name_race_takes_next_suffix(self):
        self.env['TEST_NEW_SESSION_RACE'] = self.session
        self.spawn('--agent', 'codex')
        self.assertEqual(self.calls()[-1]['env']['ORCHESTRA_SESSION'], self.session+'-2')
        self.assertEqual(self.state()[self.session]['options'], {})      # the winner of the race is left alone
        self.assertEqual(self.tag('@orchestra-session-type', self.session+'-2'), 'worktree')
        self.assertEqual([c for c in self.tmux_calls() if 'kill-session' in c], [])
    def test_two_lost_races_count_from_the_preferred_label(self):
        self.env['TEST_NEW_SESSION_RACE'] = self.session+','+self.session+'-2'
        self.spawn('--agent', 'codex')
        self.assertEqual(self.calls()[-1]['env']['ORCHESTRA_SESSION'], self.session+'-3')
        self.assertEqual(sorted(self.state()), [self.session, self.session+'-2', self.session+'-3'])
        self.assertEqual(self.state()[self.session+'-2']['options'], {})
    def test_third_collision(self):
        self.foreign(self.session); self.foreign(self.session+'-2')
        self.spawn('--agent', 'codex')
        self.assertEqual(self.calls()[-1]['env']['ORCHESTRA_SESSION'], self.session+'-3')
        self.assertEqual(self.tag('@orchestra-branch', self.session+'-3'), 'feature/test')
        self.assertEqual([n for n in self.state() if self.state()[n]['options']], [self.session+'-3'])
    def test_tags_are_set_before_anything_else_touches_the_session(self):
        self.spawn('--agent', 'codex'); calls = self.tmux_calls()
        i = next(i for i, c in enumerate(calls) if 'new-session' in c and self.session in c)
        self.assertIn('-d', calls[i])
        required = {'@orchestra-spawner', '@orchestra-repo', '@orchestra-session-type', '@orchestra-branch'}; seen = set()
        for c in calls[i+1:]:
            if not any(t in c for t in ('=%s' % self.session, '=%s:' % self.session)): continue
            if 'set-option' in c and c[-2].startswith('@orchestra-'): seen.add(c[-2]); continue
            self.assertTrue(required <= seen, '%s ran before %s were set' % (c, sorted(required - seen))); break
        self.assertTrue(required <= seen, sorted(required - seen))
    def test_resolver_uses_tags_not_names(self):
        self.env['TEST_PANE_ALIVE'] = '1'; self.spawn('--agent', 'codex')
        self.rename(self.session, 'some-label')                          # a label is never parsed
        self.foreign(self.session)                                       # and a stranger now wears the old one
        self.clear_log(); self.orch('send.sh', 'feature/test', '--repo', str(self.repo), 'hello')
        self.assertIn('"=some-label:"', self.tmux_log()); self.assertNotIn('"=%s:"' % self.session, self.tmux_log())
        self.orch('send.sh', 'some-label', 'hello')                      # an exact player name needs no repo
        self.assertIn('running', self.spawn(ok=False).stderr)
        self.kill_pane('some-label'); self.spawn('--resume', '--agent', 'claude', prompt=False)     # --resume resolves (repo, branch) too
        self.assertEqual(self.calls()[-1]['env']['ORCHESTRA_SESSION'], 'some-label'); self.assertEqual(sorted(self.state()), [self.session, 'some-label'])
        rows = self.sessions('--repo', str(self.repo)); self.assertEqual([(r['session'], r['name'], r['branch']) for r in rows], [('some-label', 'some-label', 'feature/test')])
        # two sessions with one identity (should not happen): the oldest wins, the other is reported, nothing is killed
        self.foreign('twin', self.player_tags(spawner='orchestra'))
        x = self.orch('screen.sh', 'feature/test', '--repo', str(self.repo)); self.assertIn('"=some-label:"', self.tmux_log()); self.assertIn('twin', x.stderr)
        s = self.state(); s['twin']['created'] = 0; self.set_state(s); self.clear_log()
        self.orch('screen.sh', 'feature/test', '--repo', str(self.repo)); self.assertIn('"=twin:"', self.tmux_log())
        self.assertEqual(sorted(self.state()), [self.session, 'some-label', 'twin'])
    def test_resolve_by_branch_across_repos(self):
        self.env['TEST_PANE_ALIVE'] = '1'; self.spawn('--agent', 'codex')
        repo2 = self.base/'other/repo'; self.git_init(repo2); self.spawn('--agent', 'codex', repo=repo2)
        self.assertEqual(self.calls()[-1]['env']['ORCHESTRA_SESSION'], self.session+'-2')      # same basename, different repo
        x = self.orch('send.sh', 'feature/test', 'hi', cwd=self.base, ok=False)              # outside any repo: ambiguous
        self.assertNotEqual(x.returncode, 0); self.assertIn(self.session, x.stderr); self.assertIn(self.session+'-2', x.stderr); self.assertNotIn('paste-buffer', self.tmux_log())
        self.clear_log(); self.orch('send.sh', 'feature/test', '--repo', str(repo2), 'hi', cwd=self.base); self.assertIn('"=%s-2:"' % self.session, self.tmux_log())
        self.clear_log(); self.orch('send.sh', 'feature/test', 'hi', cwd=self.wt); self.assertIn('"=%s:"' % self.session, self.tmux_log())   # cwd inside a worktree selects its repo
        self.clear_log(); self.orch('send.sh', self.session+'-2', 'hi', cwd=self.base); self.assertIn('"=%s-2:"' % self.session, self.tmux_log())
        self.orch('kill.sh', 'feature/test', '--repo', str(repo2)); self.assertEqual(sorted(self.state()), [self.session])
        self.clear_log(); self.orch('send.sh', 'feature/test', 'hi', cwd=self.base); self.assertIn('"=%s:"' % self.session, self.tmux_log())   # unique again
        x = self.orch('send.sh', 'feature/test', '--repo', str(repo2), 'hi', ok=False); self.assertNotEqual(x.returncode, 0)          # scoped: not in that repo
    def test_kill_and_adopt_refuse_untagged_sessions(self):
        self.env['TEST_PANE_ALIVE'] = '1'
        self.foreign(self.session)
        half = dict(self.player_tags(spawner='orchestra')); del half['@orchestra-session-type']; self.foreign('half-tagged', half)
        self.foreign('repo-shell', {'@orchestra-spawner': 'kirby', '@orchestra-repo': str(self.repo.resolve()), '@orchestra-session-type': 'shell'})   # fully tagged, not a player
        norepo = self.player_tags(spawner='orchestra'); del norepo['@orchestra-repo']; self.foreign('no-repo-tag', norepo)
        before = self.state()
        for name in (self.session, 'half-tagged', 'repo-shell', 'no-repo-tag'):
            self.assertNotEqual(self.orch('kill.sh', name, ok=False).returncode, 0)
            self.assertNotEqual(self.orch('adopt.sh', name, '--orchestrator', 'tmux:p', ok=False).returncode, 0)
        self.assertNotIn('kill-session', self.tmux_log()); self.assertNotIn('send-keys', self.tmux_log()); self.assertEqual(self.state(), before)
    def test_kill_reports_a_refused_kill(self):
        self.spawn('--agent', 'codex'); self.env['TEST_KILL_FAIL'] = '1'
        x = self.orch('kill.sh', self.session, ok=False); self.assertNotEqual(x.returncode, 0); self.assertIn('could not kill', x.stderr); self.assertNotIn('killed', x.stdout)
        self.assertIn(self.session, self.state())
    def test_sessions_scoped_by_repo_tag(self):
        self.env['TEST_PANE_ALIVE'] = '1'; self.spawn('--agent', 'codex')
        repo2 = self.base/'other/repo'; self.git_init(repo2); self.spawn('--agent', 'codex', repo=repo2)
        self.foreign('stray'); self.foreign('repo-shell', {'@orchestra-spawner': 'kirby', '@orchestra-repo': str(self.repo.resolve()), '@orchestra-session-type': 'shell'})
        self.foreign('tab-made-elsewhere', self.player_tags(branch='feature/other'))
        norepo = self.player_tags(branch='feature/norepo'); del norepo['@orchestra-repo']; self.foreign('no-repo-tag', norepo)   # not ours without a repo tag
        names = lambda rows: sorted(r['session'] for r in rows)
        self.assertEqual(names(self.sessions('--repo', str(self.repo))), sorted([self.session, 'tab-made-elsewhere']))
        self.assertEqual(names(self.sessions()), sorted([self.session, 'tab-made-elsewhere']))                    # cwd's repo
        self.assertEqual(names(self.sessions('--repo', str(repo2))), [self.session+'-2'])
        self.assertEqual(names(self.sessions('--all')), sorted([self.session, self.session+'-2', 'tab-made-elsewhere']))
        self.assertEqual(names(json.loads(self.orch('sessions.sh', '--json', cwd=self.base).stdout)), sorted([self.session, self.session+'-2', 'tab-made-elsewhere']))   # outside a repo: everything
        text = self.orch('sessions.sh', '--all').stdout.splitlines()
        self.assertEqual(text[0].split(), ['STATE', 'QUIET', 'REPO', 'SESSION', 'BRANCH', 'AGENT', 'ORCHESTRATOR', 'LAST-REPORT', 'TITLE'])
        self.assertTrue(any(l.split()[2:5] == [str(repo2.resolve())[:40], self.session+'-2', 'feature/test'] for l in text[1:]), text)   # REPO is the tag value (cut to 40; JSON has it whole)
        self.assertNotIn('stray', '\n'.join(text)); self.assertNotIn('repo-shell', '\n'.join(text)); self.assertNotIn('no-repo-tag', '\n'.join(text))
        self.env['TEST_PANE_COMMAND'] = 'we"ird\\cmd'
        rows = self.sessions('--all'); self.assertEqual(rows[0]['cmd'], 'we"ird\\cmd'); self.assertEqual(rows[0]['state'], 'idle')
        text = self.orch('sessions.sh', '--repo', str(self.repo)).stdout.splitlines()
        self.assertEqual(text[0].split(), ['STATE', 'QUIET', 'SESSION', 'BRANCH', 'AGENT', 'ORCHESTRATOR', 'LAST-REPORT', 'TITLE'])
        self.assertTrue(any(l.split()[2:4] == ['tab-made-elsewhere', 'feature/other'] for l in text[1:]), text)

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
        self.spawn('--agent', 'codex'); self.orch('kill.sh', self.session, '--repo', str(self.repo))
        self.spawn('--resume', '--agent', 'claude', prompt=False); c = self.calls()[-1]
        self.assertEqual(c['cli'], 'claude'); self.assertEqual(c['args'][0], '--continue'); self.assertIn(self.session, self.state())
        self.assertEqual(self.tag('@orchestra-spawner'), 'orchestra'); self.assertEqual(self.tag('@orchestra-branch'), 'feature/test'); self.assertEqual(self.tag('@orchestra-session-type'), 'worktree')
        # gone again, and a stranger has taken the label meanwhile: the recreated session gets the next one
        self.orch('kill.sh', 'feature/test', '--repo', str(self.repo)); self.foreign(self.session)
        self.spawn('--resume', '--agent', 'claude', prompt=False)
        self.assertEqual(self.calls()[-1]['env']['ORCHESTRA_SESSION'], self.session+'-2'); self.assertEqual(self.tag('@orchestra-branch', self.session+'-2'), 'feature/test')
        self.assertEqual(self.state()[self.session]['options'], {})

    def test_resume_keeps_kirby_identity_tags(self):
        self.spawn('--agent', 'codex'); self.orch('kill.sh', self.session)             # leaves the worktree behind
        kirby = self.player_tags(spawner='kirby'); self.foreign('label-chosen-elsewhere', kirby); self.kill_pane('label-chosen-elsewhere')
        self.spawn('--resume', '--agent', 'claude', prompt=False); c = self.calls()[-1]
        self.assertEqual(c['cli'], 'claude'); self.assertEqual(c['env']['ORCHESTRA_SESSION'], 'label-chosen-elsewhere')
        opts = self.state()['label-chosen-elsewhere']['options']
        self.assertEqual({k: opts.get(k) for k in kirby}, kirby)                          # creator-only tags untouched
        self.assertEqual(opts['@orchestra-agent'], 'claude'); self.assertEqual(opts['@orchestra-orchestrator'], 'codex:'+ID)
        self.assertEqual(sorted(self.state()), ['label-chosen-elsewhere'])
    def assert_reads_pass_utf8(self):
        reads = [c for c in self.tmux_calls() if any(k in c for k in ('display-message', 'show-options', 'list-sessions', 'list-panes'))]
        self.assertTrue(reads); self.assertEqual([c for c in reads if c[0] != '-u'], [])

    # --- reporting -------------------------------------------------------------------
    def assert_delivery_failed(self, result, destination, reason, kind, text, session=None):
        self.assertEqual(result.returncode, 1)
        self.assertIn('report.sh: delivery failed\nTarget: '+destination+'\nReason: '+reason, result.stderr)
        self.assertTrue(result.stderr.endswith('Report: [player %s] %s: %s\n' % (session or self.session, kind, text)), result.stderr)
        self.assertNotIn('queued for', result.stdout); self.assertNotIn('sent to', result.stdout)
    def test_report_codex_records_success_and_prints_failure(self):
        self.spawn('--agent', 'codex')
        x = self.report('PROGRESS', 'one\ntwo $(touch BAD)')
        self.assertEqual(self.calls()[-1]['args'][:5], ['queue', '--thread', ID, '--message', '[player repo-feature-test] PROGRESS: one\ntwo $(touch BAD)']); self.assertIn('queued for', x.stdout)
        self.assertRegex(self.last_report(), '^PROGRESS '+STAMP+'$')
        before = self.state(); n = len(self.calls())
        self.env['TEST_CLI_EXIT'] = '1'; text = 'two\nlines\twith tab'
        x = self.report('BLOCKED', text, ok=False)
        self.assert_delivery_failed(x, 'codex:'+ID, 'Codex queue refused', 'BLOCKED', text)
        self.assertEqual(self.state(), before)                       # no session writes after failed delivery
        self.assertEqual(len(self.calls()), n+1)                    # one attempt, no retry
        self.assert_no_state_files()
    def test_failed_report_preserves_complete_large_message(self):
        self.spawn('--agent', 'codex'); self.env['TEST_CLI_EXIT'] = '1'
        text = 'Résumé\n'+('h'*20000)+'\t100% $(touch BAD)\nEND\n'
        before = self.state(); x = self.report('DONE', text, ok=False)
        self.assert_delivery_failed(x, 'codex:'+ID, 'Codex queue refused', 'DONE', text)
        self.assertEqual(self.state(), before); self.assertFalse((self.wt/'BAD').exists())
    def test_report_outside_player_pane_prints_failure(self):
        self.spawn('--agent', 'codex'); n = len(self.calls()); before = self.state()
        x = self.report('DONE', 'lost text', env=self.env, ok=False)      # no ORCHESTRA_SESSION / ORCHESTRA_SOCKET
        self.assert_delivery_failed(x, '<unknown>', 'neither ORCHESTRA_SESSION nor TMUX', 'DONE', 'lost text', session=self.wt.name)
        self.assertEqual(len(self.calls()), n); self.assertEqual(self.state(), before)
    def test_invalid_report_target_is_printed_intact(self):
        self.spawn('--agent', 'codex')
        self.run_cmd(['tmux', 'set-option', '-t', '='+self.session+':', '@orchestra-orchestrator', 'codex:not-a-thread'])
        before = self.state(); n = len(self.calls())
        x = self.report('QUESTION', 'where next?', ok=False)
        self.assert_delivery_failed(x, 'codex:not-a-thread', 'invalid orchestrator target', 'QUESTION', 'where next?')
        self.assertEqual(len(self.calls()), n); self.assertEqual(self.state(), before)
    def test_report_with_missing_session_prints_failure(self):
        self.spawn('--agent', 'codex'); self.run_cmd(['tmux', 'kill-session', '-t', '='+self.session])
        x = self.report('DONE', 'session gone', ok=False)
        self.assert_delivery_failed(x, '<unknown>', 'orchestrator target is unset or unreachable', 'DONE', 'session gone')
    def test_tmux_load_and_submit_failures_print_report(self):
        self.env['TEST_PANE_ALIVE'] = '1'
        self.spawn('--agent', 'claude', '--orchestrator', 'tmux:parent'); self.foreign('parent')
        before = self.state()
        for flag, reason in [('TEST_LOAD_FAIL', 'tmux could not load'), ('TEST_SEND_KEYS_FAIL', 'tmux could not submit')]:
            with self.subTest(flag=flag):
                self.clear_log(); self.env[flag] = '1'
                x = self.report('DONE', 'one\ntwo', ok=False)
                self.assert_delivery_failed(x, 'tmux:parent', reason, 'DONE', 'one\ntwo')
                self.assertEqual(self.state(), before); self.assertEqual(self.buffers(), {})
                if flag == 'TEST_SEND_KEYS_FAIL':
                    self.assertIn('the paste succeeded, inspect before retrying', x.stderr)
                    self.assertEqual(sum('paste-buffer' in c for c in self.tmux_calls()), 1)
                    self.assertEqual(sum('send-keys' in c for c in self.tmux_calls()), 1)
                else:
                    self.assertNotIn('paste-buffer', self.tmux_log())
                del self.env[flag]
    def test_report_from_pane_without_orchestra_env_uses_tmux(self):
        self.spawn('--agent', 'codex'); self.rename(self.session, 'label-chosen-elsewhere')     # a pane Kirby started, under whatever label Kirby chose
        inside = dict(self.env, TMUX='/tmp/custom-socket,7,0', TEST_TMUX_SESSION='label-chosen-elsewhere')
        self.assertEqual(self.report('--orchestrator', env=inside).stdout.strip(), 'codex:'+ID)
        self.clear_log(); x = self.report('PROGRESS', 'derived', env=inside); self.assertIn('queued for', x.stdout)
        self.assertEqual(self.calls()[-1]['args'][:5], ['queue', '--thread', ID, '--message', '[player label-chosen-elsewhere] PROGRESS: derived'])
        self.assertRegex(self.tag('@orchestra-last-report', 'label-chosen-elsewhere'), '^PROGRESS '+STAMP+'$'); self.assertIn('"-S", "/tmp/custom-socket", "set-option"', self.tmux_log())
        self.assertIn('["-u", "-S", "/tmp/custom-socket", "display-message"', self.tmux_log())        # the session lookup goes through tmux_on too
        x = self.report('DONE', 'derived fail', env=dict(inside, TEST_CLI_EXIT='1'), ok=False)
        self.assert_delivery_failed(x, 'codex:'+ID, 'Codex queue refused', 'DONE', 'derived fail', session='label-chosen-elsewhere')
    def test_help_text_is_the_whole_header_comment(self):
        # Usage output is exactly the run of "#" lines from line 2 to the first non-comment line: no
        # code line printed, no header line dropped.
        def header(script):
            lines = Path(self.script(script)).read_text().splitlines()[1:]
            out = []
            for l in lines:
                if not l.startswith('#'): break
                out.append(l)
            return '\n'.join(out) + '\n'
        for s, args in (('spawn.sh', ['--help']), ('sessions.sh', ['--help'])):
            x = self.orch(s, *args); self.assertIn('Usage: '+s, x.stdout); self.assertEqual(x.stdout, header(s), s)
        for s in ('report.sh', 'kill.sh', 'adopt.sh', 'send.sh', 'screen.sh'):
            x = self.run_cmd(['bash', self.script(s)], ok=False); self.assertEqual(x.returncode, 2, s); self.assertIn('Usage: '+s, x.stderr)
            self.assertEqual(x.stderr, header(s), s)
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
        self.foreign('parent'); self.clear_log()
        self.report('PROGRESS', 'tmux delivery', env=self.player_env(ORCHESTRA_SOCKET='/tmp/custom-socket')); log = self.tmux_log()
        self.assertIn('"-S", "/tmp/custom-socket", "load-buffer"', log); self.assertIn('paste-buffer', log); self.assertIn('"=parent:"', log)
        self.assertEqual((self.base/'buffer').read_text(), '[player repo-feature-test] PROGRESS: tmux delivery')
        self.assertRegex(self.last_report(), '^PROGRESS '+STAMP+'$')
        self.run_cmd(['tmux', 'kill-session', '-t', '=parent'])
        x = self.report('DONE', 'gone', env=self.player_env(ORCHESTRA_SOCKET='/tmp/custom-socket'), ok=False)
        self.assert_delivery_failed(x, 'tmux:parent', 'orchestrator session parent is gone', 'DONE', 'gone')
    def test_failed_paste_leaves_no_buffer(self):
        self.env['TEST_PANE_ALIVE'] = '1'; self.spawn('--agent', 'claude', '--orchestrator', 'tmux:parent'); self.foreign('parent')
        self.env['TEST_PASTE_FAIL'] = '1'
        x = self.orch('send.sh', self.session, 'hello', ok=False); self.assertNotEqual(x.returncode, 0); self.assertEqual(self.buffers(), {})
        x = self.report('DONE', 'lost', ok=False); self.assertIn('report.sh: delivery failed', x.stderr); self.assertEqual(self.buffers(), {})
        # paste and the cleanup both fail (server gone in between): the full error must still reach the player
        self.env['TEST_DELETE_FAIL'] = '1'
        x = self.report('DONE', 'doubly lost', ok=False); self.assertEqual(x.returncode, 1)
        self.assert_delivery_failed(x, 'tmux:parent', 'tmux could not paste', 'DONE', 'doubly lost')
        x = self.orch('send.sh', self.session, 'hello', ok=False); self.assertNotEqual(x.returncode, 0); self.assertIn('could not paste', x.stderr)
    def test_shell_owned_parent_prints_failure(self):
        self.spawn('--agent', 'claude', '--orchestrator', 'tmux:parent'); self.foreign('parent')
        self.env['TEST_PANE_COMMAND'] = 'bash'; x = self.report('QUESTION', 'decision', ok=False)
        self.assertNotEqual(x.returncode, 0); self.assertNotIn('paste-buffer', self.tmux_log()); self.assertIn('a shell owns', x.stderr)
        self.assert_delivery_failed(x, 'tmux:parent', 'a shell owns', 'QUESTION', 'decision')
    def test_no_parent_never_uses_player_id(self):
        self.spawn('--agent', 'claude'); self.drop_tag('@orchestra-orchestrator'); n = len(self.calls())
        x = self.report('DONE', 'no parent', ok=False); self.assertNotEqual(x.returncode, 0); self.assertEqual(len(self.calls()), n)
        self.assert_delivery_failed(x, '<unknown>', 'orchestrator target is unset or unreachable', 'DONE', 'no parent')

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
        self.orch('adopt.sh', self.session, '--orchestrator', 'tmux:new-parent')
        self.assertIn('"-l", "$player"]', self.tmux_log()); self.assertEqual(self.tag('@orchestra-orchestrator'), 'tmux:new-parent')
        self.assertEqual(self.report('--orchestrator').stdout.strip(), 'tmux:new-parent')
        self.orch('adopt.sh', 'feature/test', '--repo', str(self.repo), '--orchestrator', 'tmux:new-parent', 'Now', 'do', 'this')
        self.assertIn('"-l", "$player Now do this"]', self.tmux_log()); self.assert_no_state_files(); self.assert_reads_pass_utf8()
    def test_adopt_refuses_dead_or_shell_pane(self):
        self.spawn('--agent', 'claude')          # mock CLI exits, so the pane is dead
        x = self.orch('adopt.sh', self.session, '--orchestrator', 'tmux:p', ok=False); self.assertIn('dead', x.stderr)
        self.env['TEST_PANE_ALIVE'] = '1'; self.env['TEST_PANE_COMMAND'] = 'bash'; self.kill_pane(); self.spawn('--resume', prompt=False)
        self.clear_log(); x = self.orch('adopt.sh', self.session, '--orchestrator', 'tmux:p', ok=False)
        self.assertIn('shell owns', x.stderr); self.assertNotIn('send-keys', self.tmux_log()); self.assertEqual(self.tag('@orchestra-orchestrator'), 'codex:'+ID)
    def test_sessions_lists_tags(self):
        self.env['TEST_PANE_ALIVE'] = '1'; self.spawn('--agent', 'codex')
        for extra in ([], ['--all']):
            rows = self.sessions(*extra); self.assertEqual(len(rows), 1); r = rows[0]
            self.assertEqual((r['session'], r['name'], r['agent'], r['orchestrator'], r['last_report'], r['branch'], r['repo']),
                             (self.session, self.session, 'codex', 'codex:'+ID, '', 'feature/test', str(self.repo.resolve())))
        self.report('DONE', 'finished')
        r = self.sessions('--all')[0]; self.assertRegex(r['last_report'], '^DONE '+STAMP+'$')
        self.env['TEST_PANE_TITLE'] = 'left\tright'
        r = self.sessions('--all')[0]; self.assertEqual(r['title'], 'left\tright'); del self.env['TEST_PANE_TITLE']
        text = self.orch('sessions.sh', '--all').stdout.splitlines()
        self.assertIn('AGENT', text[0]); self.assertIn('ORCHESTRATOR', text[0]); self.assertIn('LAST-REPORT', text[0])
        self.assertIn('codex', text[1]); self.assertIn('codex:'+ID, text[1]); self.assertIn('DONE ', text[1])
    def test_exact_session_targeting(self):
        self.env['TEST_PANE_ALIVE'] = '1'; self.spawn('--agent', 'claude')
        self.spawn('--prompt', 'p', prompt=False, branch='feature/test-2')
        self.clear_log(); self.orch('send.sh', 'feature/test', '--repo', str(self.repo), 'hello')
        self.assertIn('"=%s:"' % self.session, self.tmux_log()); self.assertNotIn('feature-test-2', self.tmux_log()); self.assertEqual((self.base/'buffer').read_text(), '[orchestrator] hello')
        for s in ('screen.sh', 'kill.sh'):
            x = self.orch(s, 'feature', '--repo', str(self.repo), ok=False); self.assertNotEqual(x.returncode, 0)
            x = self.orch(s, 'feature-test', '--repo', str(self.repo), ok=False); self.assertNotEqual(x.returncode, 0)     # a sanitized branch is neither a name nor a branch
        self.orch('send.sh', self.session, 'y'*30000)          # over tmux's command limit: goes through load-buffer
        s2 = 'repo-feature-test-2'
        self.run_cmd(['tmux', 'load-buffer', '-b', 'orchestra-prompt-'+s2, '-'], stdin='leftover\n'); self.assertIn('orchestra-prompt-'+s2, self.buffers())
        self.orch('kill.sh', 'feature/test-2', '--repo', str(self.repo))
        self.assertEqual(sorted(self.state()), [self.session]); self.assertEqual(self.buffers(), {})
        self.orch('screen.sh', 'feature/test', '--repo', str(self.repo)); self.assert_reads_pass_utf8()

    # --- the contract itself ------------------------------------------------------------
    def test_scripts_carry_no_legacy_names(self):
        scripts = list(ROOT.glob('*/scripts/*.sh')); self.assertGreaterEqual(len(scripts), 9)
        text = '\n'.join(p.read_text() for p in scripts)
        for old in ('player-orchestrator', 'player-prompt', 'player-agent', 'orchestrator-mail', '@player-', 'ORCHESTRATOR_', 'ORCHESTRA_PLAYER',
                    'PLAYER_RE', 'project_key', 'session_prefix', 'kirby-', 'KIRBY'):
            self.assertNotIn(old, text, old)
        # "kirby" survives only in comments (the spawner value, the sentence that the contract is shared).
        self.assertEqual([l for l in text.splitlines() if 'kirby' in l.split('#', 1)[0].lower()], [])
        # Internal shell variables may keep the PLAYER_ prefix; nothing environment-shaped may.
        self.assertEqual(sorted(set(re.findall(r'\bPLAYER_[A-Z_]+', text))), ['PLAYER_SCRIPTS'])
        for tag in TAGS: self.assertIn(tag, text, tag)
        self.assertEqual(sorted(set(re.findall(r'@orchestra-[a-z-]+', text))), sorted(TAGS))
        self.assertEqual(sorted(set(re.findall(r'\bORCHESTRA_[A-Z_]+', text))),
                         ['ORCHESTRA_CLAUDE_SKILL', 'ORCHESTRA_COMMAND', 'ORCHESTRA_EFFORT', 'ORCHESTRA_HARNESS', 'ORCHESTRA_MODE', 'ORCHESTRA_MODEL',
                          'ORCHESTRA_PERMISSION_MODE', 'ORCHESTRA_SESSION', 'ORCHESTRA_SOCKET'])
        self.assertNotIn('list-sessions -f', text); self.assertNotIn('ls -F', text)

if __name__ == '__main__': unittest.main(verbosity=2)
