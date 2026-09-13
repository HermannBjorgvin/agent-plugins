# My Claude Code Plugins

Plugins I've written for myself to make [Claude Code](https://claude.ai/claude-code) fit my workflow. Feel free to use them if they solve your problems too.

## Installation

```bash
# Add the marketplace (one-time)
/plugin marketplace add HermannBjorgvin/claude-plugins

# Install a plugin
/plugin install tv-pauser@hermannbjorgvin
```

## Plugins

| Plugin | What it does |
|--------|--------------|
| [tv-pauser](./tv-pauser/) | Pauses your TV when Claude needs attention, resumes when you're back to work. No more missing plot points while staring at permission prompts. |
| [orchestra](./orchestra/) | Runs parallel coding agents (Claude Code, Codex, …) in tmux sessions and git worktrees, one branch each, and supervises them from a single orchestrator conversation. |

## License

MIT

---

**Note:** These plugins have been tested on Linux. They might work on macOS and Windows, but no promises.
