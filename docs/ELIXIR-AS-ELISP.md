# Elixir is Minga's Elisp

A guide for Emacs users who want to know if Minga can be as extensible as
Emacs — and whether Elixir can really replace Elisp.

**Short answer:** Yes. In some ways, it's stronger.

---

## What makes Elisp powerful

Let's be specific about what Emacs users actually mean when they say
"you can modify anything":

1. **Redefine any function at runtime:** `(fset 'function-name ...)` or
   just re-evaluate a `defun`
2. **Advice system:** wrap, replace, or intercept any function without
   modifying the original
3. **Hooks:** attach custom behavior to events (buffer open, save, mode
   change)
4. **Buffer-local variables:** any variable can be overridden for a single
   buffer
5. **Live evaluation:** `M-:`, `eval-buffer`, `eval-region`. run code
   in the running editor
6. **Introspection:** `describe-function`, `describe-variable`,
   `describe-key`. Inspect anything
7. **The config IS the language:** `init.el` is real Elisp, not a YAML
   file or a limited DSL

These are the properties that make Emacs Emacs. Any replacement must match
all seven.

---

## How Elixir on the BEAM matches each one

### 1. Redefine any function at runtime ✅

The BEAM was designed for hot code reloading. Erlang telecom switches
upgrade running code without dropping active phone calls. Elixir inherits
this fully.

**Elisp:**
```elisp
(defun my-custom-word-forward ()
  "Jump to next camelCase boundary."
  (interactive)
  (re-search-forward "[A-Z]" nil t))

(fset 'forward-word #'my-custom-word-forward)
```

**Elixir:**
```elixir
# Define a new module (in your config or at runtime)
defmodule MyMotion do
  def word_forward(buffer, pos) do
    # custom camelCase boundary logic
    find_next_uppercase(buffer, pos)
  end
end

# Replace the motion in the running editor
Minga.Config.override(Minga.Motion.Word, :word_forward, &MyMotion.word_forward/2)
```

Under the hood, the BEAM's code server manages two versions of a module
simultaneously (the "current" and the "old"). When you load new code,
existing function calls finish on the old version while new calls use the
updated one. This is safer than Elisp's immediate replacement, where
redefining a function mid-execution can cause subtle bugs.

**Reloading a module you've edited:**
```elixir
# Recompile and reload (~50ms)
r(MyMotion)

# Or from the editor: SPC h r to reload all user modules
```

### 2. Advice system ✅

Emacs's advice system (`advice-add`, `define-advice`) lets you wrap any
function with `:before`, `:after`, `:around`, or `:override` behavior.

**Elisp:**
```elisp
(define-advice save-buffer (:before (&rest _args))
  "Strip trailing whitespace before every save."
  (delete-trailing-whitespace))
```

**Elixir:**
```elixir
# In your config.exs
advise :before, :save, fn state ->
  strip_trailing_whitespace(state)
end

advise :after, :buffer_open, fn state, _path ->
  log("Opened: #{buffer_name(state)}")
  state
end

advise :around, :format_buffer, fn original_fn, state ->
  if get_option(state, :auto_format) do
    original_fn.(state)
  else
    state
  end
end
```

The implementation is straightforward: the command registry wraps the
original function with the advice chain. Because commands are dispatched
through GenServers, the wrapping is atomic. You can't hit a half-applied
advice state.

**Where Elixir is stronger:** In Emacs, badly written advice can crash the
editor. In Minga, advice runs inside a supervised process. A crash in your
`:before` advice kills that command execution, not the editor. The supervisor
recovers, you see an error message, and you keep editing.

### 3. Hooks ✅

**Elisp:**
```elisp
(add-hook 'after-save-hook #'my-post-save-function)
(add-hook 'find-file-hook #'my-file-open-function)
```

**Elixir:**
```elixir
on :after_save, fn buffer_pid, path ->
  if String.ends_with?(path, ".ex"), do: System.cmd("mix", ["format", path])
end

on :buffer_open, fn buffer_pid, path ->
  if String.ends_with?(path, ".md") do
    Buffer.Server.set_option(buffer_pid, :wrap, true)
    Buffer.Server.set_option(buffer_pid, :spell_check, true)
  end
end

on :mode_change, fn buffer_pid, old_mode, new_mode ->
  if new_mode == :insert, do: set_cursor_shape(:beam)
end
```

**Where Elixir is stronger:** Hooks can run concurrently. An `:after_save`
hook that runs `mix format` doesn't block your typing. It's a separate
process. In Emacs, `after-save-hook` runs synchronously. A slow hook freezes
your editor until it completes.

