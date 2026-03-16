# 🥨 Minga

**Vim motions. Emacs extensibility. Built for the age of AI agents.**

[Getting Started](https://jsmestad.github.io/minga/getting-started.html) | [Documentation](https://jsmestad.github.io/minga/) | [Architecture](https://jsmestad.github.io/minga/architecture.html) | [Roadmap](https://jsmestad.github.io/minga/roadmap.html)

<!-- TODO: add a screenshot or terminal recording here -->

Minga is a modal text editor powered by **Elixir on the BEAM VM**. Every buffer, every agent session, every background task runs in its own isolated process. Nothing shares memory. Nothing blocks your keystrokes. If a component crashes, the rest keep running.

You get the editing model you already know (Vim motions, operators, text objects), the runtime depth you wish you had (redefine any command at runtime, hook into any lifecycle event, extend with real code), and an architecture that was designed from day one for the world where AI agents are editing files alongside you.

Runs natively in the terminal (TUI) and as a macOS desktop app (GUI). Same editor core, same config, same extensions. Pick whichever fits your workflow.

## Why another editor?

AI coding agents need to read files, write files, run commands, and do it all concurrently with your own edits. Every mainstream editor handles this the same way: one event loop, shared state, hope for the best.

The BEAM VM was built 30 years ago to solve exactly this class of problem. Millions of lightweight processes, preemptive scheduling, no shared memory, crash isolation. It powers telecom switches and messaging systems where "one component failing takes down everything" is not acceptable.

Minga points that runtime at a text editor. The editor core runs on the BEAM. Rendering is delegated to native frontends (a terminal UI and a macOS app) that communicate over a clean binary protocol. Two processes, no shared memory, each doing what it's best at.

## What you get

- **Vim-style modal editing**: Normal, Insert, Visual, Operator-Pending, Replace, and Search modes. The motions and operators you think in (`d`, `c`, `y`, `w`, `b`, `e`, `iw`, `i"`, `a{`, and many more).
- **Space-leader commands**: `SPC f f` to find files, `SPC b b` to switch buffers, `SPC s p` to search your project. A Which-Key popup shows what's available as you type.
- **Tree-sitter highlighting**: 24 languages compiled in. Instant on file open.
- **Built-in AI agent**: native LLM integration with streaming, tool use, inline diff review, and conversation management. Supports Anthropic, OpenAI, and Google models.
- **Extensible in Elixir**: define commands, add keybindings, hook into save/open/mode-change events, advise any command with before/after/around wrappers. All from your config file, no restart needed.
- **Process isolation**: every buffer is its own process. Agents, renderers, parsers, file watchers all run independently. Your typing is always responsive.

### Current status

Minga is pre-release. Check the [issue tracker](https://github.com/jsmestad/minga/issues) for planned work. If you want to help shape what a BEAM-powered editor can be, now is a great time.

## Quick start

```bash
git clone https://github.com/jsmestad/minga.git
cd minga
asdf install && mix deps.get && mix compile
bin/minga
```

Press `Space` to see what's possible. Read the [Getting Started guide](https://jsmestad.github.io/minga/getting-started.html) for the full walkthrough.

## Documentation

The [doc site](https://jsmestad.github.io/minga/) is organized by what you're looking for:

| You want to... | Read |
|----------------|------|
| Install and start using Minga | [Getting Started](https://jsmestad.github.io/minga/getting-started.html) |
| Configure themes, keys, options | [Configuration](https://jsmestad.github.io/minga/configuration.html) |
| Understand the architecture | [Architecture](https://jsmestad.github.io/minga/architecture.html) |
| Write extensions | [Extensibility](https://jsmestad.github.io/minga/extensibility.html) |
| Migrate from Neovim | [For Neovim Users](https://jsmestad.github.io/minga/for-neovim-users.html) |
| Migrate from Emacs | [For Emacs Users](https://jsmestad.github.io/minga/for-emacs-users.html) |
| Use AI agents effectively | [For AI-Assisted Developers](https://jsmestad.github.io/minga/for-ai-coders.html) |
| Contribute code | [Contributing](https://jsmestad.github.io/minga/contributing.html) |

## Coming from another editor?

- **[For Neovim users](https://jsmestad.github.io/minga/for-neovim-users.html):** Same modal editing, better runtime.
- **[For Emacs users](https://jsmestad.github.io/minga/for-emacs-users.html):** Same depth of customization, none of the single-threaded pain.
- **[For pi users](https://jsmestad.github.io/minga/for-pi-users.html):** Minga embeds pi as a supervised Port. Everything you like about pi, plus an editor built for it.
- **[For AI-assisted developers](https://jsmestad.github.io/minga/for-ai-coders.html):** Your editor wasn't designed for concurrent autonomous agents. Minga was.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the build-from-source setup, testing, and how to add new commands, motions, and render features.

## License

MIT

## Acknowledgements

A heartfelt thank you to [Henrik Lissner](https://github.com/hlissner) and all contributors to [Doom Emacs](https://github.com/doomemacs/doomemacs). Its keybinding design, leader-key UX, and relentless focus on making a powerful editor feel fast and discoverable were a direct inspiration for Minga's command model.

---

*Created by [Justin Smestad](https://evalcode.com). Built with 🥨 in Colorado.*
