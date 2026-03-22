<p align="center">
  <img src="assets/minga_dark-transparent.svg" alt="Minga logo" width="128">
</p>

# Minga

**Vim motions. Emacs extensibility. Built for the age of AI agents.**

[Getting Started](https://jsmestad.github.io/minga/getting-started.html) | [Documentation](https://jsmestad.github.io/minga/) | [Architecture](https://jsmestad.github.io/minga/architecture.html)

<!-- TODO: add a screenshot or terminal recording here -->

Minga is a modal text editor powered by Elixir on the BEAM VM. It runs natively in the terminal (TUI) and as a macOS desktop app (GUI). Same editor core, same config, same extensions.

You get the editing model you already know (Vim motions, operators, text objects), the runtime depth you wish you had (redefine any command at runtime, hook into any lifecycle event, extend with real code), and an architecture that was designed from day one for a world where AI agents edit files alongside you.

### Current status

Minga is pre-release. If you want to help shape what a BEAM-powered editor can be, now is a great time. Check the [issue tracker](https://github.com/jsmestad/minga/issues) for planned work.

## What it feels like to use

Press `Space` in normal mode. A popup appears showing every command, organized by mnemonic prefix. You don't memorize anything. You read the menu, press the next key, and the popup narrows down. `SPC f f` finds files. `SPC b b` switches buffers. `SPC s p` searches your project.

After a few sessions, these become muscle memory. The popup is always there when you forget.

The AI agent is built in. Toggle the side panel with `SPC a a`, or open a full-screen agent view with `SPC a t`. The agent reads, edits, and creates files in your project. You review every change as an inline diff before it hits disk. Navigate hunks with `]c`/`[c`, accept with `y`, reject with `x`.

Your config is real Elixir, the same language the editor is written in:

```elixir
use Minga.Config

set :theme, :catppuccin_mocha
set :line_numbers, :relative
set :tab_width, 2

# Hooks run in their own processes. This never blocks your typing.
on :after_save, fn _buf, path ->
  if String.ends_with?(path, ".ex") do
    System.cmd("mix", ["format", path])
  end
end
```

That's not a limited DSL. It's the full language. Define commands, add keybindings, hook into save/open/mode-change events, wrap any command with before/after/around advice. No restart needed; press `SPC h r` to hot-reload your config.

## Why the BEAM matters

Every editor you use today was built on the same assumption: one human, typing sequentially, in one buffer at a time. The entire architecture (single event loop, shared memory, global state) follows from that.

Then AI agents showed up. Now you have external processes making API calls, reading your files, writing to your buffers, spawning shell commands, and running for minutes at a time.

You've already seen what happens. An agent streaming a large response causes UI jank because it's competing with your keystrokes for the same thread. You can't tell if the agent is thinking, stuck, or writing to the wrong file. A slow API call hangs the extension, and everything else waits.

Those aren't bugs in the AI tools. They're architectural limits of editors that were designed before AI coding existed.

The BEAM VM was built 30 years ago to solve exactly this class of problem. It powers telecom switches and messaging systems where "one component failing takes down everything" is not acceptable. Minga points that same runtime at a text editor.

**Your typing never freezes.** The BEAM runs a preemptive scheduler that guarantees every process gets fair CPU time. An agent streaming a 2,000-line response? An LSP server parsing a huge codebase? Your keystrokes don't queue up. This isn't async with callbacks. The VM enforces fairness at the scheduler level.

**Components can't corrupt each other.** Every buffer is its own process with its own memory. An agent editing line 200 while you type on line 50 isn't a race condition. Both edits arrive as messages to the buffer's process and are handled sequentially, atomically. No locks, no mutexes.

**Crashes don't take down the editor.** BEAM processes are organized into supervision trees. If a plugin fails, its supervisor restarts it. Your buffers, undo history, and unsaved changes are in completely separate processes. They can't be affected because they don't share memory.

For the full technical story (supervision tree, port protocol, display list IR, rendering pipeline), read the [Architecture doc](https://jsmestad.github.io/minga/architecture.html).

## What ships today

- **Vim-style modal editing.** Normal, Insert, Visual, Operator-Pending, Replace, and Search modes. Motions, operators, text objects (`iw`, `i"`, `a{`), registers, macros, marks, dot repeat.
- **Space-leader commands.** Doom-style `SPC` menus with Which-Key popup. Discoverable from day one.
- **Tree-sitter highlighting.** 39 languages compiled in. Instant on file open.
- **Built-in AI agent.** Native LLM integration with streaming, tool use, inline diff review, and conversation management. Supports Anthropic, OpenAI, and Google models.
- **Extensible in Elixir.** Commands, keybindings, hooks, advice system, extensions, hot reload. The config is the same language as the editor.
- **Native frontends.** Terminal (Zig + libvaxis) and macOS (Swift + Metal). Same core, same config.
- **Project management.** Auto-detected root, file finder, project search, recent files per project.

## Quick start

```bash
git clone https://github.com/jsmestad/minga.git
cd minga
asdf install && mix deps.get && mix compile
bin/minga
```

Press `Space` to see what's possible. Read the [Getting Started guide](https://jsmestad.github.io/minga/getting-started.html) for the full walkthrough.

## Where to go from here

The rest of the docs are organized by what you're trying to do.

**Just want to use Minga?** Start with the [Getting Started guide](https://jsmestad.github.io/minga/getting-started.html). Five minutes from install to editing. Then read [Configuration](https://jsmestad.github.io/minga/configuration.html) for themes, keybindings, formatters, and per-filetype settings.

**Coming from another editor?** Pick your guide:

- **[For Neovim users](https://jsmestad.github.io/minga/for-neovim-users.html):** Same modal editing, better runtime. Your muscle memory transfers directly.
- **[For Emacs users](https://jsmestad.github.io/minga/for-emacs-users.html):** Same depth of customization, none of the single-threaded pain.
- **[For pi users](https://jsmestad.github.io/minga/for-pi-users.html):** Minga embeds pi as a supervised Port. Everything you like about pi, plus an editor built for it.

**Using AI coding tools?** Read [For AI-Assisted Developers](https://jsmestad.github.io/minga/for-ai-coders.html). It covers the architectural limitations of current editors when agents are involved and how the BEAM solves them. An honest technical comparison, not a sales pitch.

**Want to extend the editor?** [Configuration](https://jsmestad.github.io/minga/configuration.html) covers commands, hooks, advice, and extensions. For the deeper "why Elixir is a real extension language" argument, read [Elixir is Minga's Elisp](https://jsmestad.github.io/minga/extensibility.html).

**Want to understand the internals?** [Architecture](https://jsmestad.github.io/minga/architecture.html) covers the two-process design, supervision tree, and rendering pipeline. [Keymap Scopes](https://jsmestad.github.io/minga/keymap-scopes.html) explains how different views get different keybindings.

**Want to contribute?** [Contributing](https://jsmestad.github.io/minga/contributing.html) has the build-from-source setup, testing, and how to add new commands, motions, and render features.

## Contributing

Bug reports, feature ideas, and code are all welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the details.

## License

MIT

## Acknowledgements

A heartfelt thank you to [Henrik Lissner](https://github.com/hlissner) and all contributors to [Doom Emacs](https://github.com/doomemacs/doomemacs). Its keybinding design, leader-key UX, and relentless focus on making a powerful editor feel fast and discoverable were a direct inspiration for Minga's command model.

---

*Created by [Justin Smestad](https://evalcode.com). Built in Colorado.*
