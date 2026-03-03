# Minga for Neovim Users

You already have modal editing, tree-sitter, and LSP. So why would you
consider Minga?

**Short answer:** Your plugins can crash without killing your editor, your
background tasks truly run in parallel, and the extension language is better
than Lua.

---

## What you keep

Let's start with what doesn't change. If you use Neovim, your muscle memory
transfers directly:

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
| Tree-sitter highlighting | Same engine, 24 grammars | ✅ |

The editing model is Vim. You're not learning a new editor. You're getting
a better runtime under the same interface.

---

## What's actually wrong with Neovim

You probably already know these pain points, even if you've accepted them:

### 1. A bad plugin crashes your entire editor

You've been there. You install a new plugin, it has a bug in an autocmd,
and Neovim segfaults. Or a Lua plugin throws an error in a hot path and
every keystroke prints a stack trace. Or worse, silent state corruption
that you don't notice until your undo history is gone.

Neovim plugins run in-process. There's no isolation. A bug in
`telescope.nvim` can corrupt state in `nvim-cmp`. A segfault in a C
extension kills everything.

**Minga:** Every component is an isolated BEAM process. A buggy plugin
crashes its own process. The supervisor restarts it. Your buffers, undo
history, cursor positions, all in separate processes, all untouched.
You get an error message, not a core dump.

### 2. "Async" isn't really async

Neovim is single-threaded. When people say it supports "async," they mean
it has an event loop with callbacks, like JavaScript. One thing runs at
a time. If your LSP server sends a huge response, or tree-sitter is
reparsing a large file, or a plugin is doing something expensive in a
`vim.schedule` callback, the event loop blocks. Your keystrokes queue up.
You feel the lag.

Neovim works around this with `:jobstart` (separate process) and Lua
coroutines, but the coordination is manual and error-prone. You've debugged
why a plugin "hangs" Neovim. It's almost always a synchronous call hiding
in what looks like async code.

**Minga:** The BEAM runs a preemptive scheduler with true parallelism.
Every process gets a fair share of CPU time, enforced by the VM. An LSP
client parsing a huge JSON response literally cannot block your keystroke
handling because they run on different scheduler threads. This isn't async with
callbacks. It's real concurrency with fairness guarantees.

### 3. Lua is... fine

Be honest. You don't love Lua. You tolerate it because it's better than
Vimscript. Your `init.lua` is 500 lines of boilerplate. Half your config
is copy-pasted from GitHub READMEs. Plugin configurations look like this:

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

That's a data structure pretending to be configuration. You can't put real
logic in there without it getting ugly fast. Lua has no pattern matching,
no pipe operator, a 1-indexed standard library, and nil-propagation bugs
that only surface at runtime.

**Minga:** Config is Elixir, a modern language with pattern matching,
pipe operators, excellent error messages, and a type system that catches
bugs at compile time:

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

And because Elixir is the same language the editor is written in, you can
read the source to understand what you're configuring. No Lua↔C boundary
to navigate. No `:h api` that describes C functions you call from Lua.

### 4. Plugin dependency hell

Your `lazy.nvim` config has 40 plugins. Half of them have breaking changes
every few months. Some depend on specific Neovim nightly features. You've
spent Saturday mornings debugging why `nvim-treesitter` broke after an
update, or why `mason.nvim` can't find `lua-language-server` anymore.

Plugin updates in Neovim are all-or-nothing. There's no way to roll back
one plugin without reverting your entire lock file. There's no supervision
If a plugin fails to load, you get a wall of Lua errors on startup.

**Minga:** Extensions are BEAM processes. They load independently. If one
fails, the others still work. You get an error message for the broken one,
not a cascade of failures. And because extensions are isolated processes,
they genuinely can't interfere with each other. There's no shared global
state to corrupt.

### 5. AI agents are fighting your event loop

You're using `copilot.vim` or `codecompanion.nvim` or `avante.nvim`. These
plugins make HTTP requests to LLM APIs, stream responses, and modify
buffers. They do this on the same event loop as your typing. You've noticed
the occasional stutter when a completion comes in.

Now imagine agentic coding tools that don't just suggest, but execute.
They spawn shell commands, read files, write to multiple buffers, and run
for minutes. All of this on Neovim's single-threaded event loop, contending
with your keystrokes.

**Minga:** Each AI agent session is its own supervised process tree. It
communicates with buffers via message passing. The BEAM's preemptive
scheduler guarantees your typing always gets CPU time, even if an agent
is burning cycles on a long operation. An agent crash takes down the
agent's process tree. Your editor doesn't blink.

---

## What you gain

Beyond fixing Neovim's problems:

### Hot code reloading

Change your config, press `SPC h r`, and the editor reloads without
restarting. No `:source %`, no restarting Neovim, no re-opening your files.
The BEAM hot-loads the new code and your session continues.

### Buffer-local everything

In Neovim, `vim.bo` vs `vim.o` vs `vim.g` is a source of constant
confusion. Which options are buffer-local? Which are window-local? The
answer is "it depends on the option" and there's a `:h` page you've never
fully read.

In Minga, each buffer is a process with its own state. Every option is
inherently buffer-local. Global defaults exist, but overriding per-buffer
is just updating that process's state. No `vim.bo` vs `vim.o` to remember.

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

This is a production-grade observability toolkit. When something goes wrong,
you don't add `print` statements and restart. You inspect the running
system.

### The extension language is the implementation language

In Neovim, you write config in Lua, but the editor is written in C. When
you need to understand what `vim.api.nvim_buf_set_lines()` does, you're
reading C source. The Lua API is a binding layer, not the real thing.

In Minga, when you call `Buffer.Server.content(buf)` in your config,
you're calling the same Elixir function the editor calls. The source you
read to learn the API is the source that runs the editor. No translation
layer.

---

## What you'd miss (honestly)

| Neovim has | Minga status |
|-----------|-------------|
| Massive plugin ecosystem | Early, core plugins only. The extension system (#14) is being built. |
| LSP built-in | Planned (#22). Will run as supervised BEAM processes. |
| Splits / tabs | Planned. Keybindings exist, implementation pending. |
| Visual block mode | Planned. |
| Telescope / fzf-lua | Built-in fuzzy picker exists. Not as feature-rich yet. |
| DAP (debugger) | Not planned yet. |
| Established community | Brand new. You'd be early. |

Minga isn't trying to match Neovim feature-for-feature today. It's building
on a fundamentally different architecture that solves problems Neovim can't
fix without a rewrite.

---

## The bet

Neovim is a great editor today. Minga is a better architecture for tomorrow.

If you're happy with Neovim and your plugins rarely crash and you don't
use AI coding agents heavily, stay with Neovim. It's a good editor.

But if you've ever:
- Lost work to a plugin crash
- Debugged why your editor "hangs" for 200ms on certain operations
- Wished Lua was a better language
- Worried about how AI agents will integrate with your single-threaded editor
- Wanted to truly understand and modify your editor's internals in one language

Then Minga is building the editor you want. The modal editing you know,
on a runtime that was designed from the ground up for exactly the problems
modern editors face.