### 4. Buffer-local variables ✅

This is where the BEAM's process model shines. In Emacs, buffer-local
variables are a layer on top of a global symbol table. The interaction
between `setq`, `setq-local`, `make-local-variable`, `default-value`, and
`buffer-local-value` is notoriously confusing:

```elisp
;; Emacs: is this global or local? Depends on whether
;; make-local-variable was called. Have fun debugging.
(setq tab-width 4)         ; global? maybe?
(setq-local tab-width 2)   ; definitely local
```

In Minga, each buffer is a BEAM process with its own state. "Buffer-local"
isn't a special mode, it's the default:

```elixir
# Set an option for one buffer (just update that process's state)
Buffer.Server.set_option(buffer_pid, :tab_size, 2)

# Set a global default (update the editor process)
Minga.Config.set(:tab_size, 4)

# Resolution: buffer-local wins, falls through to global
# There is no ambiguity. Process boundaries enforce the separation.
```

**Where Elixir is stronger:** There's no `make-local-variable` dance. A
buffer's options are *always* local to that buffer's process. You cannot
accidentally mutate another buffer's state. The VM prevents it. In Emacs,
forgetting `setq-local` vs `setq` has caused countless bugs in packages.

### 5. Live evaluation ✅

**Elisp:**
```elisp
;; M-: evaluate any expression
(+ 1 2)

;; eval-buffer: run the whole file
;; eval-region: run selected code
```

**Elixir:**
```elixir
# From the editor's eval prompt (SPC :e or similar)
Buffer.Server.line_count(current_buffer())
#=> 347

Enum.map(buffers(), &Buffer.Server.file_path/1)
#=> ["/project/lib/app.ex", "/project/README.md"]

# Eval the current selection or buffer
# Uses Code.eval_string/1 under the hood
```

`Code.eval_string/1` evaluates arbitrary Elixir at runtime. It's
interpreted (not compiled), so it's slightly slower than compiled code,
but for interactive evaluation the difference is imperceptible.

**Where Elixir is stronger:** The code you evaluate has access to the full
BEAM runtime. You can inspect any process, send messages to any GenServer,
and observe the editor's behavior live:

```elixir
# Inspect the editor's current state
:sys.get_state(Minga.Editor)

# See all running buffer processes
DynamicSupervisor.which_children(Minga.Buffer.Supervisor)

# Trace every message the editor receives (live!)
:dbg.tracer()
:dbg.p(Process.whereis(Minga.Editor), [:receive])
```

Emacs has nothing comparable to `:observer.start()`, a full GUI dashboard
showing every process, their memory usage, message queues, and CPU time.

### 6. Introspection ✅

**Elisp:**
```elisp
(describe-function 'forward-word)  ; show docstring + source location
(describe-key (kbd "C-f"))         ; what does this key do?
(describe-variable 'tab-width)     ; what's this set to?
```

**Elixir:**
```elixir
# From eval prompt or IEx
h Minga.Motion.Word.word_forward   # docstring
Minga.Keymap.describe("SPC f f")   # what does this binding do?
Minga.Config.get(:tab_size)        # current global value
Buffer.Server.get_option(buf, :tab_size)  # buffer-local value

# Elixir's module introspection
Minga.Motion.Word.__info__(:functions)  # list all functions
Minga.Motion.Word.module_info()         # compiled module metadata
```

Elixir modules carry their `@moduledoc` and `@doc` strings at runtime.
`h/1` in IEx renders them beautifully. Minga's help system (`SPC h f`,
`SPC h k`) will query these directly. Documentation is always in sync
with the running code because it *is* the running code.

### 7. The config IS the language ✅

This is the most important point. In Emacs, `init.el` is Elisp, the same
language the editor is written in. Your config can call any editor function,
inspect any state, define any behavior. You're not writing YAML or TOML or
a limited DSL. You're programming the editor.

Minga's config is Elixir, the same language the editor is written in:

