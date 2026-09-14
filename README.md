# Agent plugins

A small collection of plugins for Claude Code and Codex. Install whichever ones fit your workflow.

## Install

### Claude Code

Add the marketplace once, then choose a plugin:

```text
/plugin marketplace add HermannBjorgvin/agent-plugins
/plugin install orchestra@hermannbjorgvin
/plugin install tv-pauser@hermannbjorgvin
```

### Codex

```bash
codex plugin marketplace add HermannBjorgvin/agent-plugins
codex plugin add orchestra@hermannbjorgvin
```

Start a new Codex session, then invoke `$orchestra:orchestrator` or `$orchestra:player`. Both clients use
the shared `.claude-plugin/marketplace.json` catalog. TV Pauser is Claude Code only.

## Plugins

| Plugin | What it does |
| --- | --- |
| [Orchestra](./orchestra/) | Run coding agents in separate worktrees and tmux sessions, with reports sent back to one orchestrator conversation. Supports Claude Code and Codex. |
| [TV Pauser](./tv-pauser/) | Pause your media player when Claude needs attention and resume playback when work continues. |

Tested on Linux. Support for other operating systems has not been verified; see each plugin's requirements.

## License

MIT
