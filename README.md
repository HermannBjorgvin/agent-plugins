# Agent plugins

A small collection of skills and plugins for coding agents. Install whichever ones fit your workflow.

## Install

### Claude Code

Add the marketplace once, then choose a plugin:

```text
/plugin marketplace add HermannBjorgvin/agent-plugins
/plugin install orchestra@hermannbjorgvin
/plugin install tv-pauser@hermannbjorgvin
```

### Codex and other agents

Install Orchestra's shared skills with [Vercel's skills CLI](https://github.com/vercel-labs/skills):

```bash
npx skills@latest add HermannBjorgvin/agent-plugins --global --skill orchestrator player
```

Choose your agents when prompted. For Codex, we recommend global installation so
players in new worktrees can find both skills. To target Codex directly:

```bash
npx skills@latest add HermannBjorgvin/agent-plugins --global --agent codex --skill orchestrator player
```

Start a new Codex session, then use `$orchestrator`. Install both skills together.
The installer requires Node.js and npm; it installs the same instructions and
scripts used by the Claude plugin. TV Pauser is Claude Code only.

Use one installation method per agent to avoid duplicate skills. For updates and
migration from the manual installer, see [Orchestra's installation guide](./orchestra/#install).

## Plugins

| Plugin | What it does |
| --- | --- |
| [Orchestra](./orchestra/) | Run coding agents in separate worktrees and tmux sessions, with reports sent back to one orchestrator conversation. Supports Claude Code and Codex. |
| [TV Pauser](./tv-pauser/) | Pause your media player when Claude needs attention and resume playback when work continues. |

Tested on Linux. Support for other operating systems has not been verified; see each plugin's requirements.

## License

MIT