```elixir
# ~/.config/minga/config.exs
use Minga.Config

# This is real Elixir. Full language. Full standard library.

# Options
set :theme, :doom_one
set :tab_size, 2
set :scroll_off, 5
set :relative_line_numbers, true

# Keybindings
bind :normal, "SPC g s", :git_status, "Git status"
bind :normal, "SPC g b", :git_blame, "Git blame"

# Custom command with real Elixir logic
command :count_todos, "Count TODOs in buffer" do
  content = Buffer.Server.content(current_buffer())
  count = content |> String.split("\n") |> Enum.count(&String.contains?(&1, "TODO"))
  notify("#{count} TODOs found")
end

# Filetype-specific config
for_filetype :elixir do
  set :tab_size, 2
  set :formatter, {"mix", ["format", "--stdin-filename", "{file}", "-"]}
  on :after_save, fn _buf, path -> System.cmd("mix", ["format", path]) end
end

for_filetype :go do
  set :tab_size, 8
  set :expand_tab, false
  set :formatter, {"gofmt", []}
end

# Require your own modules
require_config "modules/*.ex"
```

When you outgrow your config, you're already writing the same code as the
editor itself. There's no graduation from "config language" to "real
language." It's Elixir all the way down.

---

## Where Elixir differs from Elisp

Honest accounting of what's different:

| Aspect | Elisp | Elixir |
|--------|-------|--------|
| **Execution model** | Single-threaded interpreter | Multi-process preemptive VM |
| **Function redefinition** | Immediate, per-function | Per-module reload (~50ms) |
| **Eval speed** | Interpreted (fast for small exprs) | Interpreted via `Code.eval_string` (comparable) |
| **Crash behavior** | Crashes Emacs or corrupts state | Crashes one process; supervisor restarts it |
| **Extension concurrency** | None (slow extension freezes editor) | Extensions are processes; can't block UI |
| **State model** | Global mutable state (footgun-prone) | Per-process state (isolated by default) |
| **Community packages** | MELPA (thousands of packages) | Hex (large Elixir ecosystem, not editor-specific yet) |
| **Learning curve** | Lisp syntax is polarizing | Ruby/Python-like syntax; approachable |

The single real trade-off: you reload a whole module, not a single function.
In practice, modules are small and reload is fast. You won't notice.

---

## What Elixir gives you that Elisp can't

These aren't incremental improvements. They're qualitatively different:

### Concurrent extensions
```elixir
# This runs in its own process. Your editing is never blocked.
on :after_save, fn _buf, path ->
  # Run formatter, linter, git add (takes 2 seconds)
  System.cmd("mix", ["format", path])
  System.cmd("mix", ["credo", "--strict", path])
  System.cmd("git", ["add", path])
end
# You're already typing in the buffer while this runs.
```

In Emacs, this would freeze your editor for 2 seconds. Every time you save.

### Crash-safe extensions
```elixir
# Your buggy command crashes? The supervisor restarts the process.
# Your buffers, undo history, and open files are untouched.
command :risky_thing, "Might crash" do
  dangerous_operation!()  # raises an exception
end
# Result: error message in status bar. Editor keeps running.
```

In Emacs, `(error ...)` in a hook can leave the editor in a half-modified
state. In Minga, it's a process crash: clean, contained, recoverable.

### Live process inspection
```elixir
# See exactly what the editor is doing right now
:observer.start()  # full GUI: processes, memory, message queues, CPU

# Trace a specific process
:sys.trace(Minga.Editor, true)  # print every message it receives

# Get a process's state without stopping it
:sys.get_state(buffer_pid)  # inspect buffer state live
```

Emacs has `describe-function` and `edebug`. The BEAM has an entire
production observability toolkit because it was built for systems that
run 24/7 and must be debuggable without stopping.

### Native concurrency for AI agents
```elixir
# AI agent running in its own supervised process tree
# Can modify buffers via message passing, can't corrupt state
# Can crash without affecting the editor
# Can run alongside your typing, preemptive scheduler guarantees it
Agent.Session.start(provider: :claude, buffer: current_buffer())
```

This is where the BEAM architecture pays off the most. Every other editor
is trying to bolt async AI support onto a fundamentally single-threaded
architecture. Minga's process model means "an external thing wants to
modify a buffer" is a first-class, safe, concurrent operation.

---

## The bottom line

Elisp's power comes from two things: *it's the same language as the editor*
and *everything is mutable at runtime*. Elixir on the BEAM matches both.

The config is Elixir. The editor is Elixir. When you customize, you're
writing the same code as the editor source. When you redefine a function,
the BEAM hot-loads it. When you set a buffer-local option, you're updating
a process's state.

And you get things Elisp never had: crash isolation, concurrent extensions,
per-process garbage collection, and a VM that was purpose-built for systems
that cannot go down.

Minga isn't a Lisp machine. It's a BEAM machine. And for building a
resilient, extensible editor, that's better.
