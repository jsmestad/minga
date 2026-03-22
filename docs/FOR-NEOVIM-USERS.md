# Minga for Neovim Users

You already have modal editing, tree-sitter, and LSP. So why would you consider Minga?

True preemptive concurrency instead of a single-threaded event loop, an extension language that's also the implementation language, and components that are structurally isolated from each other.

---

## What you keep

Your muscle memory transfers directly:

| Neovim | Minga | Status |
|--------|-------|--------|
| `h` `j` `k` `l` | Same | ✅ |
| `w` `b` `e` `W` `B` `E` | Same | ✅ |
| `d` `c` `y` + motion | Same | ✅ |
| `dd` `cc` `yy` | Same | ✅ |
| `iw` `aw` `i"` `a{` etc. | Same | ✅ |
| `f`/`F`/`t`/`T` + char | Same | ✅ |
| `gg` `G` `{` `}` `%` | Same | ✅ |
| Normal / Insert / Visual / Operator-Pending | Same | ✅ |
| `:w` `:q` `:wq` `:e` `:%s` | Same | ✅ |
| Registers (`"a`-`"z`, `"+`, `"_`) | Same | ✅ |
| Macros (`q{a-z}`, `@{a-z}`, `@@`) | Same | ✅ |
| Marks (`m{a-z}`, `'{a-z}`, `` `{a-z} ``) | Same | ✅ |
| Dot repeat (`.`) | Same | ✅ |
| Count prefix (`3dd`, `5j`) | Same | ✅ |
| Tree-sitter highlighting | Same engine, 39 grammars | ✅ |

You're not learning a new editor. You're getting a better runtime under the same interface.

---

## What's actually different about Neovim's architecture

You probably already know these pain points, even if you've accepted them.

### "Async" isn't really async

Neovim is single-threaded. When people say it supports "async," they mean it has an event loop with callbacks, like JavaScript. One thing runs at a time. If your LSP server sends a huge response, or tree-sitter is reparsing a large file, or a plugin is doing something expensive, the event loop blocks. Your keystrokes queue up.

Neovim works around this with `:jobstart` and Lua coroutines, but the coordination is manual and error-prone. You've debugged why a plugin "hangs" Neovim. It's almost always a synchronous call hiding in what looks like async code.

**Minga:** The BEAM runs a preemptive scheduler with true parallelism. Every process gets a fair share of CPU time, enforced by the VM. An LSP client parsing a huge JSON response literally cannot block your keystroke handling because they run on different scheduler threads.

### Lua is... fine

Be honest. You don't love Lua. You tolerate it because it's better than Vimscript. Your `init.lua` is 500 lines of boilerplate. Plugin configurations look like this:

```lua
require("telescope").setup({
  defaults = {
    file_ignore_patterns = { "node_modules", ".git" },
    mappings = {
      i = {
        ["<C-j>"] = require("telescope.actions").move_selection_next,
        ["<C-k>"] = require("telescope.actions").move_selection_previous,
      },
    },
  },
})
```

That's a data structure pretending to be configuration. Lua has no pattern matching, no pipe operator, a 1-indexed standard library, and nil-propagation bugs that only surface at runtime.

**Minga:** Config is Elixir, a modern language with pattern matching, pipe operators, excellent error messages, and a type system that catches bugs at compile time:

```elixir
use Minga.Config

set :theme, :doom_one
set :tab_width, 2

bind :normal, "SPC f f", :find_file, "Find file"

on :after_save, fn _buf, path ->
  if String.ends_with?(path, ".ex") do
    System.cmd("mix", ["format", path])
  end
end
```

And because Elixir is the same language the editor is written in, you can read the source to understand what you're configuring. No Lua-to-C boundary to navigate.

### Everything shares one address space

Neovim plugins run in-process. There's no isolation between components. A bug in `telescope.nvim` can corrupt state used by `nvim-cmp`. A C extension with a memory error takes down the entire process.

Your `lazy.nvim` config has 40 plugins. Half of them have breaking changes every few months. If one fails to load, it can cascade into errors in unrelated plugins because they share global state.

**Minga:** Every component is an isolated BEAM process. A buggy plugin can't corrupt your buffer state because it doesn't have access to buffer memory. The VM enforces the isolation. If a plugin fails, its supervisor handles it while everything else keeps running.

### AI agents are fighting your event loop

You're using `copilot.vim` or `codecompanion.nvim`. These plugins make HTTP requests, stream responses, and modify buffers on the same event loop as your typing. Now imagine agentic tools that spawn shell commands, read files, write to multiple buffers, and run for minutes. All on Neovim's single-threaded event loop.

**Minga:** Each AI agent session is its own supervised process tree. The BEAM's preemptive scheduler guarantees your typing always gets CPU time. Agent tools are being [wired to edit buffers in-memory](BUFFER-AWARE-AGENTS.md) instead of going through the filesystem. Multiple agents will get their own buffer forks with three-way merge.

---

## What you gain

### Hot code reloading

Change your config, press `SPC h r`, and the editor reloads without restarting. No `:source %`, no restarting Neovim, no re-opening your files.

### Buffer-local everything

In Neovim, `vim.bo` vs `vim.o` vs `vim.g` is a constant source of confusion. Which options are buffer-local? Which are window-local?

In Minga, each buffer is a BEAM process with its own state. `:set` is always buffer-local. `:setglobal` is always the global default. Process isolation makes this structural, not conventional.

Resolution: buffer-local first, then filetype defaults, then global. No ambiguity.

### Live introspection

Neovim's debugging story is `:messages`, `:checkhealth`, and `print()`.

The BEAM gives you:

```elixir
# Full GUI: every process, memory, CPU, message queues
:observer.start()

# Inspect any process's state live
:sys.get_state(Minga.Editor)

# Trace every message a process receives
:dbg.tracer()
:dbg.p(Process.whereis(Minga.Editor), [:receive])
```

This is a production-grade observability toolkit. When something goes wrong, you inspect the running system instead of adding `print` statements and restarting.

### The extension language is the implementation language

In Neovim, you write config in Lua, but the editor is written in C. When you need to understand what `vim.api.nvim_buf_set_lines()` does, you're reading C source.

In Minga, when you call `Buffer.Server.content(buf)` in your config, you're calling the same Elixir function the editor calls. The source you read to learn the API is the source that runs the editor.

---

## What you'd miss (honestly)

| Neovim has | Minga status |
|-----------|-------------|
| Massive plugin ecosystem | ✅ Extension system ships (Hex, git, local path sources, supervised, with update/rollback). Ecosystem is young. |
| LSP built-in | Planned. Will run as supervised BEAM processes. |
| Splits / tabs | Planned. |
| Visual block mode | Planned. |
| Telescope / fzf-lua | Built-in fuzzy picker with project-scoped search. See [Projects](PROJECTS.md). |
| DAP (debugger) | Not planned yet. |
| Established community | Brand new. |

---

## The bet

Neovim is a great editor today. Minga is a better architecture for tomorrow.

If you're happy with Neovim and AI agents aren't a big part of your workflow, stay with Neovim.

But if you've ever noticed your editor stutter during background operations, wished your background tasks were truly concurrent, wanted an extension language that's also the implementation language, or wondered how AI agents will integrate with a single-threaded event loop as they get more capable, Minga is building the editor you want.

The modal editing you know, on a runtime designed for the problems modern editors actually face.
