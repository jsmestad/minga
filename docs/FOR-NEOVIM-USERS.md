# Minga for Neovim Users

You already have modal editing, tree-sitter, and LSP. So why would you consider Minga?

**Short answer:** True preemptive concurrency instead of a single-threaded event loop, an extension language that's also the implementation language, and components that are structurally isolated from each other.

---

## What you keep

Let's start with what doesn't change. If you use Neovim, your muscle memory transfers directly:

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
| Registers (`"a`–`"z`, `"+`, `"_`) | Same | ✅ |
| Macros (`q{a-z}`, `@{a-z}`, `@@`) | Same | ✅ |
| Marks (`m{a-z}`, `'{a-z}`, `` `{a-z} ``) | Same | ✅ |
| Dot repeat (`.`) | Same | ✅ |
| Count prefix (`3dd`, `5j`) | Same | ✅ |
| Tree-sitter highlighting | Same engine, 39 grammars | ✅ |

The editing model is Vim. You're not learning a new editor. You're getting a better runtime under the same interface.

---

## What's actually different about Neovim's architecture

You probably already know these pain points, even if you've accepted them:

### 1. "Async" isn't really async

Neovim is single-threaded. When people say it supports "async," they mean it has an event loop with callbacks, like JavaScript. One thing runs at a time. If your LSP server sends a huge response, or tree-sitter is reparsing a large file, or a plugin is doing something expensive in a `vim.schedule` callback, the event loop blocks. Your keystrokes queue up. You feel the lag.

Neovim works around this with `:jobstart` (separate process) and Lua coroutines, but the coordination is manual and error-prone. You've debugged why a plugin "hangs" Neovim. It's almost always a synchronous call hiding in what looks like async code.

**Minga:** The BEAM runs a preemptive scheduler with true parallelism. Every process gets a fair share of CPU time, enforced by the VM. An LSP client parsing a huge JSON response literally cannot block your keystroke handling because they run on different scheduler threads. This isn't async with callbacks. It's real concurrency with fairness guarantees.

### 2. Lua is... fine

Be honest. You don't love Lua. You tolerate it because it's better than Vimscript. Your `init.lua` is 500 lines of boilerplate. Half your config is copy-pasted from GitHub READMEs. Plugin configurations look like this:

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

That's a data structure pretending to be configuration. You can't put real logic in there without it getting ugly fast. Lua has no pattern matching, no pipe operator, a 1-indexed standard library, and nil-propagation bugs that only surface at runtime.

**Minga:** Config is Elixir, a modern language with pattern matching, pipe operators, excellent error messages, and a type system that catches bugs at compile time:

```elixir
use Minga.Config

set :theme, :doom_one
set :tab_size, 2

bind :normal, "SPC f f", :find_file, "Find file"

on :after_save, fn _buf, path ->
  if String.ends_with?(path, ".ex") do
    System.cmd("mix", ["format", path])
  end
end

command :toggle_zen, "Toggle zen mode" do
  state
  |> set_option(:line_numbers, :none)
  |> set_option(:gutter, false)
  |> set_option(:padding, 20)
end
```

And because Elixir is the same language the editor is written in, you can read the source to understand what you're configuring. No Lua↔C boundary to navigate. No `:h api` that describes C functions you call from Lua.

### 3. Everything shares one address space

Neovim plugins run in-process. There's no isolation between components. A bug in `telescope.nvim` can corrupt state used by `nvim-cmp`. A C extension with a memory error takes down the entire process. And every plugin, hook, and autocmd competes for the same event loop.

This also means plugin dependency management is fragile. Your `lazy.nvim` config has 40 plugins. Half of them have breaking changes every few months. If one fails to load, it can cascade into errors in unrelated plugins because they share global state.

**Minga:** Every component is an isolated BEAM process. Buffers, plugins, agents: they each have their own memory and their own state. A buggy plugin can't corrupt your buffer state because it literally doesn't have access to buffer memory. The VM enforces the isolation. If a plugin fails, its supervisor handles it while everything else keeps running. Other plugins don't even know it happened.

### 4. AI agents are fighting your event loop

You're using `copilot.vim` or `codecompanion.nvim` or `avante.nvim`. These plugins make HTTP requests to LLM APIs, stream responses, and modify buffers. They do this on the same event loop as your typing. You've noticed the occasional stutter when a completion comes in.

Now imagine agentic coding tools that don't just suggest, but execute. They spawn shell commands, read files, write to multiple buffers, and run for minutes. All of this on Neovim's single-threaded event loop, contending with your keystrokes.

**Minga:** Each AI agent session is its own supervised process tree. It communicates with buffers via message passing. The BEAM's preemptive scheduler guarantees your typing always gets CPU time, even if an agent is burning cycles on a long operation. You can inspect agent state live with `:sys.get_state(agent_pid)`. You can run multiple agents concurrently without any of them affecting your input responsiveness.

---

## What you gain

Beyond addressing Neovim's architectural limitations:

### Hot code reloading

Change your config, press `SPC h r`, and the editor reloads without restarting. No `:source %`, no restarting Neovim, no re-opening your files. The BEAM hot-loads the new code and your session continues.

### Buffer-local everything

In Neovim, `vim.bo` vs `vim.o` vs `vim.g` is a source of constant confusion. Which options are buffer-local? Which are window-local? The answer is "it depends on the option" and there's a `:h` page you've never fully read.

In Minga, each buffer is a BEAM process with its own state. Editing options (tab_width, wrap, indent_with, line_numbers, autopair, etc.) are inherently buffer-local. The scope is always explicit in the command:

```vim
:set wrap         " buffer-local: only this buffer
:setglobal wrap   " global default: all buffers without a local override
```

Compare to Neovim's three confusing scopes:

| Neovim | Minga | Scope |
|--------|-------|-------|
| `vim.bo[0].tabstop = 4` | `:set tab_width=4` | Current buffer |
| `vim.o.tabstop = 4` | `:setglobal tab_width=4` | Global default |
| `vim.wo[0].wrap = true` | `:set wrap` | Minga uses buffer-local (no window-local yet) |
| `vim.g.some_plugin_var` | `Options.set(:name, val)` | Global |

No `vim.bo` vs `vim.o` vs `vim.wo` to remember. `:set` is always buffer-local. `:setglobal` is always the global default. Process isolation makes this structural, not conventional.

**Resolution chain:** When reading an option, Minga checks buffer-local first, then filetype defaults (like Neovim's `ftplugin`), then the global default. Options are eagerly seeded from filetype/global defaults when a buffer opens, so option reads are fast (no cross-process calls).

```elixir
# In config.exs (equivalent to ftplugin/go.vim):
for_filetype :go do
  set :tab_width, 8
  set :indent_with, :tabs
end

# At runtime, override one buffer:
Buffer.Server.set_option(buf, :tab_width, 4)
```

### Live introspection

Neovim's debugging story is `:messages`, `:checkhealth`, and `print()`.

The BEAM gives you:

```elixir
# See every process in the editor, their memory, message queues
:observer.start()

# Inspect any process's state live
:sys.get_state(Minga.Editor)

# Trace every message a process receives
:dbg.tracer()
:dbg.p(Process.whereis(Minga.Editor), [:receive])
```

This is a production-grade observability toolkit. When something goes wrong, you don't add `print` statements and restart. You inspect the running system. This is how Erlang engineers debug systems that run for years without downtime. The same tools work for understanding what your editor is doing.

### The extension language is the implementation language

In Neovim, you write config in Lua, but the editor is written in C. When you need to understand what `vim.api.nvim_buf_set_lines()` does, you're reading C source. The Lua API is a binding layer, not the real thing.

In Minga, when you call `Buffer.Server.content(buf)` in your config, you're calling the same Elixir function the editor calls. The source you read to learn the API is the source that runs the editor. No translation layer.

---

## What you'd miss (honestly)

| Neovim has | Minga status |
|-----------|-------------|
| Massive plugin ecosystem | Early, core plugins only. The extension system (#14) is being built. |
| LSP built-in | Planned (#22). Will run as supervised BEAM processes. |
| Splits / tabs | Planned. Keybindings exist, implementation pending. |
| Visual block mode | Planned. |
| Telescope / fzf-lua | Built-in fuzzy picker with project-scoped file finding and search. See [Projects](PROJECTS.md) |
| DAP (debugger) | Not planned yet. |
| Established community | Brand new. You'd be early. |

Minga isn't trying to match Neovim feature-for-feature today. It's building on a fundamentally different architecture that solves problems Neovim can't fix without a rewrite.

---

## The bet

Neovim is a great editor today. Minga is a better architecture for tomorrow.

If you're happy with Neovim and you don't mind the occasional UI jank from background operations and you don't use AI coding agents heavily, stay with Neovim. It's a good editor.

But if you've ever:
- Noticed your editor stutter while an LSP server or AI plugin was doing heavy work
- Wished your background tasks were truly concurrent instead of cooperative
- Wanted an extension language that's also the implementation language
- Wanted to inspect the live state of your editor's internals without restarting
- Wondered how AI agents will integrate with a single-threaded event loop as they get more capable

Then Minga is building the editor you want. The modal editing you know, on a runtime that was designed from the ground up for exactly the problems modern editors face.
